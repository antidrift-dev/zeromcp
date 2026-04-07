# frozen_string_literal: true

require 'json'
require 'base64'
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
      @resource_scanner = ResourceScanner.new(@config)
      @prompt_scanner = PromptScanner.new(@config)
      @tools = {}
      @resources = {}
      @templates = {}
      @prompts = {}
      @subscriptions = {}
      @log_level = 'info'
      @icon = nil
    end

    # Load tools (and resources/prompts) from the configured directories.
    # Call this before using handle_request directly (serve calls this
    # automatically).
    def load_tools
      @tools = @scanner.scan
      @resource_scanner.scan
      @resources = @resource_scanner.resources
      @templates = @resource_scanner.templates
      @prompt_scanner.scan
      @prompts = @prompt_scanner.prompts
      @icon = Config.resolve_icon(@config.icon)

      resource_count = @resources.size + @templates.size
      $stderr.puts "[zeromcp] #{@tools.size} tool(s), #{resource_count} resource(s), #{@prompts.size} prompt(s)"
    end

    def serve
      $stdout.sync = true
      $stderr.sync = true
      $stdin.set_encoding('UTF-8')
      $stdout.set_encoding('UTF-8')

      @tools = @scanner.scan
      @resource_scanner.scan
      @resources = @resource_scanner.resources
      @templates = @resource_scanner.templates
      @prompt_scanner.scan
      @prompts = @prompt_scanner.prompts
      @icon = Config.resolve_icon(@config.icon)

      resource_count = @resources.size + @templates.size
      $stderr.puts "[zeromcp] #{@tools.size} tool(s), #{resource_count} resource(s), #{@prompts.size} prompt(s)"
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
    # Note: tools must be loaded first via #serve or by calling load_tools
    # manually if using this method directly for HTTP integration.
    #
    # Usage:
    #   response = server.handle_request({"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"})
    def handle_request(request)
      id = request['id']
      method = request['method']
      params = request['params'] || {}

      # Notifications (no id)
      if id.nil?
        handle_notification(method, params)
        return nil
      end

      case method
      when 'initialize'
        handle_initialize(id, params)
      when 'ping'
        { 'jsonrpc' => '2.0', 'id' => id, 'result' => {} }

      # Tools
      when 'tools/list'
        handle_tools_list(id, params)
      when 'tools/call'
        { 'jsonrpc' => '2.0', 'id' => id, 'result' => call_tool(params) }

      # Resources
      when 'resources/list'
        handle_resources_list(id, params)
      when 'resources/read'
        handle_resources_read(id, params)
      when 'resources/subscribe'
        handle_resources_subscribe(id, params)
      when 'resources/templates/list'
        handle_resources_templates_list(id, params)

      # Prompts
      when 'prompts/list'
        handle_prompts_list(id, params)
      when 'prompts/get'
        handle_prompts_get(id, params)

      # Passthrough
      when 'logging/setLevel'
        handle_logging_set_level(id, params)
      when 'completion/complete'
        handle_completion_complete(id, params)

      else
        {
          'jsonrpc' => '2.0',
          'id' => id,
          'error' => { 'code' => -32601, 'message' => "Method not found: #{method}" }
        }
      end
    end

    private

    # --- Notifications ---

    def handle_notification(method, params)
      case method
      when 'notifications/initialized'
        # no-op
      when 'notifications/roots/list_changed'
        # store roots if provided
        if params.is_a?(Hash) && params['roots'].is_a?(Array)
          @roots = params['roots']
        end
      end
    end

    # --- Initialize ---

    def handle_initialize(id, params)
      capabilities = {
        'tools' => { 'listChanged' => true }
      }

      if @resources.size > 0 || @templates.size > 0
        capabilities['resources'] = { 'subscribe' => true, 'listChanged' => true }
      end

      if @prompts.size > 0
        capabilities['prompts'] = { 'listChanged' => true }
      end

      capabilities['logging'] = {}

      {
        'jsonrpc' => '2.0',
        'id' => id,
        'result' => {
          'protocolVersion' => '2024-11-05',
          'capabilities' => capabilities,
          'serverInfo' => {
            'name' => 'zeromcp',
            'version' => '0.2.0'
          }
        }
      }
    end

    # --- Tools ---

    def handle_tools_list(id, params)
      list = @tools.map do |name, tool|
        entry = {
          'name' => name,
          'description' => tool.description,
          'inputSchema' => tool.cached_schema
        }
        entry['icons'] = [{ 'uri' => @icon }] if @icon
        entry
      end

      items, next_cursor = paginate(list, params['cursor'])
      result = { 'tools' => items }
      result['nextCursor'] = next_cursor if next_cursor
      { 'jsonrpc' => '2.0', 'id' => id, 'result' => result }
    end

    # --- Resources ---

    def handle_resources_list(id, params)
      list = @resources.map do |_name, res|
        entry = {
          'uri' => res[:uri],
          'name' => res[:name],
          'description' => res[:description],
          'mimeType' => res[:mime_type]
        }
        entry['icons'] = [{ 'uri' => @icon }] if @icon
        entry
      end

      items, next_cursor = paginate(list, params['cursor'])
      result = { 'resources' => items }
      result['nextCursor'] = next_cursor if next_cursor
      { 'jsonrpc' => '2.0', 'id' => id, 'result' => result }
    end

    def handle_resources_read(id, params)
      uri = params.is_a?(Hash) ? params['uri'] : ''
      uri ||= ''

      # Check static/dynamic resources
      @resources.each do |_name, res|
        if res[:uri] == uri
          begin
            text = res[:read].call
            return {
              'jsonrpc' => '2.0',
              'id' => id,
              'result' => { 'contents' => [{ 'uri' => uri, 'mimeType' => res[:mime_type], 'text' => text }] }
            }
          rescue => e
            return {
              'jsonrpc' => '2.0',
              'id' => id,
              'error' => { 'code' => -32603, 'message' => "Error reading resource: #{e.message}" }
            }
          end
        end
      end

      # Check templates
      @templates.each do |_name, tmpl|
        match = match_template(tmpl[:uri_template], uri)
        if match
          begin
            text = tmpl[:read].call(match)
            return {
              'jsonrpc' => '2.0',
              'id' => id,
              'result' => { 'contents' => [{ 'uri' => uri, 'mimeType' => tmpl[:mime_type], 'text' => text }] }
            }
          rescue => e
            return {
              'jsonrpc' => '2.0',
              'id' => id,
              'error' => { 'code' => -32603, 'message' => "Error reading resource: #{e.message}" }
            }
          end
        end
      end

      { 'jsonrpc' => '2.0', 'id' => id, 'error' => { 'code' => -32002, 'message' => "Resource not found: #{uri}" } }
    end

    def handle_resources_subscribe(id, params)
      uri = params.is_a?(Hash) ? params['uri'] : nil
      @subscriptions[uri] = true if uri
      { 'jsonrpc' => '2.0', 'id' => id, 'result' => {} }
    end

    def handle_resources_templates_list(id, params)
      list = @templates.map do |_name, tmpl|
        entry = {
          'uriTemplate' => tmpl[:uri_template],
          'name' => tmpl[:name],
          'description' => tmpl[:description],
          'mimeType' => tmpl[:mime_type]
        }
        entry['icons'] = [{ 'uri' => @icon }] if @icon
        entry
      end

      items, next_cursor = paginate(list, params['cursor'])
      result = { 'resourceTemplates' => items }
      result['nextCursor'] = next_cursor if next_cursor
      { 'jsonrpc' => '2.0', 'id' => id, 'result' => result }
    end

    # --- Prompts ---

    def handle_prompts_list(id, params)
      list = @prompts.map do |_name, prompt|
        entry = { 'name' => prompt[:name] }
        entry['description'] = prompt[:description] if prompt[:description]
        entry['arguments'] = prompt[:arguments] if prompt[:arguments]
        entry['icons'] = [{ 'uri' => @icon }] if @icon
        entry
      end

      items, next_cursor = paginate(list, params['cursor'])
      result = { 'prompts' => items }
      result['nextCursor'] = next_cursor if next_cursor
      { 'jsonrpc' => '2.0', 'id' => id, 'result' => result }
    end

    def handle_prompts_get(id, params)
      name = params.is_a?(Hash) ? params['name'] : ''
      args = params.is_a?(Hash) ? (params['arguments'] || {}) : {}

      prompt = @prompts[name]
      unless prompt
        return {
          'jsonrpc' => '2.0',
          'id' => id,
          'error' => { 'code' => -32002, 'message' => "Prompt not found: #{name}" }
        }
      end

      begin
        messages = prompt[:render].call(args)
        { 'jsonrpc' => '2.0', 'id' => id, 'result' => { 'messages' => messages } }
      rescue => e
        { 'jsonrpc' => '2.0', 'id' => id, 'error' => { 'code' => -32603, 'message' => "Error rendering prompt: #{e.message}" } }
      end
    end

    # --- Passthrough ---

    def handle_logging_set_level(id, params)
      level = params.is_a?(Hash) ? params['level'] : nil
      @log_level = level if level
      { 'jsonrpc' => '2.0', 'id' => id, 'result' => {} }
    end

    def handle_completion_complete(id, _params)
      { 'jsonrpc' => '2.0', 'id' => id, 'result' => { 'completion' => { 'values' => [] } } }
    end

    # --- Pagination ---

    def paginate(items, cursor)
      page_size = @config.page_size
      return [items, nil] if page_size <= 0

      offset = cursor ? decode_cursor(cursor) : 0
      slice = items[offset, page_size] || []
      has_more = (offset + page_size) < items.size
      next_cursor = has_more ? encode_cursor(offset + page_size) : nil
      [slice, next_cursor]
    end

    def encode_cursor(offset)
      Base64.strict_encode64(offset.to_s)
    end

    def decode_cursor(cursor)
      decoded = Base64.decode64(cursor)
      offset = decoded.to_i
      offset < 0 ? 0 : offset
    rescue
      0
    end

    # --- Template matching ---

    def match_template(template, uri)
      # Convert {param} placeholders to named capture groups
      param_names = []
      regex_str = template.gsub(/\{(\w+)\}/) do
        param_names << $1
        '([^/]+)'
      end

      match = uri.match(/\A#{regex_str}\z/)
      return nil unless match

      result = {}
      param_names.each_with_index do |name, i|
        result[name] = match[i + 1]
      end
      result
    end

    # --- Tool execution ---

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

      errors = Schema.validate(args, tool.cached_schema)
      if errors.any?
        return {
          'content' => [{ 'type' => 'text', 'text' => "Validation errors:\n#{errors.join("\n")}" }],
          'isError' => true
        }
      end

      begin
        ctx = Context.new(tool_name: name, permissions: tool.permissions, bypass: @config.bypass_permissions, credentials: _resolve_credentials(name))

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

    def _resolve_credentials(tool_name)
      return nil if @config.credentials.empty?
      # Match credential namespace from tool name prefix
      @config.credentials.each do |ns, source|
        if tool_name.start_with?("#{ns}_") || tool_name.start_with?("#{ns}#{@config.separator}")
          return _resolve_credential_source(source)
        end
      end
      nil
    end

    def _resolve_credential_source(source)
      source = source.transform_keys(&:to_s) if source.is_a?(Hash)
      if source['env']
        val = ENV[source['env']]
        return nil if val.nil? || val.empty?
        begin; return JSON.parse(val); rescue; return val; end
      end
      if source['file']
        path = File.expand_path(source['file'])
        return nil unless File.exist?(path)
        val = File.read(path).strip
        begin; return JSON.parse(val); rescue; return val; end
      end
      nil
    end
  end
end
