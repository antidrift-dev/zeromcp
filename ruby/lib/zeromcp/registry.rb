# frozen_string_literal: true

require_relative 'server'
require_relative 'openapi'
require_relative 'credentials'
require_relative 'remote'

module ZeroMcp
  module Registry
    RouteDefinition = Struct.new(:name, :method, :path, :tool, keyword_init: true)

    ToolRegistry = Struct.new(:routes, :openapi, :mcp, :config, :credential_cache, :get_runtime, keyword_init: true) do
      # Build a ready-to-use Context for `tool`, using the same config-driven
      # credential/permission rules Server#call_tool already applies — so a
      # caller invoking a routed tool directly (route.tool.call(args, ctx))
      # doesn't have to hand-roll credential lookup. ctx.runtime comes from
      # the registry's get_runtime hook, when one was given.
      def context_for(tool)
        ZeroMcp::Context.new(
          tool_name: tool.name,
          permissions: tool.permissions,
          bypass: config.bypass_permissions,
          credentials: ZeroMcp::Credentials.resolve(tool.name, config, cache: credential_cache, ns: tool.credentials_ns),
          runtime: get_runtime&.call
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
    # remote:           Array of remote MCP servers ({ 'name', 'url', 'auth',
    #                   'tools' }) to federate. Ignored if config: is given
    #                   (config.remote is used). Connects synchronously:
    #                   create blocks until every remote has answered or failed.
    #                   Remote tools are served from `mcp` only; they have no
    #                   route, so they never appear in `routes` or `openapi`.
    # get_runtime:      optional callable, arity 0. Its return value becomes
    #                   ctx.runtime for local tools, on `mcp` tools/call and in
    #                   context_for.
    def create(tools, config: nil, title: nil, execute_timeout: nil, remote: nil, get_runtime: nil)
      cfg = config || Config.new(title: title, execute_timeout: execute_timeout, remote: remote)
      server = Server.new(cfg, tools: tools, get_runtime: get_runtime)
      merged = cfg.remote.empty? ? tools : server.attach_remote(Remote.connect(cfg.remote))
      credential_cache = {}

      routes = tools.each_with_object([]) do |(name, tool), acc|
        next unless tool.route.is_a?(Hash)
        acc << RouteDefinition.new(name: name, method: tool.route_method, path: tool.route_path, tool: tool)
      end

      ToolRegistry.new(
        routes: routes,
        openapi: OpenApi.build(merged, cfg),
        mcp: ->(request) { server.handle_request(request) },
        config: cfg,
        credential_cache: credential_cache,
        get_runtime: get_runtime
      )
    end
  end

  # Top-level convenience, mirroring ZeroMcp.serve.
  def self.create_registry(tools, config: nil, title: nil, execute_timeout: nil, remote: nil, get_runtime: nil)
    Registry.create(tools, config: config, title: title, execute_timeout: execute_timeout,
                           remote: remote, get_runtime: get_runtime)
  end
end
