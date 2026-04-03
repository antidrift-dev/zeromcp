# frozen_string_literal: true

require 'json'
require_relative 'schema'
require_relative 'config'
require_relative 'tool'
require_relative 'scanner'

module ZeroMcp
  class Server
    def initialize(config = nil)
      @config = config || Config.load
      @scanner = Scanner.new(@config)
      @tools = {}
    end

    def serve
      $stdout.sync = true
      $stderr.sync = true
      $stdin.set_encoding('UTF-8')
      $stdout.set_encoding('UTF-8')
      @tools = @scanner.scan
      $stderr.puts "[zeromcp] #{@tools.size} tool(s) loaded"
      $stderr.puts "[zeromcp] stdio transport ready"

      $stdin.each_line do |line|
        line = line.strip
        next if line.empty?

        begin
          request = JSON.parse(line)
        rescue JSON::ParserError
          next
        end

        response = handle_request(request)
        if response
          $stdout.puts JSON.generate(response)
          $stdout.flush
        end
      end
    end

    private

    def handle_request(request)
      id = request['id']
      method = request['method']
      params = request['params'] || {}

      # Notifications (no id) for known notification methods
      if id.nil? && method == 'notifications/initialized'
        return nil
      end

      case method
      when 'initialize'
        {
          'jsonrpc' => '2.0',
          'id' => id,
          'result' => {
            'protocolVersion' => '2024-11-05',
            'capabilities' => {
              'tools' => { 'listChanged' => true }
            },
            'serverInfo' => {
              'name' => 'zeromcp',
              'version' => '0.1.0'
            }
          }
        }

      when 'tools/list'
        {
          'jsonrpc' => '2.0',
          'id' => id,
          'result' => {
            'tools' => build_tool_list
          }
        }

      when 'tools/call'
        {
          'jsonrpc' => '2.0',
          'id' => id,
          'result' => call_tool(params)
        }

      when 'ping'
        { 'jsonrpc' => '2.0', 'id' => id, 'result' => {} }

      else
        return nil if id.nil?
        {
          'jsonrpc' => '2.0',
          'id' => id,
          'error' => { 'code' => -32601, 'message' => "Method not found: #{method}" }
        }
      end
    end

    def build_tool_list
      @tools.map do |name, tool|
        {
          'name' => name,
          'description' => tool.description,
          'inputSchema' => Schema.to_json_schema(tool.input)
        }
      end
    end

    def call_tool(params)
      name = params['name']
      args = params['arguments'] || {}

      tool = @tools[name]
      unless tool
        return {
          'content' => [{ 'type' => 'text', 'text' => "Unknown tool: #{name}" }],
          'isError' => true
        }
      end

      schema = Schema.to_json_schema(tool.input)
      errors = Schema.validate(args, schema)
      if errors.any?
        return {
          'content' => [{ 'type' => 'text', 'text' => "Validation errors:\n#{errors.join("\n")}" }],
          'isError' => true
        }
      end

      begin
        ctx = Context.new(tool_name: name)
        result = tool.call(args, ctx)
        text = result.is_a?(String) ? result : JSON.pretty_generate(result)
        { 'content' => [{ 'type' => 'text', 'text' => text }] }
      rescue => e
        { 'content' => [{ 'type' => 'text', 'text' => "Error: #{e.message}" }], 'isError' => true }
      end
    end
  end
end
