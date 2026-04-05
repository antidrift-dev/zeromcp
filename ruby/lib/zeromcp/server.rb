# frozen_string_literal: true

require 'json'
require 'timeout'
require_relative 'schema'
require_relative 'config'
require_relative 'tool'
require_relative 'scanner'
require_relative 'sandbox'

module ZeroMcp
  class Server
    def initialize(config = nil)
      @config = config || Config.load
      @scanner = Scanner.new(@config)
      @tools = {}
    end

    # Load tools from the configured directories. Call this before using
    # handle_request directly (serve calls this automatically).
    def load_tools
      @tools = @scanner.scan
      $stderr.puts "[zeromcp] #{@tools.size} tool(s) loaded"
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
        begin
          line = line.encode('UTF-8', invalid: :replace, undef: :replace, replace: '').strip
        rescue StandardError
          next
        end
        next if line.empty?

        begin
          request = JSON.parse(line)
        rescue JSON::ParserError, EncodingError, StandardError
          next
        end

        next unless request.is_a?(Hash)

        response = handle_request(request)
        if response
          $stdout.puts JSON.generate(response)
          $stdout.flush
        end
      end
    end

    # Process a single JSON-RPC request hash and return a response hash.
    # Returns nil for notifications that require no response.
    #
    # Note: tools must be loaded first via #serve or by calling scanner.scan
    # manually if using this method directly for HTTP integration.
    #
    # Usage:
    #   response = server.handle_request({"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
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

    private

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
      name = params.is_a?(Hash) ? params['name'] : nil
      args = params.is_a?(Hash) ? (params['arguments'] || {}) : {}
      args = {} if args.nil?

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
        ctx = Context.new(tool_name: name, permissions: tool.permissions)

        # Tool-level timeout overrides config default
        timeout_secs = (tool.permissions.is_a?(Hash) && tool.permissions[:execute_timeout]) ||
                       (tool.permissions.is_a?(Hash) && tool.permissions['execute_timeout']) ||
                       @config.execute_timeout

        result = Timeout.timeout(timeout_secs) { tool.call(args, ctx) }
        text = result.is_a?(String) ? result : JSON.generate(result)
        { 'content' => [{ 'type' => 'text', 'text' => text }] }
      rescue Timeout::Error
        { 'content' => [{ 'type' => 'text', 'text' => "Tool \"#{name}\" timed out after #{timeout_secs}s" }], 'isError' => true }
      rescue => e
        { 'content' => [{ 'type' => 'text', 'text' => "Error: #{e.message}" }], 'isError' => true }
      end
    end
  end
end
