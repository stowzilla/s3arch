# frozen_string_literal: true

require_relative '../models/search_version'

class S3archController < BeltController::Base
  def index
    versions = S3arch::Models::SearchVersion.all
    success_response(owners: versions.map(&:to_h))
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
end
