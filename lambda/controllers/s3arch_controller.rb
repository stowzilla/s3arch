# frozen_string_literal: true

require 'aws-sdk-dynamodb'

class S3archController < BeltController::Base
  def index
    owners = fetch_owners
    success_response(owners: owners)
  rescue StandardError => e
    error_response("Failed to load owners: #{e.message}", 500)
  end

  def rebuild
    owner_id = params['owner_id']&.strip
    return error_response('owner_id is required', 400) if owner_id.nil? || owner_id.empty?

    handler = S3arch.configuration.rebuild_handler
    if handler
      handler.call(owner_id)
    else
      S3arch::Indexer.new.rebuild(owner_id)
    end
    success_response(status: 'ok', owner_id: owner_id)
  rescue StandardError => e
    error_response("Failed to rebuild index: #{e.message}", 500)
  end

  private

  def fetch_owners
    dynamodb = Aws::DynamoDB::Client.new
    config = S3arch.configuration
    items = []
    scan_params = { table_name: config.version_table }

    loop do
      result = dynamodb.scan(scan_params)
      items.concat(result.items)
      break unless result.last_evaluated_key

      scan_params[:exclusive_start_key] = result.last_evaluated_key
    end

    items.map do |item|
      {
        owner_id: item[config.owner_key] || item.values.first,
        version: item['version'],
        record_count: item['record_count'],
        updated_at: item['updated_at']
      }
    end.sort_by { |o| o[:updated_at].to_s }.reverse
  end
end
