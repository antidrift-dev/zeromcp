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

The official SDK has **no sandbox**. ZeroMCP lets tools declare network, filesystem, and exec permissions.

## HTTP / Streamable HTTP

ZeroMCP doesn't own the HTTP layer. You bring your own framework; ZeroMCP gives you an async `handleRequest` method that takes a `[String: Any]` dict and returns `[String: Any]?`.

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
        network: .allowList(["api.example.com"]),
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
