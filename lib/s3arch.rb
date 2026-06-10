# frozen_string_literal: true

require_relative 's3arch/version'
require_relative 's3arch/configuration'
require_relative 's3arch/tokenizer'
require_relative 's3arch/indexer'
require_relative 's3arch/searcher'
require_relative 's3arch/handler'
require_relative 's3arch/routes'
require_relative 's3arch/dashboard'

# Register as a Belt holster when Belt is loaded
require_relative 's3arch/holster' if defined?(Belt::Holster)

module S3arch
  class Error < StandardError; end

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration)
    end

    def reset_configuration!
      @configuration = Configuration.new
    end
  end
end
