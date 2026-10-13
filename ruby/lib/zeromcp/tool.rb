# frozen_string_literal: true

require_relative 'schema'

module ZeroMcp
  class Tool
    attr_reader :name, :description, :input, :permissions, :execute_block, :cached_schema, :route,
                :credentials_ns

    # credentials_ns: the `credentials` config key this tool's credentials come
    # from. Scanner sets it to the tool's top-level directory, so a
    # `namespacing` prefix doesn't change which credentials it gets. nil means
    # match by tool-name prefix.
    def initialize(name:, description: '', input: {}, permissions: {}, route: nil, credentials_ns: nil, &block)
      @name = name
      @description = description
      @input = input
      @permissions = permissions
      @route = route
      @credentials_ns = credentials_ns
      @execute_block = block
      @cached_schema = Schema.to_json_schema(@input)
    end

    def call(args, ctx = {})
      @execute_block.call(args, ctx)
    end

    def route_method
      return nil unless @route.is_a?(Hash)
      (@route[:method] || @route['method'] || 'POST').upcase
    end

    def route_path
      return nil unless @route.is_a?(Hash)
      @route[:path] || @route['path'] || '/'
    end
  end

  class Context
    attr_reader :credentials, :tool_name, :permissions, :bypass, :runtime

    def initialize(tool_name:, credentials: nil, permissions: {}, bypass: false, runtime: nil)
      @tool_name = tool_name
      @credentials = credentials
      @permissions = permissions
      @bypass = bypass
      @runtime = runtime
    end
  end

  # DSL module for tool files
  module ToolDSL
    def self.included(base)
      base.extend(ClassMethods)
    end

    module ClassMethods
      def tool_metadata
        @tool_metadata ||= {}
      end
    end
  end
end
