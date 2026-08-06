# frozen_string_literal: true

require 'json'
require 'base64'
require 'timeout'
require 'webrick'
require_relative 'schema'
require_relative 'config'
require_relative 'tool'
require_relative 'scanner'
require_relative 'sandbox'
require_relative 'openapi'
require_relative 'credentials'

module ZeroMcp
  class Server
    def initialize(config = nil, tools: nil)
      @config = config || Config.load
      @scanner = Scanner.new(@config)
      @resource_scanner = ResourceScanner.new(@config)
      @prompt_scanner = PromptScanner.new(@config)
      @tools = tools || {}
      @resources = {}
      @templates = {}
      @prompts = {}
      @subscriptions = {}
      @log_level = 'info'
      @icon = tools ? Config.resolve_icon(@config.icon) : nil
      @credential_cache = {}
    end

    # Start an HTTP server that exposes:
    #   POST /mcp  — JSON-RPC over HTTP
    #   <method> <path> — per-tool route handlers (tools with a `route:` field)
    #
    # Usage: ZeroMcp::Server.new.serve_http(port: 3000)
    def serve_http(port: 3000)
      load_tools

      http = WEBrick::HTTPServer.new(Port: port, Logger: WEBrick::Log.new($stderr), AccessLog: [])
      $stderr.puts "[zeromcp] HTTP server listening on port #{port}"

      # /mcp — JSON-RPC endpoint
      http.mount_proc('/mcp') do |req, res|
        begin
          request = JSON.parse(req.body || '{}')
        rescue JSON::ParserError
          res.status = 400
          res.content_type = 'application/json'
          res.body = JSON.generate({ 'error' => 'Invalid JSON' })
          next
        end
        response = handle_request(request)
        res.content_type = 'application/json'
        res.body = JSON.generate(response || {})
      end

      # /openapi.json — auto-generated OpenAPI 3.0 spec from routed tools
      http.mount_proc('/openapi.json') do |_req, res|
        res.content_type = 'application/json'
        res.body = JSON.generate(build_openapi_spec)
      end

      # /docs — Swagger UI
      http.mount_proc('/docs') do |_req, res|
        res.content_type = 'text/html'
        res.body = SWAGGER_UI_HTML
      end

      # /health — liveness check
      http.mount_proc('/health') do |_req, res|
        res.content_type = 'application/json'
        res.body = JSON.generate({ 'ok' => true })
      end

      # Register per-tool HTTP routes
      @tools.each do |_name, tool|
        next unless tool.route.is_a?(Hash)
        register_tool_route(http, tool, tool.route_method, tool.route_path)
      end

      trap('INT')  { http.shutdown }
      trap('TERM') { http.shutdown }
      http.start
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
      Credentials.resolve(tool_name, @config, cache: @credential_cache)
    end

    # --- HTTP route helpers ---

    def register_tool_route(http, tool, route_method, route_path)
      # Convert :param segments to a regex for matching
      param_names = []
      regex_str = route_path.gsub(/:([A-Za-z_][A-Za-z0-9_]*)/) do
        param_names << $1
        '([^/]+)'
      end
      route_regex = /\A#{regex_str}\z/

      http.mount_proc(route_path_prefix(route_path)) do |req, res|
        next unless req.request_method == route_method

        path_params = extract_path_params(req.path, route_regex, param_names)
        unless path_params
          res.status = 404
          res.content_type = 'application/json'
          res.body = JSON.generate({ 'ok' => false, 'error' => 'Not found' })
          next
        end

        args = if route_method == 'GET'
          query_args = WEBrick::HTTPUtils.parse_query(req.query_string || '')
          query_args.merge(path_params)
        else
          body_args = begin
            req.body && !req.body.empty? ? JSON.parse(req.body) : {}
          rescue JSON::ParserError
            {}
          end
          body_args.merge(path_params)
        end

        begin
          ctx = Context.new(tool_name: tool.name, permissions: tool.permissions,
                            bypass: @config.bypass_permissions,
                            credentials: _resolve_credentials(tool.name))
          timeout_secs = (tool.permissions.is_a?(Hash) && tool.permissions[:execute_timeout]) ||
                         (tool.permissions.is_a?(Hash) && tool.permissions['execute_timeout']) ||
                         @config.execute_timeout
          result = Timeout.timeout(timeout_secs) { tool.call(args, ctx) }
          res.content_type = 'application/json'
          res.body = JSON.generate({ 'ok' => true, 'result' => result })
        rescue => e
          res.status = 500
          res.content_type = 'application/json'
          res.body = JSON.generate({ 'ok' => false, 'error' => e.message })
        end
      end
    end

    def route_path_prefix(route_path)
      # WEBrick mounts on a fixed prefix; use the static prefix before first :param
      route_path.split('/:').first || '/'
    end

    def extract_path_params(path, route_regex, param_names)
      m = path.match(route_regex)
      return nil unless m
      result = {}
      param_names.each_with_index { |name, i| result[name] = m[i + 1] }
      result
    end

    # --- OpenAPI spec builder ---

    def build_openapi_spec
      OpenApi.build(@tools, @config)
    end

    SWAGGER_UI_HTML = <<~HTML.freeze
      <!DOCTYPE html>
      <html>
      <head>
        <title>ZeroMCP API</title>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist/swagger-ui.css">
      </head>
      <body>
      <div id="swagger-ui"></div>
      <script src="https://unpkg.com/swagger-ui-dist/swagger-ui-bundle.js"></script>
      <script>SwaggerUIBundle({ url: '/openapi.json', dom_id: '#swagger-ui' })</script>
      </body>
      </html>
    HTML
  end
end
