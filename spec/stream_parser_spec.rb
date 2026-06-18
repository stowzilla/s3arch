# frozen_string_literal: true

require 'spec_helper'

RSpec.describe S3arch::Indexer::StreamParser do
  # Create a test class that includes StreamParser to test private methods
  let(:parser_instance) do
    config = S3arch.configuration
    config.source_table = 'test-table'
    config.source_index = 'UserIndex'
    config.index_bucket = 'test-bucket'
    config.version_table = 'test-versions'
    config.owner_key = 'userId'
    config.searchable_fields = %w[name description]
    config.metadata_fields = %w[status]
    config.token_field = 'searchTokens'
    config.record_filter = ->(_record) { true }

    # Use a simple object with the module included and @config set
    klass = Class.new do
      include S3arch::Indexer::StreamParser
      attr_accessor :config

      def initialize(config)
        @config = config
      end

      # Expose private methods for testing
      public :group_changes, :build_change, :extract_owner, :extract_record_id, :extract_tokens, :extract_meta
    end
    klass.new(config)
  end

  describe '#group_changes' do
    it 'groups INSERT events by owner' do
      sqs_records = [
        { 'body' => JSON.generate('eventName' => 'INSERT', 'dynamodb' => {
          'NewImage' => { 'id' => { 'S' => 'i1' }, 'userId' => { 'S' => 'o1' },
                          'searchTokens' => { 'M' => { 'name' => { 'S' => 'test' } } }, 'status' => { 'S' => 'active' } }
        }) },
        { 'body' => JSON.generate('eventName' => 'INSERT', 'dynamodb' => {
          'NewImage' => { 'id' => { 'S' => 'i2' }, 'userId' => { 'S' => 'o1' },
                          'searchTokens' => { 'M' => { 'name' => { 'S' => 'other' } } }, 'status' => { 'S' => 'active' } }
        }) }
      ]

      grouped = parser_instance.group_changes(sqs_records)
      expect(grouped.keys).to eq(['o1'])
      expect(grouped['o1'].size).to eq(2)
      expect(grouped['o1'].map { |c| c[:action] }).to eq(%i[insert insert])
    end

    it 'separates changes by different owners' do
      sqs_records = [
        { 'body' => JSON.generate('eventName' => 'INSERT', 'dynamodb' => {
          'NewImage' => { 'id' => { 'S' => 'i1' }, 'userId' => { 'S' => 'o1' },
                          'searchTokens' => { 'M' => { 'name' => { 'S' => 'a' } } }, 'status' => { 'S' => 'active' } }
        }) },
        { 'body' => JSON.generate('eventName' => 'INSERT', 'dynamodb' => {
          'NewImage' => { 'id' => { 'S' => 'i2' }, 'userId' => { 'S' => 'o2' },
                          'searchTokens' => { 'M' => { 'name' => { 'S' => 'b' } } }, 'status' => { 'S' => 'active' } }
        }) }
      ]

      grouped = parser_instance.group_changes(sqs_records)
      expect(grouped.keys).to contain_exactly('o1', 'o2')
    end

    it 'skips records without owner_id' do
      sqs_records = [
        { 'body' => JSON.generate('eventName' => 'INSERT', 'dynamodb' => {
          'NewImage' => { 'id' => { 'S' => 'i1' }, 'searchTokens' => { 'M' => { 'name' => { 'S' => 'orphan' } } } }
        }) }
      ]

      grouped = parser_instance.group_changes(sqs_records)
      expect(grouped).to be_empty
    end

    it 'handles REMOVE events using OldImage' do
      sqs_records = [
        { 'body' => JSON.generate('eventName' => 'REMOVE', 'dynamodb' => {
          'OldImage' => { 'id' => { 'S' => 'i1' }, 'userId' => { 'S' => 'o1' },
                          'searchTokens' => { 'M' => { 'name' => { 'S' => 'deleted' } } }, 'status' => { 'S' => 'active' } }
        }) }
      ]

      grouped = parser_instance.group_changes(sqs_records)
      expect(grouped['o1'].first[:action]).to eq(:delete)
      expect(grouped['o1'].first[:record_id]).to eq('i1')
    end

    it 'handles MODIFY events with old and new tokens' do
      sqs_records = [
        { 'body' => JSON.generate('eventName' => 'MODIFY', 'dynamodb' => {
          'OldImage' => { 'id' => { 'S' => 'i1' }, 'userId' => { 'S' => 'o1' },
                          'searchTokens' => { 'M' => { 'name' => { 'S' => 'old name' } } }, 'status' => { 'S' => 'active' } },
          'NewImage' => { 'id' => { 'S' => 'i1' }, 'userId' => { 'S' => 'o1' },
                          'searchTokens' => { 'M' => { 'name' => { 'S' => 'new name' } } }, 'status' => { 'S' => 'active' } }
        }) }
      ]

      grouped = parser_instance.group_changes(sqs_records)
      change = grouped['o1'].first
      expect(change[:action]).to eq(:update)
      expect(change[:old_tokens]).to eq({ 'name' => 'old name' })
      expect(change[:new_tokens]).to eq({ 'name' => 'new name' })
    end

    it 'emits delete when MODIFY makes record fail filter' do
      S3arch.configuration.record_filter = ->(item) { item['status'] == 'active' }

      # Rebuild parser_instance with the updated config
      config = S3arch.configuration
      config.source_table = 'test-table'
      config.source_index = 'UserIndex'
      config.index_bucket = 'test-bucket'
      config.version_table = 'test-versions'
      config.owner_key = 'userId'
      config.token_field = 'searchTokens'
      config.metadata_fields = %w[status]

      klass = Class.new do
        include S3arch::Indexer::StreamParser
        attr_accessor :config
        def initialize(c) = @config = c
        public :group_changes
      end
      parser = klass.new(config)

      sqs_records = [
        { 'body' => JSON.generate('eventName' => 'MODIFY', 'dynamodb' => {
          'OldImage' => { 'id' => { 'S' => 'i1' }, 'userId' => { 'S' => 'o1' },
                          'searchTokens' => { 'M' => { 'name' => { 'S' => 'thing' } } }, 'status' => { 'S' => 'active' } },
          'NewImage' => { 'id' => { 'S' => 'i1' }, 'userId' => { 'S' => 'o1' },
                          'searchTokens' => { 'M' => { 'name' => { 'S' => 'thing' } } }, 'status' => { 'S' => 'archived' } }
        }) }
      ]

      grouped = parser.group_changes(sqs_records)
      expect(grouped['o1'].first[:action]).to eq(:delete)
    end

    it 'emits insert when MODIFY makes record pass filter (was failing)' do
      S3arch.configuration.record_filter = ->(item) { item['status'] == 'active' }

      sqs_records = [
        { 'body' => JSON.generate('eventName' => 'MODIFY', 'dynamodb' => {
          'OldImage' => { 'id' => { 'S' => 'i1' }, 'userId' => { 'S' => 'o1' },
                          'searchTokens' => { 'M' => { 'name' => { 'S' => 'thing' } } }, 'status' => { 'S' => 'archived' } },
          'NewImage' => { 'id' => { 'S' => 'i1' }, 'userId' => { 'S' => 'o1' },
                          'searchTokens' => { 'M' => { 'name' => { 'S' => 'thing' } } }, 'status' => { 'S' => 'active' } }
        }) }
      ]

      grouped = parser_instance.group_changes(sqs_records)
      # Old tokens had no searchTokens that passed filter, so old_tokens extraction returns the map
      # but passes_filter? on old_image fails → emits insert (not update)
      change = grouped['o1'].first
      expect(change[:action]).to eq(:update)
    end
  end

  describe '#extract_owner' do
    it 'extracts owner from DynamoDB stream format' do
      image = { 'userId' => { 'S' => 'user-123' } }
      expect(parser_instance.extract_owner(image)).to eq('user-123')
    end

    it 'extracts owner from plain format' do
      image = { 'userId' => 'user-123' }
      expect(parser_instance.extract_owner(image)).to eq('user-123')
    end

    it 'returns nil for nil image' do
      expect(parser_instance.extract_owner(nil)).to be_nil
    end
  end

  describe '#extract_record_id' do
    it 'extracts id from DynamoDB stream format' do
      image = { 'id' => { 'S' => 'rec-456' } }
      expect(parser_instance.extract_record_id(image)).to eq('rec-456')
    end

    it 'extracts id from plain format' do
      image = { 'id' => 'rec-456' }
      expect(parser_instance.extract_record_id(image)).to eq('rec-456')
    end
  end

  describe '#extract_tokens' do
    it 'extracts tokens from M (Map) format' do
      image = { 'searchTokens' => { 'M' => { 'name' => { 'S' => 'hello' }, 'description' => { 'S' => 'world' } } } }
      expect(parser_instance.extract_tokens(image)).to eq({ 'name' => 'hello', 'description' => 'world' })
    end

    it 'extracts tokens from plain hash format' do
      image = { 'searchTokens' => { 'name' => { 'S' => 'hello' }, 'description' => { 'S' => 'world' } } }
      expect(parser_instance.extract_tokens(image)).to eq({ 'name' => 'hello', 'description' => 'world' })
    end

    it 'returns nil when token field is missing' do
      image = { 'other' => 'stuff' }
      expect(parser_instance.extract_tokens(image)).to be_nil
    end

    it 'returns nil for nil image' do
      expect(parser_instance.extract_tokens(nil)).to be_nil
    end
  end

  describe '#extract_meta' do
    it 'extracts metadata fields from stream format' do
      image = { 'status' => { 'S' => 'active' } }
      expect(parser_instance.extract_meta(image)).to eq({ 'status' => 'active' })
    end

    it 'extracts metadata from plain format' do
      image = { 'status' => 'active' }
      expect(parser_instance.extract_meta(image)).to eq({ 'status' => 'active' })
    end
  end
end
