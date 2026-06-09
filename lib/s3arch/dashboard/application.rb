# frozen_string_literal: true

require 'erb'
require 'json'
require 'aws-sdk-dynamodb'

module S3arch
  module Dashboard
    class Application
      VIEWS_PATH = File.expand_path('views', __dir__)

      def routes
        [
          { method: :get, path: '/' },
          { method: :post, path: '/rebuild' }
        ]
      end

      def call(env)
        req = Rack::Request.new(env)
        path = req.path_info.sub(%r{^/}, '')

        case [req.request_method, path]
        when ['GET', ''], ['GET', 'index']
          index(req)
        when ['POST', 'rebuild']
          rebuild(req)
        else
          [404, { 'content-type' => 'text/plain' }, ['Not Found']]
        end
      end

      private

      def index(req)
        @env = req.env
        @owners = fetch_owners
        html = render('index')
        [200, { 'content-type' => 'text/html' }, [html]]
      end

      def rebuild(req)
        owner_id = req.params['owner_id']&.strip
        if owner_id && !owner_id.empty?
          indexer = S3arch::Indexer.new
          indexer.rebuild(owner_id)
        end
        [303, { 'location' => req.script_name.to_s + '/' }, []]
      end

      def fetch_owners
        config = S3arch.configuration
        dynamodb = Aws::DynamoDB::Client.new
        items = []
        params = { table_name: config.version_table }

        loop do
          result = dynamodb.scan(params)
          items.concat(result.items)
          break unless result.last_evaluated_key

          params[:exclusive_start_key] = result.last_evaluated_key
        end

        items.map do |item|
          {
            owner_id: item[config.owner_key] || item.values.first,
            version: item['version'],
            record_count: item['record_count'],
            updated_at: item['updated_at']
          }
        end.sort_by { |o| o[:updated_at].to_s }.reverse
      rescue StandardError => e
        @error = e.message
        []
      end

      def render(template)
        path = File.join(VIEWS_PATH, "#{template}.html.erb")
        ERB.new(File.read(path), trim_mode: '-').result(binding)
      end
    end
  end
end
