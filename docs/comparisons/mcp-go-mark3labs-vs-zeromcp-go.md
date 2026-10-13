Go

# 1.1x faster.  
Zero dependencies.

`ZeroMCP` vs `mcp-go` (mark3labs) — HTTP benchmarks.

Tested April 7, 2026 · zeromcp-benchmarks v1.0 · Reviewed by ZeroMCP Team

Throughput

4.74K req/s ZeroMCP

vs.

4.20K req/s mark3labs

Memory

30 MB ZeroMCP

vs.

14 MB mark3labs

## HTTP Performance — Head to Head

Same hello tool. Same methodology. 5-minute sustained load in Docker. Chi router for ZeroMCP, built-in HTTP for mcp-go.

req/s p50 p99 Memory CPU

ZeroMCP (Chi) 4.74K 0.18ms 0.45ms 30 MB 0.00%

mcp-go (mark3labs) 4.20K 0.17ms 0.67ms 14 MB 0.00%

## The tradeoff

Choose mcp-go

If you want the leanest possible binary. 14 MB with built-in HTTP transport. No router dependency.

-   14 MB binary — leanest option
-   Built-in HTTP transport
-   No router dependency required

Choose ZeroMCP

If you want to embed MCP into an existing Go service. Mount on Chi, Gin, or net/http — 1.1x faster with zero dependencies.

-   0 dependencies — stdlib only
-   Chi + net/http + Gin
-   Built-in sandbox with enforced permissions
-   4.74K req/s on Chi

## Drop a .go file. It's an MCP tool.

[Get started](https://github.com/antidrift-dev/zeromcp/blob/main/docs/getting-started.md) [All comparisons →](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/README.md) [See all benchmarks →](https://github.com/antidrift-dev/zeromcp-benchmarks/blob/main/writeups/README.md)

## Other languages

[Node.js](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/modelcontextprotocol-sdk-vs-zeromcp-nodejs.md) [Python](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/fastmcp-vs-zeromcp-python.md) [Go](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-go-sdk-vs-zeromcp-go.md) [Rust](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/rmcp-vs-zeromcp-rust.md) [Java](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-java-sdk-vs-zeromcp-java.md) [Kotlin](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-kotlin-sdk-vs-zeromcp-kotlin.md) [Swift](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-swift-sdk-vs-zeromcp-swift.md) [C#](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/modelcontextprotocol-dotnet-vs-zeromcp-csharp.md) [Ruby](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-ruby-gem-vs-zeromcp-ruby.md) [PHP](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-php-sdk-vs-zeromcp-php.md)
