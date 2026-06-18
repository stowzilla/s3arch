# frozen_string_literal: true

require 'spec_helper'
require_relative '../lambda/models/search_version'

RSpec.describe S3arch::Models::SearchVersion do
  let(:dynamodb) { instance_double(Aws::DynamoDB::Client) }

  before do
    S3arch.configure do |c|
      c.source_table = 'test-items'
      c.source_index = 'UserIndex'
      c.index_bucket = 'test-bucket'
      c.version_table = 'test-versions'
      c.owner_key = 'userId'
    end
    allow(Aws::DynamoDB::Client).to receive(:new).and_return(dynamodb)
  end

  describe '.all' do
    it 'returns SearchVersion instances sorted by updated_at descending' do
      items = [
        { 'userId' => 'u1', 'version' => 3, 'record_count' => 10, 'updated_at' => '2026-01-01' },
        { 'userId' => 'u2', 'version' => 7, 'record_count' => 25, 'updated_at' => '2026-06-01' }
      ]
      allow(dynamodb).to receive(:scan).and_return(double(items: items, last_evaluated_key: nil))

      results = described_class.all

      expect(results.size).to eq(2)
      expect(results.first.owner_id).to eq('u2')
      expect(results.first.version).to eq(7)
      expect(results.last.owner_id).to eq('u1')
    end

    it 'paginates through all pages' do
      page1 = double(items: [{ 'userId' => 'u1', 'version' => 1, 'record_count' => 5, 'updated_at' => '2026-01-01' }],
                     last_evaluated_key: { 'userId' => 'u1' })
      page2 = double(items: [{ 'userId' => 'u2', 'version' => 2, 'record_count' => 8, 'updated_at' => '2026-02-01' }],
                     last_evaluated_key: nil)
      allow(dynamodb).to receive(:scan).and_return(page1, page2)

      results = described_class.all

      expect(results.size).to eq(2)
    end
  end

  describe '.find' do
    it 'returns the version number' do
      allow(dynamodb).to receive(:get_item).and_return(double(item: { 'version' => 12 }))

      expect(described_class.find('u1')).to eq(12)
    end

    it 'returns nil when not found' do
      allow(dynamodb).to receive(:get_item).and_return(double(item: nil))

      expect(described_class.find('u1')).to be_nil
    end
  end

  describe '.increment!' do
    it 'updates DynamoDB with atomic increment' do
      allow(dynamodb).to receive(:update_item)

      described_class.increment!('u1', record_count: 50)

      expect(dynamodb).to have_received(:update_item).with(hash_including(
                                                             table_name: 'test-versions',
                                                             key: { 'userId' => 'u1' },
                                                             expression_attribute_values: hash_including(':count' => 50)
                                                           ))
    end
  end

  describe '#to_h' do
    it 'returns a hash with string version' do
      sv = described_class.new(owner_id: 'u1', version: 42, record_count: 10, updated_at: '2026-01-01')

      expect(sv.to_h).to eq(owner_id: 'u1', version: '42', record_count: 10, updated_at: '2026-01-01')
    end
  end
end
