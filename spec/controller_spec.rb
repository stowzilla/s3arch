# frozen_string_literal: true

require 'spec_helper'

RSpec.describe S3arch::Dashboard::Controller do
  let(:controller_class) do
    Class.new do
      include S3arch::Dashboard::Controller

      attr_reader :response_body, :response_error

      def initialize(params = {})
        @params = params
      end

      attr_reader :params

      def success_response(data)
        @response_body = data
      end

      def error_response(msg)
        @response_error = msg
      end
    end
  end

  before do
    S3arch.configure do |c|
      c.source_table = 'test-table'
      c.source_index = 'UserIndex'
      c.index_bucket = 'test-bucket'
      c.version_table = 'test-versions'
      c.owner_key = 'userId'
    end
  end

  describe '#index' do
    it 'returns owners from the version table' do
      dynamodb = instance_double(Aws::DynamoDB::Client)
      allow(Aws::DynamoDB::Client).to receive(:new).and_return(dynamodb)
      allow(dynamodb).to receive(:scan).and_return(
        double(items: [{ 'userId' => 'u1', 'version' => 2, 'record_count' => 10, 'updated_at' => '2026-01-01' }],
               last_evaluated_key: nil)
      )

      ctrl = controller_class.new
      ctrl.index

      expect(ctrl.response_body[:owners]).to eq([
                                                  { owner_id: 'u1', version: 2, record_count: 10,
                                                    updated_at: '2026-01-01' }
                                                ])
    end
  end

  describe '#rebuild' do
    it 'rebuilds the index for the given owner' do
      indexer = instance_double(S3arch::Indexer)
      allow(S3arch::Indexer).to receive(:new).and_return(indexer)
      allow(indexer).to receive(:rebuild)

      ctrl = controller_class.new('owner_id' => 'u1')
      ctrl.rebuild

      expect(indexer).to have_received(:rebuild).with('u1')
      expect(ctrl.response_body).to eq(status: 'ok', owner_id: 'u1')
    end

    it 'returns error when owner_id is missing' do
      ctrl = controller_class.new({})
      ctrl.rebuild

      expect(ctrl.response_error).to eq('owner_id is required')
    end
  end
end
