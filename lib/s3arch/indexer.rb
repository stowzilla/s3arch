# frozen_string_literal: true

require 'sqlite3'
require 'json'
require_relative 'indexer/stream_parser'

module S3arch
  # Builds SQLite FTS5 databases per owner from pre-computed tokens stored in DynamoDB.
  # The indexer never sees raw content — only tokens. Supports incremental updates via
  # DynamoDB Stream events (INSERT/MODIFY/REMOVE).
  class Indexer
    include StreamParser

    def initialize(config: S3arch.configuration, store: nil)
      config.validate!
      @config = config
      @store = store || Store.new(config: config)
    end

    # Full rebuild — pulls all tokens from DynamoDB for an owner.
    def rebuild(owner_id)
      records = @store.fetch_records(owner_id)
      db_path = "/tmp/s3arch_#{owner_id}.sqlite3"

      build_database(db_path, records)
      @store.upload_index(owner_id, db_path)
      @store.increment_version(owner_id, records.size)

      log(:info, 'Index rebuilt', owner_id: owner_id, record_count: records.size)
    ensure
      File.delete(db_path) if db_path && File.exist?(db_path)
    end

    # Incremental update — applies INSERT/DELETE/UPDATE to an existing index.
    def apply_changes(owner_id, changes)
      db_path = "/tmp/s3arch_#{owner_id}.sqlite3"

      unless @store.download_index(owner_id, db_path)
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

      @store.upload_index(owner_id, db_path)
      @store.increment_version(owner_id, record_count)

      log(:info, 'Index updated incrementally', owner_id: owner_id, changes: changes.size, record_count: record_count)
    ensure
      File.delete(db_path) if db_path && File.exist?(db_path)
    end

    # Process SQS event containing DynamoDB stream records.
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

    def log(level, message, **data)
      return unless @config.logger

      @config.logger.send(level, message, **data)
    end
  end
end
