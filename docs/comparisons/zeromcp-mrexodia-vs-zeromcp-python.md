Python

# 2.0x faster throughput.  
Production HTTP transport.

`ZeroMCP` vs `zeromcp-mrexodia` — HTTP benchmarks.

Tested April 7, 2026 · zeromcp-benchmarks v1.0 · Reviewed by ZeroMCP Team

Throughput

3.53K req/s ZeroMCP

vs.

1.80K req/s mrexodia

Memory

30 MB ZeroMCP

vs.

13 MB mrexodia

## HTTP Performance — Head to Head

Same hello tool. Same methodology. 5-minute sustained load in Docker. Starlette for ZeroMCP, built-in transport for zeromcp-mrexodia.

req/s p50 p99 Memory CPU

ZeroMCP (Starlette) 3.53K 0.27ms 0.57ms 30 MB 0.28%

zeromcp-mrexodia 1.80K 0.45ms 1.24ms 13 MB 0.04%

## The tradeoff

Choose mrexodia

If memory footprint is your top priority. 13 MB is hard to beat. Great for resource-constrained environments.

-   13 MB memory footprint
-   Lightweight built-in transport
-   Great for resource-constrained environments

Choose ZeroMCP

If you need production throughput. 2.0x faster on Starlette with enforced sandboxing and credential injection.

-   0 dependencies
-   File-based tools — drop a .py file, it's live
-   Starlette + FastAPI + Flask
-   Built-in sandbox with enforced permissions
-   3.53K req/s on Starlette

## Drop a .py file. It's an MCP tool.

[Get started](https://github.com/antidrift-dev/zeromcp/blob/main/docs/getting-started.md) [All comparisons →](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/README.md) [See all benchmarks →](https://github.com/antidrift-dev/zeromcp-benchmarks/blob/main/writeups/README.md)

## Other languages

[Node.js](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/modelcontextprotocol-sdk-vs-zeromcp-nodejs.md) [Python](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/fastmcp-vs-zeromcp-python.md) [Go](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-go-sdk-vs-zeromcp-go.md) [Rust](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/rmcp-vs-zeromcp-rust.md) [Java](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-java-sdk-vs-zeromcp-java.md) [Kotlin](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-kotlin-sdk-vs-zeromcp-kotlin.md) [Swift](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-swift-sdk-vs-zeromcp-swift.md) [C#](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/modelcontextprotocol-dotnet-vs-zeromcp-csharp.md) [Ruby](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-ruby-gem-vs-zeromcp-ruby.md) [PHP](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-php-sdk-vs-zeromcp-php.md)
