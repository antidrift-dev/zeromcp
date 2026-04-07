# frozen_string_literal: true

require_relative 'schema'

module ZeroMcp
  class Tool
    attr_reader :name, :description, :input, :permissions, :execute_block, :cached_schema

    def initialize(name:, description: '', input: {}, permissions: {}, &block)
      @name = name
      @description = description
      @input = input
      @permissions = permissions
      @execute_block = block
      @cached_schema = Schema.to_json_schema(@input)
    end

    def call(args, ctx = {})
      @execute_block.call(args, ctx)
    end
  end

  class Context
    attr_reader :credentials, :tool_name, :permissions, :bypass

    def initialize(tool_name:, credentials: nil, permissions: {}, bypass: false)
      @tool_name = tool_name
      @credentials = credentials
      @permissions = permissions
      @bypass = bypass
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
