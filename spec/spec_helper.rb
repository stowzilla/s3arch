# frozen_string_literal: true

require 's3arch'

RSpec.configure do |config|
  config.before { S3arch.reset_configuration! }
end
