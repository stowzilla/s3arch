# frozen_string_literal: true

module S3arch
  class Configuration
    attr_accessor :source_table, :source_index, :owner_key, :index_bucket, :version_table,
                  :searchable_fields, :metadata_fields, :record_filter, :owner_extractor,
                  :logger, :version_ttl, :max_results, :max_cached_dbs, :ephemeral_storage_mb

    def initialize
      @owner_key = 'user_id'
      @searchable_fields = %w[name description]
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

    def from_env!
      @source_table = ENV['S3ARCH_SOURCE_TABLE']
      @source_index = ENV['S3ARCH_SOURCE_INDEX'] || 'UserIndex'
      @index_bucket = ENV['S3ARCH_INDEX_BUCKET']
      @version_table = ENV['S3ARCH_VERSION_TABLE']
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
