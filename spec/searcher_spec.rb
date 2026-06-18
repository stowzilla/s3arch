# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'

RSpec.describe S3arch::Searcher do
  let(:dynamodb) { instance_double(Aws::DynamoDB::Client) }
  let(:s3) { instance_double(Aws::S3::Client) }
  let(:searcher) { described_class.new }

  before do
    S3arch.configure do |c|
      c.source_table = 'test-items'
      c.source_index = 'UserIndex'
      c.index_bucket = 'test-bucket'
      c.version_table = 'test-versions'
      c.owner_key = 'userId'
      c.searchable_fields = %w[name description]
      c.metadata_fields = %w[status]
      c.max_results = 50
      c.max_cached_dbs = 3
      c.version_ttl = 30
    end

    allow(Aws::DynamoDB::Client).to receive(:new).and_return(dynamodb)
    allow(Aws::S3::Client).to receive(:new).and_return(s3)
    described_class.reset!
  end

  after do
    described_class.reset!
    Dir.glob('/tmp/s3arch_*.sqlite3').each { |f| File.delete(f) rescue nil }
  end

  def create_test_db(owner_id, records)
    db_path = "/tmp/s3arch_source_#{owner_id}.sqlite3"
    FileUtils.rm_f(db_path)
    db = SQLite3::Database.new(db_path)
    db.execute_batch(<<~SQL)
      CREATE VIRTUAL TABLE records_fts USING fts5(name, description, content='');
      CREATE TABLE records_meta (rowid INTEGER PRIMARY KEY, record_id TEXT NOT NULL, status TEXT);
    SQL
    records.each_with_index do |record, idx|
      rowid = idx + 1
      db.execute('INSERT INTO records_fts(rowid, name, description) VALUES (?, ?, ?)',
                 [rowid, record[:name], record[:description]])
      db.execute('INSERT INTO records_meta(rowid, record_id, status) VALUES (?, ?, ?)',
                 [rowid, record[:id], record[:status] || 'active'])
    end
    db.close
    db_path
  end

  describe '#search' do
    it 'returns nil for empty owner_ids' do
      expect(searcher.search(query: 'test', owner_ids: [])).to be_nil
    end

    it 'returns nil for nil query' do
      expect(searcher.search(query: nil, owner_ids: ['o1'])).to be_nil
    end

    it 'returns nil for blank query' do
      expect(searcher.search(query: '   ', owner_ids: ['o1'])).to be_nil
    end

    context 'with a valid database' do
      before do
        db_path = create_test_db('owner-1', [
          { id: 'item-1', name: 'blue chair', description: 'comfortable seating', status: 'active' },
          { id: 'item-2', name: 'red table', description: 'wooden dining table', status: 'active' },
          { id: 'item-3', name: 'blue lamp', description: 'bright light', status: 'archived' }
        ])

        allow(dynamodb).to receive(:get_item).and_return(double(item: { 'version' => 1 }))
        allow(s3).to receive(:get_object) do |args|
          FileUtils.cp(db_path, args[:response_target])
        end
      end

      it 'returns matching record_ids' do
        result = searcher.search(query: 'blue', owner_ids: ['owner-1'])
        expect(result[:record_ids]).to contain_exactly('item-1', 'item-3')
        expect(result[:search_mode]).to eq('fts5')
      end

      it 'supports prefix matching' do
        result = searcher.search(query: 'tab', owner_ids: ['owner-1'])
        expect(result[:record_ids]).to include('item-2')
      end

      it 'supports multi-term AND queries' do
        result = searcher.search(query: 'blue chair', owner_ids: ['owner-1'])
        expect(result[:record_ids]).to eq(['item-1'])
      end

      it 'applies metadata filters' do
        result = searcher.search(query: 'blue', owner_ids: ['owner-1'], filters: { status: 'active' })
        expect(result[:record_ids]).to eq(['item-1'])
      end

      it 'returns nil when no results match' do
        result = searcher.search(query: 'nonexistent', owner_ids: ['owner-1'])
        expect(result).to be_nil
      end

      it 'respects max_results limit' do
        S3arch.configuration.max_results = 1
        result = searcher.search(query: 'blue', owner_ids: ['owner-1'])
        expect(result[:record_ids].size).to eq(1)
      end
    end

    context 'with multiple owners' do
      before do
        db_path1 = create_test_db('owner-1', [{ id: 'item-1', name: 'blue chair', description: '' }])
        db_path2 = create_test_db('owner-2', [{ id: 'item-2', name: 'blue table', description: '' }])

        allow(dynamodb).to receive(:get_item).and_return(double(item: { 'version' => 1 }))
        allow(s3).to receive(:get_object) do |args|
          src = args[:key].start_with?('owner-1') ? db_path1 : db_path2
          FileUtils.cp(src, args[:response_target])
        end
      end

      it 'searches across multiple owners' do
        result = searcher.search(query: 'blue', owner_ids: %w[owner-1 owner-2])
        expect(result[:record_ids]).to contain_exactly('item-1', 'item-2')
      end
    end

    context 'version caching' do
      before do
        db_path = create_test_db('owner-1', [{ id: 'item-1', name: 'widget', description: '' }])
        allow(s3).to receive(:get_object) do |args|
          FileUtils.cp(db_path, args[:response_target])
        end
      end

      it 'caches version checks within TTL' do
        allow(dynamodb).to receive(:get_item).and_return(double(item: { 'version' => 1 }))

        searcher.search(query: 'widget', owner_ids: ['owner-1'])
        searcher.search(query: 'widget', owner_ids: ['owner-1'])

        expect(dynamodb).to have_received(:get_item).once
      end

      it 'refreshes version after TTL expires' do
        allow(dynamodb).to receive(:get_item).and_return(double(item: { 'version' => 1 }))
        S3arch.configuration.version_ttl = 0

        searcher.search(query: 'widget', owner_ids: ['owner-1'])
        # Expire the cache
        described_class.version_cache['owner-1'][:checked_at] = Time.now - 60
        searcher.search(query: 'widget', owner_ids: ['owner-1'])

        expect(dynamodb).to have_received(:get_item).twice
      end
    end

    context 'database caching' do
      before do
        db_path = create_test_db('owner-1', [{ id: 'item-1', name: 'widget', description: '' }])
        allow(dynamodb).to receive(:get_item).and_return(double(item: { 'version' => 1 }))
        allow(s3).to receive(:get_object) do |args|
          FileUtils.cp(db_path, args[:response_target])
        end
      end

      it 'reuses cached database when version unchanged' do
        searcher.search(query: 'widget', owner_ids: ['owner-1'])
        searcher.search(query: 'widget', owner_ids: ['owner-1'])

        expect(s3).to have_received(:get_object).once
      end

      it 're-downloads database when version changes' do
        searcher.search(query: 'widget', owner_ids: ['owner-1'])

        # Simulate version bump
        described_class.version_cache.clear
        allow(dynamodb).to receive(:get_item).and_return(double(item: { 'version' => 2 }))

        searcher.search(query: 'widget', owner_ids: ['owner-1'])

        expect(s3).to have_received(:get_object).twice
      end
    end

    context 'LRU eviction' do
      it 'evicts least recently used database when cache is full' do
        S3arch.configuration.max_cached_dbs = 2
        allow(dynamodb).to receive(:get_item).and_return(double(item: { 'version' => 1 }))

        %w[owner-1 owner-2 owner-3].each do |owner|
          db_path = create_test_db(owner, [{ id: "item-#{owner}", name: 'thing', description: '' }])
          allow(s3).to receive(:get_object).with(hash_including(key: "#{owner}/index.sqlite3")) do |args|
            FileUtils.cp(db_path, args[:response_target])
          end
        end

        searcher.search(query: 'thing', owner_ids: ['owner-1'])
        searcher.search(query: 'thing', owner_ids: ['owner-2'])
        searcher.search(query: 'thing', owner_ids: ['owner-3'])

        expect(described_class.db_cache.keys).not_to include('owner-1')
        expect(described_class.db_cache.keys).to include('owner-2', 'owner-3')
      end
    end

    context 'when owner has no version' do
      it 'skips owner without version entry' do
        allow(dynamodb).to receive(:get_item).and_return(double(item: nil))
        allow(s3).to receive(:get_object)

        result = searcher.search(query: 'test', owner_ids: ['owner-1'])
        expect(result).to be_nil
        expect(s3).not_to have_received(:get_object)
      end
    end

    context 'when S3 download fails' do
      it 'skips owner when database not found on S3' do
        allow(dynamodb).to receive(:get_item).and_return(double(item: { 'version' => 1 }))
        allow(s3).to receive(:get_object).and_raise(Aws::S3::Errors::NoSuchKey.new(nil, 'not found'))

        result = searcher.search(query: 'test', owner_ids: ['owner-1'])
        expect(result).to be_nil
      end
    end
  end
end
