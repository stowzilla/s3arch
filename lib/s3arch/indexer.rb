# frozen_string_literal: true

require 'aws-sdk-dynamodb'
require 'aws-sdk-s3'
require 'sqlite3'
require 'json'

module S3arch
  class Indexer
    def initialize(config: S3arch.configuration)
      config.validate!
      @config = config
      @dynamodb = Aws::DynamoDB::Client.new
      @s3 = Aws::S3::Client.new
    end

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

    def process_event(event)
      records = event['Records'] || []
      owner_ids = records.filter_map { |r|
        body = JSON.parse(r['body'])
        @config.owner_extractor.call(body)
      }.uniq

      log(:info, 'Rebuilding indexes', owner_ids: owner_ids, record_count: records.size)
      owner_ids.each { |id| rebuild(id) }
      { statusCode: 200, body: JSON.generate(rebuilt: owner_ids.size) }
    end

    private

    def fetch_records(owner_id)
      records = []
      params = { table_name: @config.source_table, index_name: @config.source_index,
                 key_condition_expression: "#{@config.owner_key} = :owner",
                 expression_attribute_values: { ':owner' => owner_id } }

      loop do
        result = @dynamodb.query(params)
        result.items.each { |item| records << item if @config.record_filter.call(item) }
        break unless result.last_evaluated_key
        params[:exclusive_start_key] = result.last_evaluated_key
      end

      records
    end

    def build_database(db_path, records)
      File.delete(db_path) if File.exist?(db_path)
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
          fts_values = @config.searchable_fields.map { |f| normalize_field(record[f]) }
          db.execute("INSERT INTO records_fts(rowid, #{fts_cols}) VALUES (#{(['?'] * (fts_values.size + 1)).join(', ')})",
                     [rowid] + fts_values)

          meta_values = [rowid, normalize_field(record['id'])] + @config.metadata_fields.map { |f| normalize_field(record[f]) }
          placeholders = (['?'] * meta_values.size).join(', ')
          db.execute("INSERT INTO records_meta(rowid, record_id, #{@config.metadata_fields.join(', ')}) VALUES (#{placeholders})",
                     meta_values)
        end
      end

      db.close
    end

    def normalize_field(value)
      case value
      when Hash
        if value.key?('S') then value['S'].to_s
        elsif value.key?('L') then value['L'].map { |v| v['S'] || v.to_s }.join(' ')
        elsif value.key?('N') then value['N'].to_s
        elsif value.key?('SS') then value['SS'].join(' ')
        else value.values.first.to_s
        end
      when Array then value.map { |v| v.is_a?(Hash) ? (v['S'] || v.to_s) : v.to_s }.join(' ')
      when nil then ''
      else value.to_s
      end
    end

    def upload(owner_id, db_path)
      @s3.put_object(bucket: @config.index_bucket, key: "#{owner_id}/index.sqlite3", body: File.open(db_path, 'rb'))
    end

    def increment_version(owner_id, record_count)
      @dynamodb.update_item(
        table_name: @config.version_table,
        key: { @config.owner_key => owner_id },
        update_expression: 'SET version = if_not_exists(version, :zero) + :one, updated_at = :now, record_count = :count',
        expression_attribute_values: { ':zero' => 0, ':one' => 1, ':now' => Time.now.iso8601, ':count' => record_count }
      )
    end

    def log(level, message, **data)
      return unless @config.logger
      @config.logger.send(level, message, **data)
    end
  end
end
