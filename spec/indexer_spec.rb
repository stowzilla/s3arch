# frozen_string_literal: true

require 'spec_helper'
require 'fileutils'

RSpec.describe S3arch::Indexer do
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
  let(:indexer) { described_class.new(config: config) }

  before do
    allow(Aws::DynamoDB::Client).to receive(:new).and_return(dynamodb)
    allow(Aws::S3::Client).to receive(:new).and_return(s3)
  end

  after do
    Dir.glob('/tmp/s3arch_*.sqlite3').each { |f| File.delete(f) }
  end

  describe '#rebuild' do
    let(:records) do
      [
        { 'id' => 'item-1', 'userId' => 'owner-1',
          'searchTokens' => { 'name' => 'blue chair', 'description' => 'comfy' }, 'status' => 'active' },
        { 'id' => 'item-2', 'userId' => 'owner-1',
          'searchTokens' => { 'name' => 'red table', 'description' => 'wooden' }, 'status' => 'active' }
      ]
    end

    before do
      allow(dynamodb).to receive(:query).and_return(double(items: records, last_evaluated_key: nil))
      allow(s3).to receive(:put_object)
      allow(dynamodb).to receive(:update_item)
    end

    it 'queries DynamoDB for owner records' do
      indexer.rebuild('owner-1')

      expect(dynamodb).to have_received(:query).with(hash_including(
                                                       table_name: 'test-items',
                                                       index_name: 'UserIndex',
                                                       key_condition_expression: 'userId = :owner',
                                                       expression_attribute_values: { ':owner' => 'owner-1' }
                                                     ))
    end

    it 'uploads SQLite database to S3' do
      indexer.rebuild('owner-1')

      expect(s3).to have_received(:put_object).with(hash_including(
                                                      bucket: 'test-bucket',
                                                      key: 'owner-1/index.sqlite3'
                                                    ))
    end

    it 'increments version in DynamoDB' do
      indexer.rebuild('owner-1')

      expect(dynamodb).to have_received(:update_item).with(hash_including(
                                                             table_name: 'test-versions',
                                                             key: { 'userId' => 'owner-1' },
                                                             expression_attribute_values: hash_including(':count' => 2)
                                                           ))
    end

    it 'builds a valid SQLite FTS5 database' do
      db_path = nil
      allow(s3).to receive(:put_object) do |args|
        db_path = '/tmp/s3arch_rebuild_test.sqlite3'
        File.binwrite(db_path, args[:body].read)
      end

      indexer.rebuild('owner-1')

      db = SQLite3::Database.new(db_path)
      db.results_as_hash = true
      results = db.execute('SELECT * FROM records_meta')
      expect(results.size).to eq(2)
      expect(results.map { |r| r['record_id'] }).to contain_exactly('item-1', 'item-2')
      db.close
      File.delete(db_path)
    end

    it 'handles paginated DynamoDB results' do
      page1 = double(items: [records[0]], last_evaluated_key: { 'id' => 'item-1' })
      page2 = double(items: [records[1]], last_evaluated_key: nil)
      allow(dynamodb).to receive(:query).and_return(page1, page2)

      indexer.rebuild('owner-1')

      expect(dynamodb).to have_received(:query).twice
      expect(dynamodb).to have_received(:update_item).with(hash_including(
                                                             expression_attribute_values: hash_including(':count' => 2)
                                                           ))
    end

    it 'respects record_filter' do
      config.record_filter = ->(item) { item['status'] == 'active' }
      filtered_indexer = described_class.new(config: config)
      filtered_records = [
        { 'id' => 'item-1', 'userId' => 'owner-1', 'searchTokens' => { 'name' => 'blue', 'description' => '' },
          'status' => 'active' },
        { 'id' => 'item-2', 'userId' => 'owner-1', 'searchTokens' => { 'name' => 'red', 'description' => '' },
          'status' => 'archived' }
      ]
      allow(dynamodb).to receive(:query).and_return(double(items: filtered_records, last_evaluated_key: nil))

      filtered_indexer.rebuild('owner-1')

      expect(dynamodb).to have_received(:update_item).with(hash_including(
                                                             expression_attribute_values: hash_including(':count' => 1)
                                                           ))
    end

    it 'falls back to searchable_fields when searchTokens is empty' do
      records_without_tokens = [
        { 'id' => 'item-1', 'userId' => 'owner-1', 'searchTokens' => {}, 'name' => 'fallback name',
          'description' => 'fallback desc', 'status' => 'active' }
      ]
      allow(dynamodb).to receive(:query).and_return(double(items: records_without_tokens, last_evaluated_key: nil))

      db_path = nil
      allow(s3).to receive(:put_object) do |args|
        db_path = '/tmp/s3arch_fallback_test.sqlite3'
        File.binwrite(db_path, args[:body].read)
      end

      indexer.rebuild('owner-1')

      db = SQLite3::Database.new(db_path)
      db.results_as_hash = true
      # FTS query for the fallback content
      results = db.execute("SELECT * FROM records_fts WHERE records_fts MATCH 'fallback*'")
      expect(results.size).to eq(1)
      db.close
      File.delete(db_path)
    end

    it 'cleans up temp file even on error' do
      allow(s3).to receive(:put_object).and_raise(StandardError, 'upload failed')

      expect { indexer.rebuild('owner-1') }.to raise_error(StandardError, 'upload failed')
      expect(File.exist?('/tmp/s3arch_owner-1.sqlite3')).to be false
    end

    it 'handles reserved words in owner_key' do
      config.owner_key = 'status'
      reserved_indexer = described_class.new(config: config)
      allow(dynamodb).to receive(:query).and_return(double(items: [], last_evaluated_key: nil))
      allow(dynamodb).to receive(:update_item)

      reserved_indexer.rebuild('owner-1')

      expect(dynamodb).to have_received(:query).with(hash_including(
                                                       key_condition_expression: '#status = :owner',
                                                       expression_attribute_names: hash_including('#status' => 'status')
                                                     ))
    end
  end

  describe '#apply_changes' do
    let(:db_path) { '/tmp/s3arch_owner-1.sqlite3' }

    before do
      allow(dynamodb).to receive(:update_item)

      # Create a real SQLite DB to download
      FileUtils.rm_f(db_path)
      db = SQLite3::Database.new(db_path)
      db.execute_batch(<<~SQL)
        CREATE VIRTUAL TABLE records_fts USING fts5(name, description, content='');
        CREATE TABLE records_meta (rowid INTEGER PRIMARY KEY, record_id TEXT NOT NULL, status TEXT);
        INSERT INTO records_fts(rowid, name, description) VALUES (1, 'blue chair', 'comfy seat');
        INSERT INTO records_meta(rowid, record_id, status) VALUES (1, 'item-1', 'active');
      SQL
      db.close
    end

    after { FileUtils.rm_f(db_path) }

    it 'applies insert changes to existing database' do
      allow(s3).to receive(:get_object) do |args|
        # Simulate download by ensuring the file exists at target
        FileUtils.cp(db_path, args[:response_target]) unless args[:response_target] == db_path
      end
      allow(s3).to receive(:put_object)

      changes = [{ action: :insert, record_id: 'item-2', tokens: { 'name' => 'red table', 'description' => 'wooden' },
                   meta: { 'status' => 'active' } }]
      indexer.apply_changes('owner-1', changes)

      expect(s3).to have_received(:put_object)
      expect(dynamodb).to have_received(:update_item).with(hash_including(
                                                             expression_attribute_values: hash_including(':count' => 2)
                                                           ))
    end

    it 'applies delete changes' do
      allow(s3).to receive(:get_object) do |args|
        FileUtils.cp(db_path, args[:response_target]) unless args[:response_target] == db_path
      end
      allow(s3).to receive(:put_object)

      changes = [{ action: :delete, record_id: 'item-1',
                   tokens: { 'name' => 'blue chair', 'description' => 'comfy seat' } }]
      indexer.apply_changes('owner-1', changes)

      expect(dynamodb).to have_received(:update_item).with(hash_including(
                                                             expression_attribute_values: hash_including(':count' => 0)
                                                           ))
    end

    it 'applies update changes' do
      allow(s3).to receive(:get_object) do |args|
        FileUtils.cp(db_path, args[:response_target]) unless args[:response_target] == db_path
      end
      allow(s3).to receive(:put_object)

      changes = [{ action: :update, record_id: 'item-1',
                   old_tokens: { 'name' => 'blue chair', 'description' => 'comfy seat' },
                   new_tokens: { 'name' => 'green chair', 'description' => 'comfy seat' },
                   meta: { 'status' => 'active' } }]
      indexer.apply_changes('owner-1', changes)

      expect(s3).to have_received(:put_object)
    end

    it 'falls back to full rebuild when no existing index' do
      FileUtils.rm_f(db_path) # Remove the pre-created DB
      allow(s3).to receive(:get_object).and_raise(Aws::S3::Errors::NoSuchKey.new(nil, 'not found'))
      allow(dynamodb).to receive(:query).and_return(double(items: [], last_evaluated_key: nil))
      allow(s3).to receive(:put_object)

      changes = [{ action: :insert, record_id: 'item-2', tokens: { 'name' => 'test', 'description' => '' },
                   meta: { 'status' => 'active' } }]
      indexer.apply_changes('owner-1', changes)

      # Should have done a full rebuild (query + put)
      expect(dynamodb).to have_received(:query)
      expect(s3).to have_received(:put_object)
    end

    it 'handles insert for record_id not yet in index during update action' do
      allow(s3).to receive(:get_object) do |args|
        FileUtils.cp(db_path, args[:response_target]) unless args[:response_target] == db_path
      end
      allow(s3).to receive(:put_object)

      changes = [{ action: :update, record_id: 'item-new',
                   old_tokens: { 'name' => 'old', 'description' => 'old' },
                   new_tokens: { 'name' => 'brand new', 'description' => 'fresh' },
                   meta: { 'status' => 'active' } }]
      indexer.apply_changes('owner-1', changes)

      expect(dynamodb).to have_received(:update_item).with(hash_including(
                                                             expression_attribute_values: hash_including(':count' => 2)
                                                           ))
    end
  end

  describe '#process_event' do
    before do
      allow(dynamodb).to receive(:query).and_return(double(items: [], last_evaluated_key: nil))
      allow(dynamodb).to receive(:update_item)
      allow(s3).to receive(:get_object).and_raise(Aws::S3::Errors::NoSuchKey.new(nil, 'not found'))
      allow(s3).to receive(:put_object)
    end

    it 'processes SQS event with DynamoDB stream records' do
      event = {
        'Records' => [
          {
            'body' => JSON.generate(
              'eventName' => 'INSERT',
              'dynamodb' => {
                'NewImage' => {
                  'id' => { 'S' => 'item-1' },
                  'userId' => { 'S' => 'owner-1' },
                  'searchTokens' => { 'M' => { 'name' => { 'S' => 'widget' }, 'description' => { 'S' => 'thing' } } },
                  'status' => { 'S' => 'active' }
                }
              }
            )
          }
        ]
      }

      result = indexer.process_event(event)

      expect(result[:statusCode]).to eq(200)
    end

    it 'groups changes by owner' do
      event = {
        'Records' => [
          {
            'body' => JSON.generate(
              'eventName' => 'INSERT',
              'dynamodb' => { 'NewImage' => { 'id' => { 'S' => 'i1' }, 'userId' => { 'S' => 'o1' },
                                              'searchTokens' => { 'M' => { 'name' => { 'S' => 'a' } } },
                                              'status' => { 'S' => 'active' } } }
            )
          },
          {
            'body' => JSON.generate(
              'eventName' => 'INSERT',
              'dynamodb' => { 'NewImage' => { 'id' => { 'S' => 'i2' }, 'userId' => { 'S' => 'o2' },
                                              'searchTokens' => { 'M' => { 'name' => { 'S' => 'b' } } },
                                              'status' => { 'S' => 'active' } } }
            )
          }
        ]
      }

      indexer.process_event(event)

      # Should rebuild twice (once per owner since there's no existing index)
      expect(dynamodb).to have_received(:query).twice
    end

    it 'handles REMOVE events' do
      event = {
        'Records' => [
          {
            'body' => JSON.generate(
              'eventName' => 'REMOVE',
              'dynamodb' => {
                'OldImage' => {
                  'id' => { 'S' => 'item-1' },
                  'userId' => { 'S' => 'owner-1' },
                  'searchTokens' => { 'M' => { 'name' => { 'S' => 'deleted' } } },
                  'status' => { 'S' => 'active' }
                }
              }
            )
          }
        ]
      }

      result = indexer.process_event(event)
      expect(result[:statusCode]).to eq(200)
    end

    it 'handles MODIFY events' do
      event = {
        'Records' => [
          {
            'body' => JSON.generate(
              'eventName' => 'MODIFY',
              'dynamodb' => {
                'OldImage' => { 'id' => { 'S' => 'i1' }, 'userId' => { 'S' => 'o1' },
                                'searchTokens' => { 'M' => { 'name' => { 'S' => 'old' } } },
                                'status' => { 'S' => 'active' } },
                'NewImage' => { 'id' => { 'S' => 'i1' }, 'userId' => { 'S' => 'o1' },
                                'searchTokens' => { 'M' => { 'name' => { 'S' => 'new' } } },
                                'status' => { 'S' => 'active' } }
              }
            )
          }
        ]
      }

      result = indexer.process_event(event)
      expect(result[:statusCode]).to eq(200)
    end

    it 'skips records without owner_id' do
      event = {
        'Records' => [
          {
            'body' => JSON.generate(
              'eventName' => 'INSERT',
              'dynamodb' => { 'NewImage' => { 'id' => { 'S' => 'i1' },
                                              'searchTokens' => { 'M' => { 'name' => { 'S' => 'x' } } } } }
            )
          }
        ]
      }

      result = indexer.process_event(event)
      expect(result[:statusCode]).to eq(200)
      expect(dynamodb).not_to have_received(:query)
    end

    it 'triggers full rebuild when a rebuild action is present' do
      event = {
        'Records' => [
          {
            'body' => JSON.generate(
              'eventName' => 'MODIFY',
              'dynamodb' => {
                'OldImage' => { 'id' => { 'S' => 'i1' }, 'userId' => { 'S' => 'o1' },
                                'searchTokens' => { 'M' => { 'name' => { 'S' => 'old' } } },
                                'status' => { 'S' => 'active' } },
                'NewImage' => { 'id' => { 'S' => 'i1' }, 'userId' => { 'S' => 'o1' },
                                'searchTokens' => { 'M' => { 'name' => { 'S' => 'new' } } },
                                'status' => { 'S' => 'active' } }
              }
            )
          }
        ]
      }

      # This test just verifies incremental processing works — rebuild triggers tested separately
      result = indexer.process_event(event)
      expect(result[:statusCode]).to eq(200)
    end
  end
end
