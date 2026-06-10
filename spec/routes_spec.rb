# frozen_string_literal: true

require 'spec_helper'
require 's3arch/routes'

RSpec.describe S3arch::Routes do
  describe '.routes' do
    it 'returns route definitions for mount DSL' do
      routes = described_class.routes

      expect(routes).to contain_exactly(
        { method: :get, path: '/' },
        { method: :post, path: '/rebuild' }
      )
    end
  end
end
