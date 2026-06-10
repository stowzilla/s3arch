# frozen_string_literal: true

require 'spec_helper'

# Simulate belt being loaded — define BeltController::Base with the interface
# that our controller expects, then require the controller file.
require 'json'

module BeltController
  class Base
    include Belt::Helpers::Response if defined?(Belt::Helpers::Response)

    attr_reader :event, :body

    class << self
      def before_actions
        @before_actions ||= []
      end

      def before_action(method_name, only: nil, except: nil)
        before_actions << { method: method_name, only: only&.map(&:to_sym), except: except&.map(&:to_sym) }
      end

      def skipped_before_actions
        @skipped_before_actions ||= []
      end

      def skip_before_action(method_name, only: nil, except: nil)
        skipped_before_actions << { method: method_name, only: only&.map(&:to_sym), except: except&.map(&:to_sym) }
      end

      def all_before_actions
        if superclass.respond_to?(:all_before_actions)
          superclass.all_before_actions + before_actions
        else
          before_actions
        end
      end

      def all_skipped_before_actions
        if superclass.respond_to?(:all_skipped_before_actions)
          superclass.all_skipped_before_actions + skipped_before_actions
        else
          skipped_before_actions
        end
      end
    end

    def initialize(event:, body:)
      @event = event
      @raw_body = body || {}
    end

    def params
      @params ||= @raw_body
    end

    def dispatch(action_name)
      send(action_name)
    end

    def success_response(body, _status_code = 200)
      { statusCode: 200, headers: { 'Content-Type' => 'application/json' }, body: JSON.generate(body) }
    end

    def error_response(message, status_code = 400)
      { statusCode: status_code, headers: { 'Content-Type' => 'application/json' }, body: JSON.generate(error: message) }
    end
  end
end

# Now require the controller (BeltController::Base is defined)
require_relative '../lib/s3arch/dashboard/controller'

RSpec.describe S3arch::Dashboard::S3archController do
  let(:event) do
    { 'requestContext' => { 'authorizer' => { 'claims' => { 'sub' => 'user-1' } } } }
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

      ctrl = described_class.new(event: event, body: {})
      result = ctrl.dispatch(:index)

      expect(result[:statusCode]).to eq(200)
      body = JSON.parse(result[:body])
      expect(body['owners'].first['owner_id']).to eq('u1')
    end
  end

  describe '#rebuild' do
    it 'rebuilds the index for the given owner' do
      indexer = instance_double(S3arch::Indexer)
      allow(S3arch::Indexer).to receive(:new).and_return(indexer)
      allow(indexer).to receive(:rebuild)

      ctrl = described_class.new(event: event, body: { 'owner_id' => 'u1' })
      result = ctrl.dispatch(:rebuild)

      expect(indexer).to have_received(:rebuild).with('u1')
      expect(result[:statusCode]).to eq(200)
    end

    it 'returns error when owner_id is missing' do
      ctrl = described_class.new(event: event, body: {})
      result = ctrl.dispatch(:rebuild)

      expect(result[:statusCode]).to eq(400)
    end
  end
end
