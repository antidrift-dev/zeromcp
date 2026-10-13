Node.js

# 2.4x faster.  
Half the memory.

`ZeroMCP` vs `mcp-framework` — HTTP benchmarks.

Tested April 7, 2026 · zeromcp-benchmarks v1.0 · Reviewed by ZeroMCP Team

Throughput

5.50K req/s ZeroMCP

vs.

2.30K req/s mcp-framework

Memory

77 MB ZeroMCP

vs.

141 MB mcp-framework

## HTTP Performance — Head to Head

Same hello tool. Same methodology. 5-minute sustained load in Docker. Bare HTTP for ZeroMCP, mcp-framework with Express transport.

req/s p50 p99 Memory CPU

ZeroMCP (bare http) 5.50K 0.17ms 0.32ms 77 MB 0.02%

mcp-framework 2.30K 0.36ms 0.99ms 141 MB 0.03%

## The tradeoff

Choose mcp-framework

If you want a batteries-included TypeScript framework with class-based tools and built-in Express scaffolding.

-   Batteries-included TypeScript framework
-   Class-based tool definitions
-   Built-in Express scaffolding

Choose ZeroMCP

If you want to own your HTTP stack. Embed in Express, Fastify, or bare http — 2.4x faster, half the memory.

-   0 dependencies
-   File-based tools — drop a .js file, it's live
-   19 HTTP frameworks supported
-   Built-in sandbox with enforced permissions
-   5.50K req/s on bare http

## Drop a .js file. It's an MCP tool.

[Get started](https://github.com/antidrift-dev/zeromcp/blob/main/docs/getting-started.md) [All comparisons →](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/README.md) [See all benchmarks →](https://github.com/antidrift-dev/zeromcp-benchmarks/blob/main/writeups/README.md)

## Other languages

[Node.js](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/modelcontextprotocol-sdk-vs-zeromcp-nodejs.md) [Python](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/fastmcp-vs-zeromcp-python.md) [Go](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-go-sdk-vs-zeromcp-go.md) [Rust](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/rmcp-vs-zeromcp-rust.md) [Java](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-java-sdk-vs-zeromcp-java.md) [Kotlin](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-kotlin-sdk-vs-zeromcp-kotlin.md) [Swift](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-swift-sdk-vs-zeromcp-swift.md) [C#](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/modelcontextprotocol-dotnet-vs-zeromcp-csharp.md) [Ruby](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-ruby-gem-vs-zeromcp-ruby.md) [PHP](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-php-sdk-vs-zeromcp-php.md)
