# frozen_string_literal: true

require 'spec_helper'

RSpec.describe S3arch::Tokenizer do
  before do
    S3arch.configure do |c|
      c.searchable_fields = %w[name description]
    end
  end

  describe '#tokenize' do
    subject(:tokenizer) { described_class.new }

    it 'returns a hash of field => tokenized string' do
      result = tokenizer.tokenize('name' => 'Blue Chair', 'description' => 'Comfy seat')
      expect(result).to eq('name' => 'Blue Chair', 'description' => 'Comfy seat')
    end

    it 'handles nil values as empty strings' do
      result = tokenizer.tokenize('name' => nil, 'description' => 'test')
      expect(result).to eq('name' => '', 'description' => 'test')
    end

    it 'handles missing fields as empty strings' do
      result = tokenizer.tokenize({})
      expect(result).to eq('name' => '', 'description' => '')
    end

    it 'handles DynamoDB stream format (Hash with S key)' do
      result = tokenizer.tokenize('name' => { 'S' => 'Widget' }, 'description' => { 'S' => 'A thing' })
      expect(result).to eq('name' => 'Widget', 'description' => 'A thing')
    end

    it 'handles DynamoDB list format (Hash with L key)' do
      result = tokenizer.tokenize('name' => { 'L' => [{ 'S' => 'tag1' }, { 'S' => 'tag2' }] }, 'description' => 'x')
      expect(result).to eq('name' => 'tag1 tag2', 'description' => 'x')
    end

    it 'handles DynamoDB number format (Hash with N key)' do
      result = tokenizer.tokenize('name' => { 'N' => '42' }, 'description' => 'x')
      expect(result).to eq('name' => '42', 'description' => 'x')
    end

    it 'handles DynamoDB string set format (Hash with SS key)' do
      result = tokenizer.tokenize('name' => { 'SS' => %w[alpha beta] }, 'description' => 'x')
      expect(result).to eq('name' => 'alpha beta', 'description' => 'x')
    end

    it 'handles arrays of plain strings' do
      result = tokenizer.tokenize('name' => %w[foo bar], 'description' => 'x')
      expect(result).to eq('name' => 'foo bar', 'description' => 'x')
    end

    it 'handles numeric values' do
      result = tokenizer.tokenize('name' => 123, 'description' => 4.5)
      expect(result).to eq('name' => '123', 'description' => '4.5')
    end

    it 'uses custom fields from configuration' do
      tokenizer = described_class.new(fields: %w[title tags])
      result = tokenizer.tokenize('title' => 'Hello', 'tags' => 'world', 'name' => 'ignored')
      expect(result).to eq('title' => 'Hello', 'tags' => 'world')
    end
  end

  describe '#tokenize_flat' do
    subject(:tokenizer) { described_class.new }

    it 'concatenates all fields into a single string' do
      result = tokenizer.tokenize_flat('name' => 'Blue Chair', 'description' => 'Comfy')
      expect(result).to eq('Blue Chair Comfy')
    end

    it 'excludes empty fields' do
      result = tokenizer.tokenize_flat('name' => 'Only Name', 'description' => nil)
      expect(result).to eq('Only Name')
    end

    it 'returns empty string when all fields are nil' do
      result = tokenizer.tokenize_flat('name' => nil, 'description' => nil)
      expect(result).to eq('')
    end
  end
end
