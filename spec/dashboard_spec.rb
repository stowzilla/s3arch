# frozen_string_literal: true

require 'spec_helper'
require 'rack/test'
require 'ostruct'

RSpec.describe S3arch::Dashboard::Application do
  include Rack::Test::Methods

  let(:app) { described_class.new }

  before do
    S3arch.configure do |c|
      c.source_table = 'test-table'
      c.source_index = 'UserIndex'
      c.index_bucket = 'test-bucket'
      c.version_table = 'test-versions'
    end
  end

  describe 'GET /' do
    it 'renders the index page' do
      dynamodb = instance_double(Aws::DynamoDB::Client)
      allow(Aws::DynamoDB::Client).to receive(:new).and_return(dynamodb)
      allow(dynamodb).to receive(:scan).and_return(
        OpenStruct.new(items: [{ 'user_id' => 'user-1', 'version' => 3, 'record_count' => 42,
                                 'updated_at' => '2026-01-01T00:00:00Z' }], last_evaluated_key: nil)
      )

      get '/'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('user-1')
      expect(last_response.body).to include('42')
    end

    it 'handles errors gracefully' do
      allow(Aws::DynamoDB::Client).to receive(:new).and_raise(StandardError, 'connection failed')

      get '/'
      expect(last_response.status).to eq(200)
      expect(last_response.body).to include('connection failed')
    end
  end

  describe 'POST /rebuild' do
    it 'triggers a rebuild and redirects' do
      indexer = instance_double(S3arch::Indexer)
      allow(S3arch::Indexer).to receive(:new).and_return(indexer)
      allow(indexer).to receive(:rebuild)

      post '/rebuild', owner_id: 'user-1'
      expect(last_response.status).to eq(303)
      expect(indexer).to have_received(:rebuild).with('user-1')
    end
  end

  describe 'GET /unknown' do
    it 'returns 404' do
      get '/unknown'
      expect(last_response.status).to eq(404)
    end
  end
end
