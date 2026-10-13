Java

# 988 lines.  
No Spring. No Netty.

`zeromcp` vs `mcp-java-sdk` — side by side.

Tested April 7, 2026 · zeromcp-benchmarks v1.0 · Reviewed by ZeroMCP Team

Dependencies

1 ZeroMCP

vs.

15 Official SDK

Throughput

4.38K req/s ZeroMCP

vs.

2.40K req/s Official SDK

Memory

207 MB ZeroMCP

vs.

217 MB Official SDK

## This is a hello world

A server builder, JsonSchema objects, CallToolResult wrapping, and transport setup. 13 lines of ceremony before your tool does anything.

mcp-java-sdk 13 lines

```
var server = McpServer.sync("test")
    .tool(new SyncToolSpecification(
        new Tool("hello", "Say hello",
            new JsonSchemaObject(Map.of("name",
                new JsonSchemaString()))),
        (exchange, args) -> new CallToolResult(
            List.of(new TextContent(
                "Hello, " + args.get("name") + "!"))
        )
    ))
    .build();
var transport = new StdioServerTransport();
server.connect(transport);
```

## This is the whole server

No builder chain. No JsonSchema objects. No CallToolResult wrapping.  
Register a lambda and serve.

ZeroMCP 7 lines

```
var server = new ZeroMcp();
server.tool("hello", Tool.builder()
    .description("Say hello")
    .input(new Input().required("name", "string"))
    .execute((args, ctx) ->
        "Hello, " + args.get("name") + "!")
    .build());
server.serveStdio();
```

## HTTP Performance — Head to Head

Mixed workload across all 7 MCP method types. 5-minute sustained load in Docker. Javalin for ZeroMCP, stdio proxy for the official SDK.

req/s CPU Memory Ratio

ZeroMCP (Javalin) 4.38K 0.16% 207 MB 1.8x

Official SDK 2.40K 0.15% 217 MB

## The tradeoff

Choose the official SDK

If you're already in a Spring stack and want familiar abstractions — McpServer builders, annotation-driven configuration.

-   Builder pattern — full builder pattern with typed schemas
-   Spec parity — tracks every spec change immediately
-   Enterprise support — maintained by the MCP specification team at Anthropic

Choose ZeroMCP

If you want one dependency (gson), plain java.net.http, and a minimal classpath you can reason about.

-   1 dependency (gson)
-   Plain java.net.http — no framework lock-in
-   Javalin HTTP embedding
-   Built-in sandbox with enforced permissions
-   4.38K req/s on Javalin

## Register a function. It's an MCP tool.

[Get started](https://github.com/antidrift-dev/zeromcp/blob/main/docs/getting-started.md) [All comparisons →](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/README.md) [See all benchmarks →](https://github.com/antidrift-dev/zeromcp-benchmarks/blob/main/writeups/README.md)

## Other languages

[Node.js](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/modelcontextprotocol-sdk-vs-zeromcp-nodejs.md) [Python](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/fastmcp-vs-zeromcp-python.md) [Go](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-go-sdk-vs-zeromcp-go.md) [Rust](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/rmcp-vs-zeromcp-rust.md) [Java](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-java-sdk-vs-zeromcp-java.md) [Kotlin](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-kotlin-sdk-vs-zeromcp-kotlin.md) [Swift](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-swift-sdk-vs-zeromcp-swift.md) [C#](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/modelcontextprotocol-dotnet-vs-zeromcp-csharp.md) [Ruby](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-ruby-gem-vs-zeromcp-ruby.md) [PHP](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-php-sdk-vs-zeromcp-php.md)
