# frozen_string_literal: true

require_relative 'lib/s3arch/version'

Gem::Specification.new do |spec|
  spec.name    = 's3arch'
  spec.version = S3arch::VERSION
  spec.authors = ['Adam Dalton']
  spec.email   = ['adam@stowzilla.com']

  spec.summary     = 'SQLite FTS5 full-text search for DynamoDB on AWS Lambda'
  spec.description = 'Per-owner SQLite FTS5 indexes stored on S3, queried from Lambda /tmp with version tracking.'
  spec.homepage    = 'https://github.com/stowzilla/s3arch'
  spec.license     = 'MIT'

  spec.required_ruby_version = '>= 3.2'

  spec.cert_chain  = ['certs/stowzilla.pem']
  signing_key_path = File.expand_path('~/.ssh/gem-private_key.pem')
  spec.signing_key = signing_key_path if File.exist?(signing_key_path)

  spec.files = Dir['lib/**/*', 'lambda/**/*', 'infrastructure/**/*', 'README.md', 'LICENSE.txt', 'CHANGELOG.md',
                   'certs/*']
  spec.require_paths = ['lib']

  spec.add_dependency 'aws-sdk-dynamodb', '~> 1.0'
  spec.add_dependency 'aws-sdk-s3', '~> 1.0'
  spec.add_dependency 'rack', '>= 2.0'
  spec.add_dependency 'sqlite3', '~> 2.0'

  spec.metadata = {
    'rubygems_mfa_required' => 'true',
    'homepage_uri' => spec.homepage,
    'source_code_uri' => "#{spec.homepage}/tree/main",
    'changelog_uri' => "#{spec.homepage}/blob/main/CHANGELOG.md"
  }
end
