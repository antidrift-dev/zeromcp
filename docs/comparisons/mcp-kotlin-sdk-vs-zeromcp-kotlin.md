Kotlin

# Coroutines without  
the SDK ceremony.

`zeromcp` vs `kotlin-sdk` — side by side.

Tested April 7, 2026 · zeromcp-benchmarks v1.0 · Reviewed by ZeroMCP Team

Dependencies

2 ZeroMCP

vs.

~30 Official SDK

Throughput

3.40K req/s ZeroMCP

vs.

328 req/s Official SDK

Memory

194 MB ZeroMCP

vs.

204 MB Official SDK

## This is a hello world

Server options, map-based schemas, CallToolResult wrapping, and transport setup. 11 lines of Kotlin DSL that could be simpler.

kotlin-sdk 11 lines

```
val server = Server(ServerOptions(
    name = "test", version = "1.0.0"))
server.addTool("hello", "Say hello",
    inputSchema = mapOf(
        "name" to mapOf("type" to "string")
    )) { args ->
    CallToolResult(content = listOf(
        TextContent("Hello, ${args["name"]}!")
    ))
}
server.connectStdio()
```

## This is the whole server

No ServerOptions. No CallToolResult. No map-based schemas.  
A DSL that reads like Kotlin should.

ZeroMCP 8 lines

```
val server = Server()
server.tool("hello") {
    description = "Say hello"
    input { required("name", "string") }
    execute { args, ctx ->
        "Hello, ${args["name"]}!"
    }
}
server.serveStdio()
```

## HTTP Performance — Head to Head

Mixed workload across all 7 MCP method types. 5-minute sustained load in Docker. Ktor for ZeroMCP, stdio proxy for the official SDK.

req/s CPU Memory Ratio

ZeroMCP (Ktor) 3.40K 0.11% 194 MB 10x

Official SDK 328 0.19% 204 MB

## The tradeoff

Choose the official SDK

If you want the coroutine-based API with full MCP spec coverage and don't mind the ~30 transitive dependencies.

-   DSL definitions — full Kotlin SDK DSL with typed parameters
-   Spec parity — tracks every spec change immediately
-   Enterprise support — maintained by the MCP specification team at Anthropic

Choose ZeroMCP

If you want 2 dependencies (kotlinx essentials), a clean DSL, and 10x more throughput.

-   2 dependencies (kotlinx essentials)
-   Clean DSL — reads like Kotlin should
-   Ktor HTTP embedding
-   Built-in sandbox with enforced permissions
-   3.40K req/s on Ktor

## Register a function. It's an MCP tool.

[Get started](https://github.com/antidrift-dev/zeromcp/blob/main/docs/getting-started.md) [All comparisons →](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/README.md) [See all benchmarks →](https://github.com/antidrift-dev/zeromcp-benchmarks/blob/main/writeups/README.md)

## Other languages

[Node.js](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/modelcontextprotocol-sdk-vs-zeromcp-nodejs.md) [Python](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/fastmcp-vs-zeromcp-python.md) [Go](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-go-sdk-vs-zeromcp-go.md) [Rust](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/rmcp-vs-zeromcp-rust.md) [Java](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-java-sdk-vs-zeromcp-java.md) [Kotlin](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-kotlin-sdk-vs-zeromcp-kotlin.md) [Swift](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-swift-sdk-vs-zeromcp-swift.md) [C#](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/modelcontextprotocol-dotnet-vs-zeromcp-csharp.md) [Ruby](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-ruby-gem-vs-zeromcp-ruby.md) [PHP](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-php-sdk-vs-zeromcp-php.md)
