# frozen_string_literal: true

module S3arch
  # Lightweight route manifest for Dispatcher mount DSL.
  # No heavy dependencies — safe to load in parse-only contexts.
  module Routes
    def self.routes
      [
        { method: :get, path: '/' },
        { method: :post, path: '/rebuild' }
      ]
    end
  end
end
