# ZeroMCP &mdash; Swift

Sandboxed MCP server library for Swift. Register tools, call `server.serve()`, done.

## Getting started

```swift
import ZeroMcp

let server = ZeroMcp()

server.tool(
    "hello",
    description: "Say hello to someone",
    input: ["name": .simple(.string)]
) { args, ctx in
    "Hello, \(args["name"] as? String ?? "world")!"
}

await server.serve()
```

Stdio works immediately. No transport configuration needed.

## vs. the official SDK

The official Swift SDK requires server setup, transport configuration, and schema definition. ZeroMCP handles the protocol, transport, and schema generation with native Swift async/await and zero external dependencies.

In benchmarks, ZeroMCP Swift handles 7,947 requests/second over stdio versus the official SDK's 80 — 99x faster with 27% less memory (19 MB vs 26 MB). Over HTTP (Vapor), ZeroMCP serves 1,730 rps at 49-96 MB versus the official SDK's 74 rps at 25-39 MB. The official SDK takes 12ms per request and burns 1.76% CPU. ZeroMCP takes 0.48ms at 0.21% CPU.

Swift passes all 10 conformance suites and survives 21/22 chaos monkey attacks.

The official SDK has **no sandbox**. ZeroMCP lets tools declare network, filesystem, and exec permissions.

## HTTP

ZeroMCP doesn't ship an HTTP server. You mount it in the one you already run (Vapor, Hummingbird, anything).

### `createRegistry`: routes, OpenAPI and MCP as plain data

`createRegistry(_:options:)` turns a tool map into three things you can mount:

- `registry.routes`: one `RegistryRoute` (`name`, `method`, `path` with `:param` segments, `tool`) per tool that has a `route:`
- `registry.openapi`: an OpenAPI 3.0 document (`[String: Any]`) for those routes
- `registry.mcp`: the JSON-RPC handler (`[String: Any]` in, `[String: Any]?` out; nil means a notification, so reply 204)

**Vapor**

```swift
import Vapor
import ZeroMcp

let tools: [String: ToolDefinition] = [
    "greet": ToolDefinition(
        description: "Greet a person by name",
        input: ["name": .simple(.string)],
        route: RouteDefinition(method: "GET", path: "/greet/:name")
    ) { args, _ in
        "Hello, \(args["name"] as? String ?? "world")!"
    },
]

let registry = await createRegistry(tools)
let app = try await Application.make(.detect())

func json(_ object: Any, status: HTTPStatus = .ok) throws -> Response {
    let body = try JSONSerialization.data(withJSONObject: object)
    return Response(status: status, headers: ["Content-Type": "application/json"], body: .init(data: body))
}

func bodyObject(_ req: Request) -> [String: Any] {
    guard let buffer = req.body.data,
          let object = try? JSONSerialization.jsonObject(with: Data(buffer.readableBytesView)) as? [String: Any]
    else { return [:] }
    return object
}

// MCP over HTTP
app.post("mcp") { req async throws -> Response in
    guard let response = await registry.mcp(bodyObject(req)) else { return Response(status: .noContent) }
    return try json(response)
}

// OpenAPI
app.get("openapi.json") { _ in try json(registry.openapi) }

// One REST endpoint per routed tool
for route in registry.routes {
    app.on(HTTPMethod(rawValue: route.method), route.path.pathComponents) { req async throws -> Response in
        var args: [String: Any] = route.method == "GET"
            ? ((try? req.query.decode([String: String].self)) ?? [:])
            : bodyObject(req)
        for (key, value) in req.parameters.all { args[key] = value }
        let ctx = ToolContext(toolName: route.name, permissions: route.tool.permissions)
        let result = try await route.tool.execute(args, ctx)
        return try json(["ok": true, "result": result])
    }
}

try await app.execute()
```

### `handleRequest`: a `ZeroMcp` instance as the MCP endpoint

If you already build a `ZeroMcp` with `.tool()`, its `handleRequest(_:)` is the same JSON-RPC handler. Call `prepare()` once after registering tools and before handling requests: it connects `remote` servers and resolves `icon` (`serve()` and `createRegistry` do this for you).

```swift
let server = ZeroMcp()
server.tool("hello", description: "Say hello", input: ["name": .simple(.string)]) { args, _ in
    "Hello, \(args["name"] as? String ?? "world")!"
}
await server.prepare()

app.post("mcp") { req async throws -> Response in
    guard let response = await server.handleRequest(bodyObject(req)) else { return Response(status: .noContent) }
    return try json(response)
}
```

### The `http` transport is gone

A config with `"transport": [{"type": "http"}]` makes `serve()` exit with:

```
[zeromcp] The http transport was removed. Mount createRegistry(_:) (routes, openapi, mcp) in your own HTTP server.
```

The built-in HTTP server that shipped in 0.3.0 has been removed. Replace it by mounting `createRegistry(_:)` as shown above.

## Remote servers

List other MCP servers (HTTP, JSON responses) under `remote`, and their tools appear as `<name>.<tool>`:

```json
{
  "remote": [
    { "name": "probeo", "url": "https://mcp.example.com/mcp", "auth": "env:PROBEO_TOKEN", "tools": ["list_pages"] }
  ]
}
```

- `auth` is sent as `Authorization: Bearer <token>`. `env:VAR` reads an environment variable; anything else is used literally.
- `tools` is an allowlist of upstream tool names. Leave it out to expose them all.
- A local tool with the same name wins, and `[zeromcp] Local tool "<name>" overrides remote` is logged.
- A server that can't be reached is logged and skipped. The others still connect.
- Remote tools have no `route`, so they never appear in `registry.routes` or `registry.openapi`.

Remotes are connected by `serve()`, by `createRegistry` (from `options.config.remote`) and by `prepare()`.

```swift
let config = ZeroMcpConfig(remote: [RemoteServer(name: "probeo", url: "https://mcp.example.com/mcp", auth: "env:PROBEO_TOKEN")])
let registry = await createRegistry(tools, options: RegistryOptions(config: config))
```

## Runtime context

Set `getRuntime` to hand per-call context (tenant, request info, a database handle) to your tools as `ctx.runtime`. It's called once per local tool execution. Remote tools don't receive it.

```swift
server.getRuntime = { ["tenant": currentTenant()] }

server.tool("whoami", description: "Current tenant") { _, ctx in
    (ctx.runtime as? [String: String])?["tenant"] ?? "unknown"
}

// Registry equivalent
let registry = await createRegistry(tools, options: RegistryOptions(getRuntime: { ["tenant": currentTenant()] }))
```

## Config

`ZeroMcp()` reads `./zeromcp.config.json`. You can also pass `ZeroMcpConfig(...)` directly.

| Key | Meaning |
|---|---|
| `title` | OpenAPI title |
| `execute_timeout` | Default tool timeout in seconds (30) |
| `bypass_permissions`, `logging`, `cache_credentials` | Sandbox and credential behavior |
| `page_size` | Cursor pagination for list methods (0 = off) |
| `icon` | Data URI, `http(s)` URL (fetched) or file path (read; `~` expands). Becomes a data URI on every tool, resource and prompt. An `icon` set in code wins. |
| `remote` | Remote MCP servers (see above) |
| `transport` | Only `stdio` is supported; `http` is an error |

## Requirements

- Swift 5.9+
- macOS 13+

## Build & run

```sh
swift build
.build/debug/zeromcp-example
```

## Sandbox

```swift
server.tool(
    "fetch_data",
    description: "Fetch from our API",
    input: ["url": .simple(.string)],
    permissions: Permissions(
        network: .allowlist(["api.example.com"]),
        fs: .none,
        exec: false
    )
) { args, ctx in
    // ...
}
```

## Package dependency

Add to your `Package.swift`:

```swift
dependencies: [
    .package(path: "../swift")  // or a remote URL
]
```

## Testing

```sh
swift test
```
