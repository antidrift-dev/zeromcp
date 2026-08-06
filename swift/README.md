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

## HTTP / Streamable HTTP

ZeroMCP ships a built-in HTTP server (POSIX sockets — Linux + macOS, no framework required). Register a tool with a `route:` to expose it as a REST endpoint too:

```swift
server.tool(
    "greet",
    description: "Greet a person by name",
    input: ["name": .simple(.string)],
    route: RouteDefinition(method: "GET", path: "/greet/:name")
) { args, ctx in
    "Hello, \(args["name"] as? String ?? "world")!"
}

await server.serveHttp(port: 3000)
```

`serveHttp` also exposes:

- `POST /mcp` — JSON-RPC over HTTP
- `GET /health` — health check
- `GET /openapi.json` — OpenAPI 3.0 spec generated from registered routes
- `GET /docs` — Swagger UI

### Bring your own framework

You don't have to use `serveHttp`. ZeroMCP also gives you an async `handleRequest` method that takes a `[String: Any]` dict and returns `[String: Any]?`, so you can wire it into any HTTP framework yourself.

```swift
// let response = await server.handleRequest(request)
```

**Vapor**

```swift
import Vapor

let app = try Application(.detect())

app.post("mcp") { req async throws -> Response in
    let request = try req.content.decode([String: AnyCodable].self)
    let dict = request.mapValues { $0.value }

    if let response = await server.handleRequest(dict) {
        let body = try JSONSerialization.data(withJSONObject: response)
        return Response(status: .ok, headers: ["Content-Type": "application/json"], body: .init(data: body))
    }
    return Response(status: .noContent)
}

try app.run()
```

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
