# frozen_string_literal: true

module S3arch
  module Handler
    class << self
      def indexer(event)
        if event['action'] == 'rebuild'
          S3arch::Indexer.new.rebuild(event['owner_id'])
        else
          S3arch::Indexer.new.process_event(event)
        end
      end

      def search(event)
        query = event['query']
        owner_ids = event['owner_ids'] || []
        filters = event['filters'] || {}

        return { record_ids: [], search_mode: 'fts5' } if query.nil? || owner_ids.empty?

        searcher = S3arch::Searcher.new
        result = searcher.search(query: query, owner_ids: owner_ids, filters: filters)

        result || { record_ids: nil, search_mode: nil }
      end
    end
  end
end
