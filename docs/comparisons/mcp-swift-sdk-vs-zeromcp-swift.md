Swift

# 1,311 lines.  
Zero SPM dependencies.

`zeromcp` vs `swift-sdk` — side by side.

Tested April 7, 2026 · zeromcp-benchmarks v1.0 · Reviewed by ZeroMCP Team

Dependencies

0 ZeroMCP

vs.

8 Official SDK

Throughput

1.81K req/s ZeroMCP

vs.

64 req/s Official SDK

Memory

96 MB ZeroMCP

vs.

39 MB Official SDK

## This is a hello world

Server instantiation, schema dictionaries, tool registration, and transport setup. 10 lines before your tool does anything.

swift-sdk 10 lines

```
let server = MCPServer(
    name: "test", version: "1.0.0")
server.registerTool("hello",
    description: "Say hello",
    inputSchema: [
        "name": .string
    ]) { args in
    .text("Hello, \(args["name"] as! String)!")
}
try await server.runStdio()
```

## This is the whole server

No schema dictionaries. No MCPServer constructor ceremony.  
Register a closure and serve.

ZeroMCP 8 lines

```
let server = Server()
server.tool("hello",
    description: "Say hello",
    input: Input()
        .required("name", "string")
) { args, ctx in
    "Hello, \(args["name"] as! String)!"
}
try await server.serve()
```

## HTTP Performance — Head to Head

Mixed workload across all 7 MCP method types. 5-minute sustained load in Docker. Vapor for ZeroMCP, stdio proxy for the official SDK.

req/s CPU Memory Ratio

ZeroMCP (Vapor) 1.81K 0.21% 96 MB 28x

Official SDK 64 1.76% 39 MB

The official Swift SDK manages 64 req/s at 1.76% CPU. ZeroMCP on Vapor delivers 1.81K at 0.21% CPU.

## The tradeoff

Choose the official SDK

If you need the full MCP protocol implementation and don't mind swift-nio as a dependency.

-   Swift concurrency types — full concurrency integration with typed parameters
-   Spec parity — tracks every spec change immediately
-   Enterprise support — maintained by the MCP specification team at Anthropic

Choose ZeroMCP

If you want zero SPM dependencies, 1,311 lines, and 28x the throughput on Vapor.

-   0 SPM dependencies
-   1,311 lines — small enough to audit
-   Vapor HTTP embedding
-   Built-in sandbox with enforced permissions
-   1.81K req/s on Vapor

## Register a function. It's an MCP tool.

[Get started](https://github.com/antidrift-dev/zeromcp/blob/main/docs/getting-started.md) [All comparisons →](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/README.md) [See all benchmarks →](https://github.com/antidrift-dev/zeromcp-benchmarks/blob/main/writeups/README.md)

## Other languages

[Node.js](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/modelcontextprotocol-sdk-vs-zeromcp-nodejs.md) [Python](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/fastmcp-vs-zeromcp-python.md) [Go](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-go-sdk-vs-zeromcp-go.md) [Rust](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/rmcp-vs-zeromcp-rust.md) [Java](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-java-sdk-vs-zeromcp-java.md) [Kotlin](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-kotlin-sdk-vs-zeromcp-kotlin.md) [Swift](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-swift-sdk-vs-zeromcp-swift.md) [C#](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/modelcontextprotocol-dotnet-vs-zeromcp-csharp.md) [Ruby](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-ruby-gem-vs-zeromcp-ruby.md) [PHP](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-php-sdk-vs-zeromcp-php.md)
