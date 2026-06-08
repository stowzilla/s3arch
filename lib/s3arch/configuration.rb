# frozen_string_literal: true

module S3arch
  class Configuration
    # DynamoDB table that contains the source records to index
    attr_accessor :source_table

    # DynamoDB index to query records by owner (e.g., 'UserIndex')
    attr_accessor :source_index

    # Partition key field on the source table for owner lookup
    attr_accessor :owner_key

    # S3 bucket for storing SQLite index files
    attr_accessor :index_bucket

    # DynamoDB table for version tracking
    attr_accessor :version_table

    # FTS5 searchable fields — array of field names from the source record
    attr_accessor :searchable_fields

    # DynamoDB attribute name where pre-computed tokens are stored (Map type)
    # e.g., { "searchTokens": { "name": "blue jacket", "description": "warm winter coat" } }
    attr_accessor :token_field

    # Metadata fields stored alongside FTS5 for filtering (not searched)
    attr_accessor :metadata_fields

    # Filter proc — receives a record hash, returns true to include in index
    attr_accessor :record_filter

    # Owner extractor — proc that extracts owner_id from a DynamoDB stream record
    attr_accessor :owner_extractor

    # Logger (defaults to $stdout)
    attr_accessor :logger

    # Searcher settings
    attr_accessor :version_ttl, :max_results, :max_cached_dbs, :ephemeral_storage_mb

    def initialize
      @owner_key = 'user_id'
      @searchable_fields = %w[name description]
      @token_field = 'searchTokens'
      @metadata_fields = %w[status created_at]
      @record_filter = ->(_record) { true }
      @owner_extractor = ->(stream_record) {
        image = stream_record.dig('dynamodb', 'NewImage') || stream_record.dig('dynamodb', 'OldImage') || {}
        image.dig(owner_key, 'S')
      }
      @version_ttl = 30
      @max_results = 50
      @max_cached_dbs = 20
      @ephemeral_storage_mb = 2048
      @logger = nil
    end

    # Convenience: env-based configuration (reads from Lambda environment variables)
    def from_env!
      @source_table = ENV['S3ARCH_SOURCE_TABLE'] || ENV['INVENTORY_TABLE']
      @source_index = ENV['S3ARCH_SOURCE_INDEX'] || 'UserIndex'
      @index_bucket = ENV['S3ARCH_INDEX_BUCKET'] || ENV['SEARCH_INDEX_BUCKET']
      @version_table = ENV['S3ARCH_VERSION_TABLE'] || ENV['SEARCH_INDEX_TABLE']
      self
    end

    def validate!
      missing = []
      missing << 'source_table' unless source_table
      missing << 'index_bucket' unless index_bucket
      missing << 'version_table' unless version_table
      missing << 'source_index' unless source_index
      raise Error, "S3arch configuration missing: #{missing.join(', ')}" if missing.any?
    end
  end
end
