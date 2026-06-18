# frozen_string_literal: true

require 'aws-sdk-dynamodb'
require 'aws-sdk-s3'

module S3arch
  # Thin adapter layer encapsulating all DynamoDB/S3 operations for index lifecycle.
  # Indexer and Searcher delegate here instead of calling AWS SDKs directly.
  class Store
    def initialize(config: S3arch.configuration)
      @config = config
      @dynamodb = Aws::DynamoDB::Client.new
      @s3 = Aws::S3::Client.new
    end

    # --- Source data (read tokens from host app's DynamoDB table) ---

    def fetch_records(owner_id)
      records = []
      params = build_query_params(owner_id)

      loop do
        result = @dynamodb.query(params)
        result.items.each do |item|
          next unless @config.record_filter.call(item)

          tokens = extract_tokens_from_item(item)
          next unless tokens.is_a?(Hash) && tokens.any?

          records << { 'id' => item['id'], 'tokens' => tokens, 'meta' => extract_meta(item) }
        end
        break unless result.last_evaluated_key

        params[:exclusive_start_key] = result.last_evaluated_key
      end

      records
    end

    # --- Index files (SQLite databases on S3) ---

    def upload_index(owner_id, db_path)
      @s3.put_object(bucket: @config.index_bucket, key: index_key(owner_id), body: File.open(db_path, 'rb'))
    end

    def download_index(owner_id, db_path)
      @s3.get_object(bucket: @config.index_bucket, key: index_key(owner_id), response_target: db_path)
      true
    rescue Aws::S3::Errors::NoSuchKey
      false
    end

    # --- Version tracking ---

    def fetch_version(owner_id)
      result = @dynamodb.get_item(table_name: @config.version_table,
                                  key: { @config.owner_key => owner_id },
                                  projection_expression: 'version')
      result.item&.dig('version')&.to_i
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

    private

    RESERVED_WORDS = Set.new(%w[status name comment count size type]).freeze

    def index_key(owner_id) = "#{owner_id}/index.sqlite3"

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

    def extract_tokens_from_item(item)
      tokens = item[@config.token_field]
      return tokens if tokens.is_a?(Hash) && tokens.any?

      @config.searchable_fields.each_with_object({}) do |field, map|
        val = item[field]
        map[field] = val.to_s if val
      end
    end

    def extract_meta(item)
      @config.metadata_fields.to_h { |field| [field, item[field].to_s] }
    end

    def reserved_word?(field) = RESERVED_WORDS.include?(field.downcase)
  end
end
