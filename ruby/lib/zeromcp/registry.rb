# frozen_string_literal: true

require_relative 'server'
require_relative 'openapi'
require_relative 'credentials'

module ZeroMcp
  module Registry
    RouteDefinition = Struct.new(:name, :method, :path, :tool, keyword_init: true)

    ToolRegistry = Struct.new(:routes, :openapi, :mcp, :config, :credential_cache, keyword_init: true) do
      # Build a ready-to-use Context for `tool`, using the same config-driven
      # credential/permission rules Server#call_tool already applies — so a
      # caller invoking a routed tool directly (route.tool.call(args, ctx))
      # doesn't have to hand-roll credential lookup.
      def context_for(tool)
        ZeroMcp::Context.new(
          tool_name: tool.name,
          permissions: tool.permissions,
          bypass: config.bypass_permissions,
          credentials: ZeroMcp::Credentials.resolve(tool.name, config, cache: credential_cache)
        )
      end
    end

    module_function

    # tools:           Hash[String, ZeroMcp::Tool] — already-constructed Tool
    #                   instances, the same object Scanner#load_tool produces.
    #                   Not raw hashes, and not file paths.
    # config:           optional ZeroMcp::Config. Defaults to ZeroMcp::Config.new
    #                   (in-memory defaults, no zeromcp.config.json file read).
    #                   When supplied, title:/execute_timeout: are ignored (the
    #                   config already fully specifies them).
    # title:            OpenAPI info.title override. Ignored if config: is given.
    # execute_timeout:  default per-tool execute timeout in seconds. Ignored if
    #                   config: is given.
    def create(tools, config: nil, title: nil, execute_timeout: nil)
      cfg = config || Config.new(title: title, execute_timeout: execute_timeout)
      server = Server.new(cfg, tools: tools)
      credential_cache = {}

      routes = tools.each_with_object([]) do |(name, tool), acc|
        next unless tool.route.is_a?(Hash)
        acc << RouteDefinition.new(name: name, method: tool.route_method, path: tool.route_path, tool: tool)
      end

      ToolRegistry.new(
        routes: routes,
        openapi: OpenApi.build(tools, cfg),
        mcp: ->(request) { server.handle_request(request) },
        config: cfg,
        credential_cache: credential_cache
      )
    end
  end

  # Top-level convenience, mirroring ZeroMcp.serve / ZeroMcp.serve_http.
  def self.create_registry(tools, config: nil, title: nil, execute_timeout: nil)
    Registry.create(tools, config: config, title: title, execute_timeout: execute_timeout)
  end
end
