# frozen_string_literal: true

module S3arch
  class Indexer
    # Parses DynamoDB Stream events from SQS records into change operations.
    module StreamParser
      private

      def group_changes(sqs_records)
        grouped = Hash.new { |h, k| h[k] = [] }

        sqs_records.each do |sqs_record|
          stream_record = JSON.parse(sqs_record['body'])
          event_name = stream_record['eventName']
          new_image = stream_record.dig('dynamodb', 'NewImage')
          old_image = stream_record.dig('dynamodb', 'OldImage')

          owner_id = extract_owner(new_image || old_image)
          next unless owner_id

          change = build_change(event_name, new_image, old_image)
          grouped[owner_id] << change if change
        end

        grouped
      end

      def build_change(event_name, new_image, old_image)
        case event_name
        when 'INSERT'
          tokens = extract_tokens(new_image)
          record_id = extract_record_id(new_image)
          return nil unless tokens && record_id && passes_filter?(new_image)

          { action: :insert, record_id: record_id, tokens: tokens, meta: extract_meta(new_image) }
        when 'REMOVE'
          tokens = extract_tokens(old_image)
          record_id = extract_record_id(old_image)
          return nil unless tokens && record_id

          { action: :delete, record_id: record_id, tokens: tokens }
        when 'MODIFY'
          build_modify_change(new_image, old_image)
        end
      end

      def build_modify_change(new_image, old_image)
        old_tokens = extract_tokens(old_image)
        new_tokens = extract_tokens(new_image)
        record_id = extract_record_id(new_image)
        return nil unless record_id

        unless passes_filter?(new_image)
          return old_tokens ? { action: :delete, record_id: record_id, tokens: old_tokens } : nil
        end

        unless old_tokens
          return new_tokens ? { action: :insert, record_id: record_id, tokens: new_tokens,
                                meta: extract_meta(new_image) } : nil
        end

        return nil unless new_tokens

        { action: :update, record_id: record_id, old_tokens: old_tokens, new_tokens: new_tokens,
          meta: extract_meta(new_image) }
      end

      def extract_owner(image)
        return nil unless image

        val = image[@config.owner_key]
        val.is_a?(Hash) ? val['S'] : val
      end

      def extract_record_id(image)
        return nil unless image

        val = image['id']
        val.is_a?(Hash) ? val['S'] : val
      end

      def extract_tokens(image)
        return nil unless image

        val = image[@config.token_field]
        return nil unless val

        if val.is_a?(Hash) && val.key?('M')
          val['M'].transform_values { |v| v.is_a?(Hash) ? (v['S'] || '') : v.to_s }
        elsif val.is_a?(Hash) && !val.key?('S')
          val.transform_values { |v| v.is_a?(Hash) ? (v['S'] || '') : v.to_s }
        end
      end

      def extract_meta(image)
        @config.metadata_fields.each_with_object({}) do |field, meta|
          val = image[field]
          meta[field] = val.is_a?(Hash) ? (val['S'] || val['N'] || '') : val.to_s
        end
      end

      def passes_filter?(image)
        plain = image.transform_values { |v| v.is_a?(Hash) ? (v['S'] || v['N'] || v['BOOL']&.to_s || '') : v }
        @config.record_filter.call(plain)
      end
    end
  end
end
