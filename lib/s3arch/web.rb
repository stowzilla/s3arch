# frozen_string_literal: true

# Lightweight S3arch load for web/API contexts (no SQLite dependency).
# Provides configuration and routes only.
require_relative 'version'
require_relative 'configuration'
require_relative 'routes'

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
