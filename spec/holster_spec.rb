# frozen_string_literal: true

require 'spec_helper'

# Simulate Belt being loaded
module Belt
  class Holster
    class << self
      def gem_root
        @gem_root ||= File.expand_path('../..', caller_locations(1, 1).first.path)
      end
    end
  end

  @holsters = []

  class << self
    attr_reader :holsters
  end
end

require_relative '../lib/s3arch/holster'

RSpec.describe S3arch::Holster do
  it 'inherits from Belt::Holster' do
    expect(described_class.superclass).to eq(Belt::Holster)
  end
end
