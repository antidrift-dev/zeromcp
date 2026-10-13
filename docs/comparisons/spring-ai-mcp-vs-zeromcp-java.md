Java

# 1.9x faster.  
No Spring required.

`ZeroMCP` vs `spring-ai-mcp` — HTTP benchmarks.

Tested April 7, 2026 · zeromcp-benchmarks v1.0 · Reviewed by ZeroMCP Team

Throughput

4.51K req/s ZeroMCP

vs.

2.44K req/s spring-ai-mcp

Memory

200 MB ZeroMCP

vs.

284 MB spring-ai-mcp

## HTTP Performance — Head to Head

Same hello tool. Same methodology. 5-minute sustained load in Docker. Javalin for ZeroMCP, Spring Boot for spring-ai-mcp.

req/s p50 p99 Memory CPU

ZeroMCP (Javalin) 4.51K 0.21ms ~1ms 200 MB 0.16%

spring-ai-mcp 2.44K 0.32ms 0.97ms 284 MB 0.22%

## The tradeoff

Choose spring-ai-mcp

If you already live in the Spring ecosystem. Auto-configuration, dependency injection, familiar annotation patterns.

-   Spring auto-configuration
-   Dependency injection built in
-   Familiar annotation patterns

Choose ZeroMCP

If you want to stay lean. One JAR, no Spring, 1.9x faster, 84 MB less memory.

-   1 dependency (gson)
-   Plain java.net.http — no framework lock-in
-   Javalin HTTP embedding
-   Built-in sandbox with enforced permissions
-   4.51K req/s on Javalin

## Drop a .java file. It's an MCP tool.

[Get started](https://github.com/antidrift-dev/zeromcp/blob/main/docs/getting-started.md) [All comparisons →](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/README.md) [See all benchmarks →](https://github.com/antidrift-dev/zeromcp-benchmarks/blob/main/writeups/README.md)

## Other languages

[Node.js](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/modelcontextprotocol-sdk-vs-zeromcp-nodejs.md) [Python](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/fastmcp-vs-zeromcp-python.md) [Go](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-go-sdk-vs-zeromcp-go.md) [Rust](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/rmcp-vs-zeromcp-rust.md) [Java](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-java-sdk-vs-zeromcp-java.md) [Kotlin](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-kotlin-sdk-vs-zeromcp-kotlin.md) [Swift](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-swift-sdk-vs-zeromcp-swift.md) [C#](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/modelcontextprotocol-dotnet-vs-zeromcp-csharp.md) [Ruby](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-ruby-gem-vs-zeromcp-ruby.md) [PHP](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-php-sdk-vs-zeromcp-php.md)
