# frozen_string_literal: true

module S3arch
  module Models
    # Lightweight model for the version tracking table.
    # Each record represents one owner's index state.
    class SearchVersion
      attr_reader :owner_id, :version, :record_count, :updated_at

      def initialize(owner_id:, version: 0, record_count: 0, updated_at: nil)
        @owner_id = owner_id
        @version = version.to_i
        @record_count = record_count.to_i
        @updated_at = updated_at
      end

      def to_h
        { owner_id: owner_id, version: version.to_s, record_count: record_count, updated_at: updated_at }
      end

      class << self
        def all(config: S3arch.configuration)
          items = []
          params = { table_name: config.version_table }

          loop do
            result = Aws::DynamoDB::Client.new.scan(params)
            items.concat(result.items)
            break unless result.last_evaluated_key

            params[:exclusive_start_key] = result.last_evaluated_key
          end

          items.map { |item| from_dynamo(item, config) }
               .sort_by { |v| v.updated_at.to_s }
               .reverse
        end

        def find(owner_id, config: S3arch.configuration)
          result = Aws::DynamoDB::Client.new.get_item(table_name: config.version_table,
                                                      key: { config.owner_key => owner_id },
                                                      projection_expression: 'version')
          return nil unless result.item

          result.item['version']&.to_i
        end

        def increment!(owner_id, record_count:, config: S3arch.configuration)
          Aws::DynamoDB::Client.new.update_item(
            table_name: config.version_table,
            key: { config.owner_key => owner_id },
            update_expression: 'SET version = if_not_exists(version, :zero) + :one, ' \
                               'updated_at = :now, record_count = :count',
            expression_attribute_values: { ':zero' => 0, ':one' => 1, ':now' => Time.now.iso8601, ':count' => record_count }
          )
        end

        private

        def from_dynamo(item, config)
          new(
            owner_id: item[config.owner_key] || item.values.first,
            version: item['version'],
            record_count: item['record_count'],
            updated_at: item['updated_at']
          )
        end
      end
    end
  end
end
