# frozen_string_literal: true

require_relative 'schema'

module ZeroMcp
  module OpenApi
    module_function

    def build(tools, config)
      paths = {}

      tools.each do |_name, tool|
        next unless tool.route.is_a?(Hash)

        route_method = tool.route_method
        route_path = tool.route_path

        # Extract :param names from path, convert to {param} for OpenAPI
        path_param_names = route_path.scan(/:([A-Za-z_][A-Za-z0-9_]*)/).flatten
        openapi_path = route_path.gsub(/:([A-Za-z_][A-Za-z0-9_]*)/, '{\1}')

        input = tool.input || {}
        operation = {
          'operationId' => tool.name,
          'description' => tool.description || '',
          'responses'   => {
            '200' => { 'description' => 'Success' },
            '500' => { 'description' => 'Error' }
          }
        }

        if route_method == 'GET'
          operation['parameters'] = build_parameters(input, path_param_names)
        else
          operation['requestBody'] = build_request_body(input, path_param_names)
          unless path_param_names.empty?
            operation['parameters'] = path_param_names.map do |name|
              {
                'name'     => name,
                'in'       => 'path',
                'required' => true,
                'schema'   => { 'type' => 'string' }
              }
            end
          end
        end

        paths[openapi_path] ||= {}
        paths[openapi_path][route_method.downcase] = operation
      end

      {
        'openapi' => '3.0.0',
        'info'    => { 'title' => config.title, 'version' => '0.5.0' },
        'paths'   => paths
      }
    end

    def build_parameters(input, path_param_names)
      params = []

      # Path params first (preserve order from path)
      path_param_names.each do |name|
        spec = field_to_openapi_schema(input[name] || input[name.to_sym])
        params << {
          'name'     => name,
          'in'       => 'path',
          'required' => true,
          'schema'   => spec
        }
      end

      # Remaining fields as query params
      input.each do |key, value|
        key_s = key.to_s
        next if path_param_names.include?(key_s)

        spec     = field_to_openapi_schema(value)
        optional = value.is_a?(Hash) && (value[:optional] || value['optional'])
        params << {
          'name'     => key_s,
          'in'       => 'query',
          'required' => !optional,
          'schema'   => spec
        }
      end

      params
    end

    def build_request_body(input, path_param_names)
      body_input = input.reject { |key, _| path_param_names.include?(key.to_s) }
      schema = Schema.to_json_schema(body_input)
      {
        'required' => true,
        'content'  => {
          'application/json' => { 'schema' => schema }
        }
      }
    end

    def field_to_openapi_schema(value)
      return { 'type' => 'string' } if value.nil?

      if value.is_a?(String)
        Schema::TYPE_MAP[value] || { 'type' => 'string' }
      elsif value.is_a?(Hash)
        type = value[:type] || value['type']
        mapped = Schema::TYPE_MAP[type.to_s] || { 'type' => 'string' }
        spec = mapped.dup
        desc = value[:description] || value['description']
        spec['description'] = desc if desc
        spec
      else
        { 'type' => 'string' }
      end
    end
  end
end
