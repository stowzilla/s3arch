# frozen_string_literal: true

# Lightweight S3arch load for web/API contexts (no SQLite dependency).
# Provides configuration and routes only.
require_relative 'version'
require_relative 'configuration'
require_relative 'routes'

# Register controllers and models with Belt when Belt is loaded
if defined?(Belt)
  Belt.register_controllers(File.expand_path('../../lambda/controllers', __dir__))
  Belt.register_models(File.expand_path('../../lambda/models', __dir__))
end

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
