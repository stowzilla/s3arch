# frozen_string_literal: true

module S3arch
  # Pure tokenization — generates the token string stored in DynamoDB.
  # At query time, FTS5 tokenizes the same way internally, so prefix matches work.
  class Tokenizer
    def initialize(fields: S3arch.configuration.searchable_fields)
      @fields = fields
    end

    # Accepts a record hash, returns a hash of { field => tokenized_string }
    # This is what gets stored in DynamoDB and fed directly into FTS5.
    def tokenize(record)
      @fields.to_h do |field|
        [field, normalize(record[field])]
      end
    end

    # Flattened single-string version for simple storage (all fields concatenated)
    def tokenize_flat(record)
      @fields.map { |f| normalize(record[f]) }.reject(&:empty?).join(' ')
    end

    private

    def normalize(value)
      case value
      when Hash
        if value.key?('S') then value['S'].to_s
        elsif value.key?('L') then value['L'].map { |v| v['S'] || v.to_s }.join(' ')
        elsif value.key?('N') then value['N'].to_s
        elsif value.key?('SS') then value['SS'].join(' ')
        else value.values.first.to_s
        end
      when Array then value.map { |v| v.is_a?(Hash) ? (v['S'] || v.to_s) : v.to_s }.join(' ')
      when nil then ''
      else value.to_s
      end
    end
  end
end
