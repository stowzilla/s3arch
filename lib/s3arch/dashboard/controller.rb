# frozen_string_literal: true

require 'aws-sdk-dynamodb'

module S3arch
  module Dashboard
    # Mixin for Lambda controllers. Include in your ApplicationController subclass:
    #
    #   class S3archController < BaseController
    #     include S3arch::Dashboard::Controller
    #   end
    #
    # Provides #index and #rebuild actions that return JSON via success_response/error_response.
    module Controller
      def index
        owners = fetch_owners
        success_response(owners: owners)
      rescue StandardError => e
        error_response("Failed to load s3arch dashboard: #{e.message}")
      end

      def rebuild
        owner_id = params['owner_id']&.strip
        return error_response('owner_id is required') if owner_id.nil? || owner_id.empty?

        S3arch::Indexer.new.rebuild(owner_id)
        success_response(status: 'ok', owner_id: owner_id)
      rescue StandardError => e
        error_response("Failed to rebuild index: #{e.message}")
      end

      private

      def fetch_owners
        dynamodb = Aws::DynamoDB::Client.new
        config = S3arch.configuration
        items = []
        params = { table_name: config.version_table }

        loop do
          result = dynamodb.scan(params)
          items.concat(result.items)
          break unless result.last_evaluated_key

          params[:exclusive_start_key] = result.last_evaluated_key
        end

        owners = items.map do |item|
          {
            owner_id: item[config.owner_key] || item.values.first,
            version: item['version'],
            record_count: item['record_count'],
            updated_at: item['updated_at']
          }
        end
        owners.sort_by { |o| o[:updated_at].to_s }.reverse
      end
    end
  end
end
