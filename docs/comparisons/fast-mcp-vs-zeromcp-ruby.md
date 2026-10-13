Ruby

# 1.3x faster.  
Less memory. Zero gems.

`ZeroMCP` vs `fast-mcp` — HTTP benchmarks.

Tested April 7, 2026 · zeromcp-benchmarks v1.0 · Reviewed by ZeroMCP Team

Throughput

4.76K req/s ZeroMCP

vs.

3.73K req/s fast-mcp

Memory

33 MB ZeroMCP

vs.

48 MB fast-mcp

## HTTP Performance — Head to Head

Same hello tool. Same methodology. 5-minute sustained load in Docker. Rack+Puma for ZeroMCP, fast-mcp with built-in server.

req/s p50 p99 Memory CPU

ZeroMCP (Rack+Puma) 4.76K 0.19ms 0.43ms 33 MB 0.06%

fast-mcp 3.73K 0.23ms 0.57ms 48 MB 0.02%

## The tradeoff

Choose fast-mcp

If you want a Ruby DSL for rapid prototyping with a built-in server. Quick to start, familiar gem workflow.

-   Ruby DSL for rapid prototyping
-   Built-in server — quick to start
-   Familiar gem workflow

Choose ZeroMCP

If you want to run on infrastructure you already trust. Rack+Puma, zero gems, 1.3x faster, less memory.

-   0 gems
-   File-based tools — drop a .rb file, it's live
-   Rack+Puma + Sinatra
-   Built-in sandbox with enforced permissions
-   4.76K req/s on Rack+Puma

## Drop a .rb file. It's an MCP tool.

[Get started](https://github.com/antidrift-dev/zeromcp/blob/main/docs/getting-started.md) [All comparisons →](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/README.md) [See all benchmarks →](https://github.com/antidrift-dev/zeromcp-benchmarks/blob/main/writeups/README.md)

## Other languages

[Node.js](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/modelcontextprotocol-sdk-vs-zeromcp-nodejs.md) [Python](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/fastmcp-vs-zeromcp-python.md) [Go](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-go-sdk-vs-zeromcp-go.md) [Rust](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/rmcp-vs-zeromcp-rust.md) [Java](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-java-sdk-vs-zeromcp-java.md) [Kotlin](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-kotlin-sdk-vs-zeromcp-kotlin.md) [Swift](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-swift-sdk-vs-zeromcp-swift.md) [C#](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/modelcontextprotocol-dotnet-vs-zeromcp-csharp.md) [Ruby](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-ruby-gem-vs-zeromcp-ruby.md) [PHP](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-php-sdk-vs-zeromcp-php.md)
