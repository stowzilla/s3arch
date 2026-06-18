# frozen_string_literal: true

require 'spec_helper'

RSpec.describe S3arch::Store do
  let(:config) do
    S3arch.configure do |c|
      c.source_table = 'test-items'
      c.source_index = 'UserIndex'
      c.index_bucket = 'test-bucket'
      c.version_table = 'test-versions'
      c.owner_key = 'userId'
      c.searchable_fields = %w[name description]
      c.metadata_fields = %w[status]
      c.token_field = 'searchTokens'
      c.filter_fields = %w[status]
      c.record_filter = ->(_record) { true }
    end
    S3arch.configuration
  end

  let(:dynamodb) { instance_double(Aws::DynamoDB::Client) }
  let(:s3) { instance_double(Aws::S3::Client) }
  let(:store) { described_class.new(config: config) }

  before do
    allow(Aws::DynamoDB::Client).to receive(:new).and_return(dynamodb)
    allow(Aws::S3::Client).to receive(:new).and_return(s3)
  end

  describe '#fetch_records' do
    it 'queries DynamoDB and returns parsed records' do
      items = [
        { 'id' => 'item-1', 'userId' => 'owner-1', 'searchTokens' => { 'name' => 'blue chair', 'description' => 'comfy' }, 'status' => 'active' }
      ]
      allow(dynamodb).to receive(:query).and_return(double(items: items, last_evaluated_key: nil))

      records = store.fetch_records('owner-1')

      expect(records.size).to eq(1)
      expect(records.first['id']).to eq('item-1')
      expect(records.first['tokens']).to eq('name' => 'blue chair', 'description' => 'comfy')
      expect(records.first['meta']).to eq('status' => 'active')
    end

    it 'filters records using config.record_filter' do
      config.record_filter = ->(r) { r['status'] != 'deleted' }
      items = [
        { 'id' => 'item-1', 'searchTokens' => { 'name' => 'good' }, 'status' => 'active' },
        { 'id' => 'item-2', 'searchTokens' => { 'name' => 'bad' }, 'status' => 'deleted' }
      ]
      allow(dynamodb).to receive(:query).and_return(double(items: items, last_evaluated_key: nil))

      records = store.fetch_records('owner-1')

      expect(records.size).to eq(1)
      expect(records.first['id']).to eq('item-1')
    end

    it 'falls back to searchable_fields when token_field is absent' do
      items = [{ 'id' => 'item-1', 'userId' => 'owner-1', 'name' => 'jacket', 'description' => 'warm', 'status' => 'active' }]
      allow(dynamodb).to receive(:query).and_return(double(items: items, last_evaluated_key: nil))

      records = store.fetch_records('owner-1')

      expect(records.first['tokens']).to eq('name' => 'jacket', 'description' => 'warm')
    end

    it 'paginates through all results' do
      page1 = double(items: [{ 'id' => 'i1', 'searchTokens' => { 'name' => 'a' }, 'status' => '' }], last_evaluated_key: { 'id' => 'i1' })
      page2 = double(items: [{ 'id' => 'i2', 'searchTokens' => { 'name' => 'b' }, 'status' => '' }], last_evaluated_key: nil)
      allow(dynamodb).to receive(:query).and_return(page1, page2)

      records = store.fetch_records('owner-1')

      expect(records.size).to eq(2)
    end
  end

  describe '#upload_index' do
    it 'puts the file to S3 with correct key' do
      allow(s3).to receive(:put_object)
      db_path = '/tmp/s3arch_test.sqlite3'
      File.write(db_path, 'test')

      store.upload_index('owner-1', db_path)

      expect(s3).to have_received(:put_object).with(hash_including(
                                                      bucket: 'test-bucket', key: 'owner-1/index.sqlite3'
                                                    ))
    ensure
      File.delete(db_path) if File.exist?(db_path)
    end
  end

  describe '#download_index' do
    it 'returns true when file exists' do
      allow(s3).to receive(:get_object)

      result = store.download_index('owner-1', '/tmp/s3arch_test.sqlite3')

      expect(result).to be true
    end

    it 'returns false when file does not exist' do
      allow(s3).to receive(:get_object).and_raise(Aws::S3::Errors::NoSuchKey.new(nil, 'not found'))

      result = store.download_index('owner-1', '/tmp/s3arch_test.sqlite3')

      expect(result).to be false
    end
  end

  describe '#fetch_version' do
    it 'returns the version integer' do
      allow(dynamodb).to receive(:get_item).and_return(double(item: { 'version' => 5 }))

      expect(store.fetch_version('owner-1')).to eq(5)
    end

    it 'returns nil when no record exists' do
      allow(dynamodb).to receive(:get_item).and_return(double(item: nil))

      expect(store.fetch_version('owner-1')).to be_nil
    end
  end

  describe '#increment_version' do
    it 'calls update_item with atomic increment' do
      allow(dynamodb).to receive(:update_item)

      store.increment_version('owner-1', 42)

      expect(dynamodb).to have_received(:update_item).with(hash_including(
                                                             table_name: 'test-versions',
                                                             key: { 'userId' => 'owner-1' },
                                                             expression_attribute_values: hash_including(':count' => 42)
                                                           ))
    end
  end
end
