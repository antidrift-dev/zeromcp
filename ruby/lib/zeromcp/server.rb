# frozen_string_literal: true

require 'json'
require 'base64'
require 'timeout'
require_relative 'schema'
require_relative 'config'
require_relative 'tool'
require_relative 'scanner'
require_relative 'sandbox'
require_relative 'credentials'
require_relative 'remote'

module ZeroMcp
  class Server
    HTTP_REMOVED_MESSAGE = '[zeromcp] The built-in HTTP transport was removed. Mount ZeroMcp.create_registry ' \
                           '(routes, openapi, mcp) or ZeroMcp::Server#handle_request in your own HTTP server.'

    # get_runtime: optional callable (lambda/proc/method), arity 0. Called on
    # every local tool execution; its return value becomes ctx.runtime.
    def initialize(config = nil, tools: nil, get_runtime: nil)
      @config = config || Config.load
      @scanner = Scanner.new(@config)
      @resource_scanner = ResourceScanner.new(@config)
      @prompt_scanner = PromptScanner.new(@config)
      @tools = tools || {}
      @remote_names = {}
      @get_runtime = get_runtime
      @resources = {}
      @templates = {}
      @prompts = {}
      @subscriptions = {}
      @log_level = 'info'
      @icon = tools ? Config.resolve_icon(@config.icon) : nil
      @credential_cache = {}
      @out_mutex = Mutex.new
      @notify = nil
      @autoload_thread = nil
    end

    # Load tools (remote + local), resources and prompts from the config.
    # Call this before using handle_request directly (serve calls this
    # automatically). A local scan error propagates.
    def load_tools
      @tools = build_tool_map(@scanner.scan)
      load_resources_and_prompts
    end

    # Merge remote tools under the current tool map: local tools win, logging
    # each override. Returns the merged map. Used by Registry.
    def attach_remote(remote_tools)
      @tools = merge_remote(remote_tools, @tools)
    end

    def serve
      if @config.http_transport?
        $stderr.puts HTTP_REMOVED_MESSAGE
        exit 1
      end

      $stdout.sync = true
      $stderr.sync = true
      $stdin.set_encoding('UTF-8')
      $stdout.set_encoding('UTF-8')

      load_for_serve
      $stderr.puts "[zeromcp] stdio transport ready"

      @notify = ->(method, params) { write_message({ 'jsonrpc' => '2.0', 'method' => method, 'params' => params }) }
      start_autoload if @config.autoload_tools

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
        write_message(response) if response
      end
    ensure
      stop_autoload
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
        ctx = Context.new(tool_name: name, permissions: tool.permissions, bypass: @config.bypass_permissions,
                          credentials: _resolve_credentials(tool, name),
                          runtime: @remote_names.key?(name) ? nil : @get_runtime&.call)

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

    def _resolve_credentials(tool, tool_name)
      Credentials.resolve(tool_name, @config, cache: @credential_cache, ns: tool.credentials_ns)
    end

    # --- Loading ---

    # Remote tools first, then local tools over them (Node: server.ts / handler.ts).
    def build_tool_map(local_tools)
      @remote_names = {}
      remote = @config.remote.empty? ? {} : Remote.connect(@config.remote)
      merge_remote(remote, local_tools)
    end

    def merge_remote(remote_tools, local_tools)
      merged = {}
      remote_tools.each { |name, tool| merged[name] = tool }
      local_tools.each do |name, tool|
        $stderr.puts "[zeromcp] Local tool \"#{name}\" overrides remote" if remote_tools.key?(name)
        merged[name] = tool
      end
      remote_tools.each_key { |name| @remote_names[name] = true unless local_tools.key?(name) }
      merged
    end

    # serve's loading path: like load_tools, but a failing local scan only
    # exits when there is nothing else to serve (Node: server.ts).
    def load_for_serve
      local = begin
        @scanner.scan
      rescue StandardError
        if @config.remote.empty? && @config.resources_dir.empty? && @config.prompts_dir.empty?
          $stderr.puts '[zeromcp] No tools directory and no remote servers configured'
          exit 1
        end
        {}
      end
      @tools = build_tool_map(local)
      load_resources_and_prompts
    end

    def load_resources_and_prompts
      @resource_scanner.scan
      @resources = @resource_scanner.resources
      @templates = @resource_scanner.templates
      @prompt_scanner.scan
      @prompts = @prompt_scanner.prompts
      @icon = Config.resolve_icon(@config.icon)

      resource_count = @resources.size + @templates.size
      $stderr.puts "[zeromcp] #{@tools.size} tool(s), #{resource_count} resource(s), #{@prompts.size} prompt(s)"
    end

    # --- Output ---

    # Stdout is shared by the stdin loop and the autoload watcher thread.
    def write_message(message)
      @out_mutex.synchronize do
        $stdout.puts JSON.generate(message)
        $stdout.flush
      end
    end

    # --- Hot reload (autoload_tools) ---

    # Ruby's stdlib has no recursive file watcher, so poll mtimes of every
    # .rb file under each tool source. On a change: rescan, set every
    # rescanned tool into the live map (never removing entries, as Node does),
    # and send notifications/tools/list_changed when stdio is running.
    def start_autoload(interval: 1.0)
      snapshot = tool_file_snapshot
      @autoload_thread = Thread.new do
        loop do
          sleep interval
          current = tool_file_snapshot
          changed = (current.keys | snapshot.keys).reject { |k| current[k] == snapshot[k] }
          snapshot_was = snapshot
          snapshot = current
          next if changed.empty?

          changed.sort.each { |path| $stderr.puts "[zeromcp] Change detected: #{(current[path] || snapshot_was[path])[0]}" }
          reload_tools
        rescue StandardError => e
          $stderr.puts "[zeromcp] autoload error: #{e.message}"
        end
      end
      $stderr.puts '[zeromcp] autoload_tools enabled — watching for changes'
      @autoload_thread
    end

    def stop_autoload
      @autoload_thread&.kill
      @autoload_thread = nil
    end

    def reload_tools
      rescanned = @scanner.scan.dup
      tools = @tools.dup
      rescanned.each do |name, tool|
        tools[name] = tool
        @remote_names.delete(name)
      end
      @tools = tools
      @notify&.call('notifications/tools/list_changed', {})
    end

    # { <absolute path> => [<path relative to its source>, mtime] } for every tool file.
    def tool_file_snapshot
      snap = {}
      @scanner.source_dirs.each do |dir|
        next unless Dir.exist?(dir)
        Dir.glob('**/*.rb', base: dir).each do |rel|
          full = File.join(dir, rel)
          snap[full] = [rel, File.mtime(full)]
        rescue StandardError
          next
        end
      end
      snap
    end
  end
end
