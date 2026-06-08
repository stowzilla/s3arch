# frozen_string_literal: true

require 'spec_helper'

RSpec.describe S3arch::Configuration do
  subject(:config) { S3arch.configuration }

  it 'has sensible defaults' do
    expect(config.owner_key).to eq('user_id')
    expect(config.searchable_fields).to eq(%w[name description])
    expect(config.max_results).to eq(50)
    expect(config.max_cached_dbs).to eq(20)
    expect(config.version_ttl).to eq(30)
  end

  it 'validates required fields' do
    expect { config.validate! }.to raise_error(S3arch::Error, /source_table/)
  end

  it 'passes validation when configured' do
    config.source_table = 'my-table'
    config.source_index = 'UserIndex'
    config.index_bucket = 'my-bucket'
    config.version_table = 'my-versions'
    expect { config.validate! }.not_to raise_error
  end

  it 'reads from environment variables' do
    ENV['S3ARCH_SOURCE_TABLE'] = 'env-table'
    ENV['S3ARCH_INDEX_BUCKET'] = 'env-bucket'
    ENV['S3ARCH_VERSION_TABLE'] = 'env-versions'

    config.from_env!

    expect(config.source_table).to eq('env-table')
    expect(config.index_bucket).to eq('env-bucket')
    expect(config.version_table).to eq('env-versions')
    expect(config.source_index).to eq('UserIndex')
  ensure
    ENV.delete('S3ARCH_SOURCE_TABLE')
    ENV.delete('S3ARCH_INDEX_BUCKET')
    ENV.delete('S3ARCH_VERSION_TABLE')
  end
end
