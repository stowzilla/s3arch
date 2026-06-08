# frozen_string_literal: true

require 'aws-sdk-dynamodb'
require 'aws-sdk-s3'
require 'sqlite3'

module S3arch
  class Searcher
    @version_cache = {}
    @db_cache = {}

    class << self
      attr_accessor :version_cache, :db_cache

      def reset!
        @version_cache = {}
        @db_cache = {}
      end
    end

    def initialize(config: S3arch.configuration)
      config.validate!
      @config = config
      @dynamodb = Aws::DynamoDB::Client.new
      @s3 = Aws::S3::Client.new
    end

    def search(query:, owner_ids:, filters: {})
      return nil if owner_ids.empty? || query.nil? || query.strip.empty?

      log(:info, 'Search started', query: query, owner_ids: owner_ids, filters: filters)

      results = []
      owner_ids.each do |owner_id|
        db = ensure_database(owner_id)
        unless db
          log(:info, 'No database available', owner_id: owner_id)
          next
        end
        hits = query_fts(db, query, filters: filters)
        log(:info, 'Owner search complete', owner_id: owner_id, hits: hits.size)
        results.concat(hits)
      end

      log(:info, 'Search complete', total_results: results.size)
      return nil if results.empty?

      results.sort_by! { |r| r[:rank] }
      { record_ids: results.first(@config.max_results).map { |r| r[:record_id] }, search_mode: 'fts5' }
    end

    private

    def ensure_database(owner_id)
      current_version = fetch_version(owner_id)
      return nil unless current_version

      cached = self.class.db_cache[owner_id]
      if cached && cached[:version] == current_version
        cached[:last_used] = Time.now
        return cached[:db]
      end

      log(:info, 'Downloading database from S3', owner_id: owner_id, version: current_version)
      db = download_database(owner_id)
      return nil unless db

      evict_lru if self.class.db_cache.size >= @config.max_cached_dbs
      self.class.db_cache[owner_id] = { db: db, version: current_version, last_used: Time.now }
      db
    end

    def fetch_version(owner_id)
      cached = self.class.version_cache[owner_id]
      return cached[:version] if cached && (Time.now - cached[:checked_at]) < @config.version_ttl

      result = @dynamodb.get_item(table_name: @config.version_table,
                                  key: { @config.owner_key => owner_id },
                                  projection_expression: 'version')
      version = result.item&.dig('version')
      self.class.version_cache[owner_id] = { version: version, checked_at: Time.now } if version
      version
    end

    def download_database(owner_id)
      db_path = "/tmp/s3arch_#{owner_id}.sqlite3"
      @s3.get_object(bucket: @config.index_bucket, key: "#{owner_id}/index.sqlite3",
                     response_target: db_path)
      db = SQLite3::Database.new(db_path)
      db.results_as_hash = true
      db
    rescue Aws::S3::Errors::NoSuchKey
      nil
    end

    def query_fts(db, query, filters: {})
      terms = query.strip.split(/\s+/).map { |t| "#{t.gsub('"', '')}*" }
      match_expr = terms.join(' AND ')
      return [] if match_expr.empty?

      sql = <<~SQL
        SELECT m.record_id, m.*, rank
        FROM records_fts f
        JOIN records_meta m ON m.rowid = f.rowid
        WHERE records_fts MATCH ?
        ORDER BY rank
        LIMIT #{@config.max_results}
      SQL

      rows = db.execute(sql, [match_expr])
      rows.filter_map do |row|
        next if filters.any? { |field, value| row[field.to_s] != value }

        { record_id: row['record_id'], rank: row['rank'] }
      end
    rescue SQLite3::Exception => e
      log(:error, 'FTS5 query failed', error: e.message)
      []
    end

    def evict_lru
      oldest = self.class.db_cache.min_by { |_, v| v[:last_used] }
      return unless oldest

      owner_id, entry = oldest
      entry[:db]&.close rescue nil
      File.delete("/tmp/s3arch_#{owner_id}.sqlite3") rescue nil
      self.class.db_cache.delete(owner_id)
    end

    def log(level, message, **data)
      return unless @config.logger

      @config.logger.send(level, message, **data)
    end
  end
end
