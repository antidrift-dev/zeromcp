/// One tool exposed as an HTTP-style route.
/// Named `RegistryRoute` (not `RouteDefinition`) because `RouteDefinition`
/// is already taken — it's the existing `{ method, path }` struct attached
/// to a tool (Tool.swift:46). This type is the registry's richer route
/// *entry*: the route metadata plus the tool it belongs to.
public struct RegistryRoute {
    public let name: String
    public let method: String   // uppercased, e.g. "GET" — matches RouteDefinition.method
    public let path: String     // ":param" segments, unmatched — matches RouteDefinition.path
    public let tool: ToolDefinition
}

/// Signature of the registry's JSON-RPC handler. Matches
/// `ZeroMcp.handleRequest(_:)` exactly (untyped dictionaries — this
/// codebase has no JsonRpcRequest/JsonRpcResponse types to reuse or port).
public typealias McpHandler = (_ request: [String: Any]) async -> [String: Any]?

public struct RegistryOptions {
    /// Config used to build the internal dispatch instance (title for
    /// OpenAPI info, executeTimeout default, etc). Defaults to an empty
    /// ZeroMcpConfig() — NOT ZeroMcpConfig.load(), which reads
    /// ./zeromcp.config.json from the current working directory as a
    /// side effect. An embeddable library must not do ambient
    /// filesystem I/O by default; pass ZeroMcpConfig.load() explicitly
    /// if that behavior is wanted.
    /// `config.remote` servers are connected and merged into `mcp` (local
    /// tools win); they never appear in `routes` or `openapi`.
    public var config: ZeroMcpConfig

    /// Called once per local tool execution through `mcp` `tools/call`; the
    /// result is passed as `ctx.runtime` (Node's `getEnv`). Direct
    /// `routes[i].tool.execute` calls build their own context.
    public var getRuntime: (() -> Any?)?

    public init(config: ZeroMcpConfig = ZeroMcpConfig(), getRuntime: (() -> Any?)? = nil) {
        self.config = config
        self.getRuntime = getRuntime
    }
}

public struct Registry {
    public let routes: [RegistryRoute]
    public let openapi: [String: Any]
    public let mcp: McpHandler
}

/// Build a framework-neutral registry from a plain tool map.
///
/// `tools` uses the same `ToolDefinition` struct the `.tool()` builder on
/// `ZeroMcp` produces internally (Tool.swift:56) — construct it directly
/// via `ToolDefinition(description:input:permissions:route:execute:)`
/// without going through a `ZeroMcp` instance's builder DSL.
public func createRegistry(
    _ tools: [String: ToolDefinition],
    options: RegistryOptions = RegistryOptions()
) async -> Registry {
    let instance = ZeroMcp(config: options.config)
    instance.tools = tools
    instance.getRuntime = options.getRuntime
    await instance.connectRemotes()

    let routes = tools
        .filter { $0.value.route != nil }
        .sorted(by: { $0.key < $1.key })
        .map { name, tool -> RegistryRoute in
            let route = tool.route!
            return RegistryRoute(name: name, method: route.method, path: route.path, tool: tool)
        }

    return Registry(
        routes: routes,
        openapi: instance.buildOpenApiSpec(),
        mcp: { request in await instance.handleRequest(request) }
    )
}
