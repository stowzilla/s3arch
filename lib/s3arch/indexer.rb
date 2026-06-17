# frozen_string_literal: true

require 'aws-sdk-dynamodb'
require 'aws-sdk-s3'
require 'sqlite3'
require 'json'
require_relative 'indexer/stream_parser'

module S3arch
  # Builds SQLite FTS5 databases per owner from pre-computed tokens stored in DynamoDB.
  # The indexer never sees raw content — only tokens. Supports incremental updates via
  # DynamoDB Stream events (INSERT/MODIFY/REMOVE).
  class Indexer
    include StreamParser

    def initialize(config: S3arch.configuration)
      config.validate!
      @config = config
      @dynamodb = Aws::DynamoDB::Client.new
      @s3 = Aws::S3::Client.new
    end

    # Full rebuild — pulls all tokens from DynamoDB for an owner.
    # Used for initial backfill or when incremental isn't possible.
    def rebuild(owner_id)
      records = fetch_records(owner_id)
      db_path = "/tmp/s3arch_#{owner_id}.sqlite3"

      build_database(db_path, records)
      upload(owner_id, db_path)
      increment_version(owner_id, records.size)

      log(:info, 'Index rebuilt', owner_id: owner_id, record_count: records.size)
    ensure
      File.delete(db_path) if db_path && File.exist?(db_path)
    end

    # Incremental update — applies INSERT/DELETE/UPDATE to an existing index.
    # Downloads current DB from S3, applies changes, re-uploads.
    def apply_changes(owner_id, changes)
      db_path = "/tmp/s3arch_#{owner_id}.sqlite3"
      download_existing(owner_id, db_path)

      unless File.exist?(db_path)
        log(:info, 'No existing index, doing full rebuild', owner_id: owner_id)
        return rebuild(owner_id)
      end

      db = SQLite3::Database.new(db_path)
      db.results_as_hash = true

      db.transaction do
        changes.each { |change| apply_change(db, change) }
      end

      record_count = db.get_first_value('SELECT COUNT(*) FROM records_meta')
      db.close

      upload(owner_id, db_path)
      increment_version(owner_id, record_count)

      log(:info, 'Index updated incrementally', owner_id: owner_id, changes: changes.size, record_count: record_count)
    ensure
      File.delete(db_path) if db_path && File.exist?(db_path)
    end

    # Process SQS event containing DynamoDB stream records.
    # Groups by owner and applies incremental changes.
    def process_event(event)
      sqs_records = event['Records'] || []
      grouped = group_changes(sqs_records)

      log(:info, 'Processing stream events', owner_count: grouped.size, record_count: sqs_records.size)

      grouped.each do |owner_id, changes|
        if changes.any? { |c| c[:action] == :rebuild }
          rebuild(owner_id)
        else
          apply_changes(owner_id, changes)
        end
      end

      { statusCode: 200, body: JSON.generate(rebuilt: grouped.size) }
    end

    RESERVED_WORDS = Set.new(%w[status name comment count size type]).freeze

    private

    def apply_change(db, change)
      case change[:action]
      when :insert
        rowid = next_rowid(db)
        insert_row(db, rowid, change[:record_id], change[:tokens], change[:meta])
      when :delete
        rowid = find_rowid(db, change[:record_id])
        delete_row(db, rowid, change[:tokens]) if rowid
      when :update
        rowid = find_rowid(db, change[:record_id])
        if rowid
          delete_row(db, rowid, change[:old_tokens])
          insert_row(db, rowid, change[:record_id], change[:new_tokens], change[:meta])
        else
          # Record wasn't in index yet, just insert
          new_rowid = next_rowid(db)
          insert_row(db, new_rowid, change[:record_id], change[:new_tokens], change[:meta])
        end
      end
    end

    def insert_row(db, rowid, record_id, tokens, meta)
      fts_cols = @config.searchable_fields
      fts_values = fts_cols.map { |f| tokens[f] || '' }
      placeholders = (['?'] * (fts_values.size + 1)).join(', ')
      db.execute("INSERT INTO records_fts(rowid, #{fts_cols.join(', ')}) VALUES (#{placeholders})",
                 [rowid] + fts_values)

      meta ||= {}
      meta_values = [rowid, record_id] + @config.metadata_fields.map { |f| meta[f] || '' }
      meta_placeholders = (['?'] * meta_values.size).join(', ')
      meta_cols = "rowid, record_id, #{@config.metadata_fields.join(', ')}"
      db.execute("INSERT INTO records_meta(#{meta_cols}) VALUES (#{meta_placeholders})", meta_values)
    end

    def delete_row(db, rowid, tokens)
      fts_cols = @config.searchable_fields
      fts_values = fts_cols.map { |f| tokens[f] || '' }
      placeholders = (['?'] * (fts_values.size + 1)).join(', ')
      # FTS5 contentless delete: INSERT with special 'delete' command
      fts_delete_sql = "INSERT INTO records_fts(records_fts, rowid, #{fts_cols.join(', ')}) " \
                       "VALUES ('delete', #{placeholders})"
      db.execute(fts_delete_sql, [rowid] + fts_values)
      db.execute('DELETE FROM records_meta WHERE rowid = ?', [rowid])
    end

    def find_rowid(db, record_id)
      db.get_first_value('SELECT rowid FROM records_meta WHERE record_id = ?', [record_id])
    end

    def next_rowid(db)
      max = db.get_first_value('SELECT MAX(rowid) FROM records_meta')
      (max || 0) + 1
    end

    def download_existing(owner_id, db_path)
      @s3.get_object(bucket: @config.index_bucket, key: "#{owner_id}/index.sqlite3", response_target: db_path)
    rescue Aws::S3::Errors::NoSuchKey
      # No existing index — caller will fall back to rebuild
    end

    # Full rebuild: fetches token field from DynamoDB (never reads content)
    def fetch_records(owner_id)
      records = []
      params = build_query_params(owner_id)

      loop do
        result = @dynamodb.query(params)
        result.items.each do |item|
          next unless @config.record_filter.call(item)

          tokens = extract_tokens_from_item(item)
          next unless tokens.is_a?(Hash) && tokens.any?

          records << { 'id' => item['id'], 'tokens' => tokens, 'meta' => extract_meta_from_item(item) }
        end
        break unless result.last_evaluated_key

        params[:exclusive_start_key] = result.last_evaluated_key
      end

      records
    end

    def extract_tokens_from_item(item)
      # Try the dedicated token field first
      tokens = item[@config.token_field]
      return tokens if tokens.is_a?(Hash) && tokens.any?

      # Fall back: synthesize tokens from searchable_fields directly
      @config.searchable_fields.each_with_object({}) do |field, map|
        val = item[field]
        map[field] = val.to_s if val
      end
    end

    def build_query_params(owner_id)
      fields = (['id', @config.token_field, @config.owner_key] +
                @config.searchable_fields + @config.metadata_fields + @config.filter_fields).compact.uniq
      expression_names = {}
      projected = fields.map { |f| reserved_word?(f) ? "##{f}".tap { |p| expression_names[p] = f } : f }

      owner_placeholder = reserved_word?(@config.owner_key) ? "##{@config.owner_key}" : @config.owner_key
      expression_names["##{@config.owner_key}"] = @config.owner_key if reserved_word?(@config.owner_key)

      params = { table_name: @config.source_table, index_name: @config.source_index,
                 key_condition_expression: "#{owner_placeholder} = :owner",
                 expression_attribute_values: { ':owner' => owner_id },
                 projection_expression: projected.join(', ') }
      params[:expression_attribute_names] = expression_names if expression_names.any?
      params
    end

    def extract_meta_from_item(item)
      @config.metadata_fields.to_h { |field| [field, item[field].to_s] }
    end

    def reserved_word?(field) = RESERVED_WORDS.include?(field.downcase)

    def build_database(db_path, records)
      FileUtils.rm_f(db_path)
      db = SQLite3::Database.new(db_path)

      fts_cols = @config.searchable_fields.join(', ')
      meta_cols = (['rowid INTEGER PRIMARY KEY', 'record_id TEXT NOT NULL'] +
                   @config.metadata_fields.map { |f| "#{f} TEXT" }).join(', ')

      db.execute_batch(<<~SQL)
        CREATE VIRTUAL TABLE records_fts USING fts5(#{fts_cols}, content='');
        CREATE TABLE records_meta (#{meta_cols});
      SQL

      db.transaction do
        records.each_with_index do |record, idx|
          rowid = idx + 1
          tokens = record['tokens']
          fts_values = @config.searchable_fields.map { |f| tokens[f] || '' }
          placeholders = (['?'] * (fts_values.size + 1)).join(', ')
          db.execute("INSERT INTO records_fts(rowid, #{fts_cols}) VALUES (#{placeholders})", [rowid] + fts_values)

          meta_values = [rowid, record['id']] + @config.metadata_fields.map { |f| record['meta'][f] || '' }
          meta_placeholders = (['?'] * meta_values.size).join(', ')
          meta_cols = "rowid, record_id, #{@config.metadata_fields.join(', ')}"
          db.execute("INSERT INTO records_meta(#{meta_cols}) VALUES (#{meta_placeholders})", meta_values)
        end
      end

      db.close
    end

    def upload(owner_id, db_path)
      @s3.put_object(bucket: @config.index_bucket, key: "#{owner_id}/index.sqlite3", body: File.open(db_path, 'rb'))
    end

    def increment_version(owner_id, record_count)
      @dynamodb.update_item(
        table_name: @config.version_table,
        key: { @config.owner_key => owner_id },
        update_expression: 'SET version = if_not_exists(version, :zero) + :one, ' \
                           'updated_at = :now, record_count = :count',
        expression_attribute_values: { ':zero' => 0, ':one' => 1, ':now' => Time.now.iso8601, ':count' => record_count }
      )
    end

    def log(level, message, **data)
      return unless @config.logger

      @config.logger.send(level, message, **data)
    end
  end
end
