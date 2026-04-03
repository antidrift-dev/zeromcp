# frozen_string_literal: true

module ZeroMcp
  module Schema
    TYPE_MAP = {
      'string'  => { 'type' => 'string' },
      'number'  => { 'type' => 'number' },
      'boolean' => { 'type' => 'boolean' },
      'object'  => { 'type' => 'object' },
      'array'   => { 'type' => 'array' }
    }.freeze

    def self.to_json_schema(input)
      return { 'type' => 'object', 'properties' => {}, 'required' => [] } if input.nil? || input.empty?

      properties = {}
      required = []

      input.each do |key, value|
        key = key.to_s
        if value.is_a?(String)
          mapped = TYPE_MAP[value]
          raise "Unknown type \"#{value}\" for field \"#{key}\"" unless mapped

          properties[key] = mapped.dup
          required << key
        elsif value.is_a?(Hash)
          type = value[:type] || value['type']
          mapped = TYPE_MAP[type.to_s]
          raise "Unknown type \"#{type}\" for field \"#{key}\"" unless mapped

          prop = mapped.dup
          desc = value[:description] || value['description']
          prop['description'] = desc if desc
          properties[key] = prop

          optional = value[:optional] || value['optional']
          required << key unless optional
        end
      end

      { 'type' => 'object', 'properties' => properties, 'required' => required }
    end

    def self.validate(input, schema)
      errors = []

      (schema['required'] || []).each do |key|
        if input[key].nil?
          errors << "Missing required field: #{key}"
        end
      end

      input.each do |key, value|
        prop = schema['properties'][key]
        next unless prop

        actual = value.is_a?(Array) ? 'array' : value.class.name.downcase
        actual = 'number' if value.is_a?(Numeric)
        actual = 'boolean' if value == true || value == false
        actual = 'string' if value.is_a?(String)
        actual = 'object' if value.is_a?(Hash)

        if actual != prop['type']
          errors << "Field \"#{key}\" expected #{prop['type']}, got #{actual}"
        end
      end

      errors
    end
  end
end
