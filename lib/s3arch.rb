# frozen_string_literal: true

require_relative 's3arch/version'
require_relative 's3arch/configuration'
require_relative 's3arch/indexer'
require_relative 's3arch/searcher'
require_relative 's3arch/handler'

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
