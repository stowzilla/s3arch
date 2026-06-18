# frozen_string_literal: true

require 'spec_helper'

RSpec.describe S3arch::Handler do
  before do
    S3arch.configure do |c|
      c.source_table = 'test-items'
      c.source_index = 'UserIndex'
      c.index_bucket = 'test-bucket'
      c.version_table = 'test-versions'
      c.owner_key = 'userId'
    end
  end

  describe '.indexer' do
    let(:indexer) { instance_double(S3arch::Indexer) }

    before { allow(S3arch::Indexer).to receive(:new).and_return(indexer) }

    it 'delegates rebuild action to Indexer#rebuild' do
      allow(indexer).to receive(:rebuild)
      described_class.indexer('action' => 'rebuild', 'owner_id' => 'user-1')
      expect(indexer).to have_received(:rebuild).with('user-1')
    end

    it 'delegates stream events to Indexer#process_event' do
      allow(indexer).to receive(:process_event).and_return({ statusCode: 200 })
      event = { 'Records' => [] }
      described_class.indexer(event)
      expect(indexer).to have_received(:process_event).with(event)
    end
  end

  describe '.search' do
    let(:searcher) { instance_double(S3arch::Searcher) }

    before { allow(S3arch::Searcher).to receive(:new).and_return(searcher) }

    it 'delegates to Searcher#search' do
      allow(searcher).to receive(:search).and_return({ record_ids: ['id1'], search_mode: 'fts5' })

      result = described_class.search('query' => 'blue', 'owner_ids' => ['o1'], 'filters' => {})

      expect(searcher).to have_received(:search).with(query: 'blue', owner_ids: ['o1'], filters: {})
      expect(result).to eq({ record_ids: ['id1'], search_mode: 'fts5' })
    end

    it 'returns empty result for nil query' do
      result = described_class.search('query' => nil, 'owner_ids' => ['o1'])
      expect(result).to eq({ record_ids: [], search_mode: 'fts5' })
    end

    it 'returns empty result for empty owner_ids' do
      result = described_class.search('query' => 'test', 'owner_ids' => [])
      expect(result).to eq({ record_ids: [], search_mode: 'fts5' })
    end

    it 'returns nil record_ids when searcher returns nil' do
      allow(searcher).to receive(:search).and_return(nil)

      result = described_class.search('query' => 'nothing', 'owner_ids' => ['o1'])
      expect(result).to eq({ record_ids: nil, search_mode: nil })
    end

    it 'defaults filters to empty hash' do
      allow(searcher).to receive(:search).and_return(nil)

      described_class.search('query' => 'test', 'owner_ids' => ['o1'])
      expect(searcher).to have_received(:search).with(query: 'test', owner_ids: ['o1'], filters: {})
    end
  end
end
