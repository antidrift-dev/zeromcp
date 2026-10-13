# frozen_string_literal: true

require 'json'
require 'net/http'
require 'uri'
require_relative 'config'
require_relative 'tool'

module ZeroMcp
  # Federates remote MCP servers over HTTP. Each remote tool is exposed
  # locally as "<server name>.<tool name>" and forwards tools/call upstream.
  module Remote
    module_function

    # servers: Array<Hash> ('name', 'url', 'auth', 'tools'; string or symbol keys)
    # => Hash[String, ZeroMcp::Tool], keyed "<server name>.<tool name>"
    def connect(servers)
      all = {}
      (servers || []).each do |server|
        name = fetch(server, 'name')
        begin
          tools = connect_one(server)
          tools.each do |tool_name, tool|
            ns_name = "#{name}.#{tool_name}"
            all[ns_name] = tool
            $stderr.puts "[mcp] Remote tool: #{ns_name}"
          end
        rescue => e
          $stderr.puts "[mcp] Failed to connect to #{name}: #{e.message}"
        end
      end
      all
    end

    # JSON Schema properties/required -> ZeroMcp input hash
    def schema_to_input(schema)
      input = {}
      return input unless schema.is_a?(Hash) && schema['properties'].is_a?(Hash)

      required = schema['required'].is_a?(Array) ? schema['required'] : []
      schema['properties'].each do |key, prop|
        prop = {} unless prop.is_a?(Hash)
        type = prop['type'] || 'string'
        is_required = required.include?(key)

        if prop['description'] || !is_required
          entry = { type: type }
          entry[:description] = prop['description'] if prop['description']
          entry[:optional] = true unless is_required
          input[key] = entry
        else
          input[key] = type
        end
      end
      input
    end

    def connect_one(server)
      name = fetch(server, 'name')
      url = fetch(server, 'url').to_s
      unless url.start_with?('http://', 'https://')
        raise "Remote server \"#{name}\" must have an HTTP/HTTPS URL, got: #{url}"
      end

      auth = Config.resolve_auth(fetch(server, 'auth'))
      allow = fetch(server, 'tools')

      rpc(url, { jsonrpc: '2.0', id: 1, method: 'initialize', params: {} }, auth)
      list = rpc(url, { jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} }, auth)

      remote_tools = (list.is_a?(Hash) && list['result'].is_a?(Hash) && list['result']['tools']) || []
      remote_tools = remote_tools.select { |rt| allow.include?(rt['name']) } if allow

      tools = {}
      remote_tools.each do |rt|
        upstream = rt['name']
        tools[upstream] = Tool.new(
          name: "#{name}.#{upstream}",
          description: rt['description'],
          input: schema_to_input(rt['inputSchema']),
          permissions: {},
          route: nil
        ) do |args, _ctx|
          res = rpc(url, {
            jsonrpc: '2.0', id: (Time.now.to_f * 1000).to_i,
            method: 'tools/call', params: { name: upstream, arguments: args }
          }, auth)
          result = res.is_a?(Hash) ? res['result'] : nil
          content = result.is_a?(Hash) ? result['content'] : nil
          text = content.is_a?(Array) && content[0].is_a?(Hash) ? content[0]['text'] : nil
          text.nil? || text == '' ? result : text
        end
      end

      $stderr.puts "[mcp] Connected to #{name} (HTTP): #{tools.size} tool(s)"
      tools
    end

    def rpc(url, body, auth)
      uri = URI(url)
      req = Net::HTTP::Post.new(uri)
      req['Content-Type'] = 'application/json'
      req['Authorization'] = "Bearer #{auth}" if auth
      req.body = JSON.generate(body)

      res = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https') { |http| http.request(req) }
      raise "HTTP #{res.code}" unless res.is_a?(Net::HTTPSuccess)

      JSON.parse(res.body)
    end

    def fetch(hash, key)
      return nil unless hash.is_a?(Hash)
      hash.key?(key) ? hash[key] : hash[key.to_sym]
    end
  end
end
