# frozen_string_literal: true

require 'json'
require 'erb'
require_relative 'dashboard/application'
require_relative 'dashboard/controller'

module S3arch
  module Dashboard
    def self.app
      Application.new
    end
  end
end
