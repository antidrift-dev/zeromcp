15 Comparisons 10 Languages HTTP Benchmarks

# Every MCP framework.  
Side by side.

Official SDKs, third-party frameworks, and ZeroMCP. Same tool, same transport, same machine. Pick your language and see the numbers.

Official MCP SDKs

## ZeroMCP vs the official SDK for each language

The official MCP SDK exists for every language we support. Here's how they compare on HTTP performance, dependencies, and memory.

[

Node.js 1.6x

@modelcontextprotocol/sdk

4.19K vs 2.59K req/s 0 vs 91 deps

](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/modelcontextprotocol-sdk-vs-zeromcp-nodejs.md)[

Python 4.9x

FastMCP / mcp

3.08K vs 623 req/s 0 vs 37 deps

](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/fastmcp-vs-zeromcp-python.md)[

Go 6.7x

go-sdk

4.88K vs 730 req/s 0 vs 7 deps

](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-go-sdk-vs-zeromcp-go.md)[

Rust 2.5x

rmcp

5.40K vs 2.19K req/s 3 vs 6 deps

](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/rmcp-vs-zeromcp-rust.md)[

Java 1.8x

mcp-java-sdk

4.38K vs 2.40K req/s 1 vs 15 deps

](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-java-sdk-vs-zeromcp-java.md)[

Kotlin 10x

kotlin-sdk

3.40K vs 328 req/s 2 vs ~30 deps

](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-kotlin-sdk-vs-zeromcp-kotlin.md)[

Swift 28x

swift-sdk

1.81K vs 64 req/s 0 vs 8 deps

](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-swift-sdk-vs-zeromcp-swift.md)[

C# 2.0x

ModelContextProtocol

4.69K vs 2.36K req/s 0 vs 41 deps

](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/modelcontextprotocol-dotnet-vs-zeromcp-csharp.md)[

Ruby 2.0x

mcp gem

4.26K vs 2.16K req/s 0 vs 90 deps

](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-ruby-gem-vs-zeromcp-ruby.md)[

PHP 81x

mcp/sdk

1.30K vs 16 req/s 0 vs 22 deps

](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-php-sdk-vs-zeromcp-php.md)

* * *

Third-Party Frameworks

## ZeroMCP vs popular community MCP frameworks

Not everyone uses the official SDK. These are the most popular alternatives — tested the same way.

[

mcp-framework 2.4x

Node.js — TypeScript MCP framework

5.50K vs 2.30K req/s 141 MB memory

](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-framework-vs-zeromcp-nodejs.md)[

mcp-go (mark3labs) 1.1x

Go — community MCP library

4.74K vs 4.20K req/s 14 MB memory

](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-go-mark3labs-vs-zeromcp-go.md)[

spring-ai-mcp 1.9x

Java — Spring Boot MCP integration

4.51K vs 2.44K req/s 284 MB memory

](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/spring-ai-mcp-vs-zeromcp-java.md)[

zeromcp-mrexodia 2.0x

Python — lightweight MCP server

3.53K vs 1.80K req/s 13 MB memory

](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/zeromcp-mrexodia-vs-zeromcp-python.md)[

fast-mcp 1.3x

Ruby — MCP gem with DSL

4.76K vs 3.73K req/s 48 MB memory

](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/fast-mcp-vs-zeromcp-ruby.md)

* * *

Methodology

## How we test

Every comparison uses the same setup. [Run them yourself.](https://github.com/antidrift-dev/zeromcp-benchmarks)

**Same tool**

Hello world — identical input, identical output. No advantage from tool complexity.

**HTTP transport**

JSON-RPC 2.0 over HTTP POST. The protocol MCP clients use in production.

**Docker isolated**

Each server in its own container. Pinned versions. No host interference.

**5 min sustained**

Not a burst test. 300 seconds of continuous load. Snapshots every 10 seconds.
