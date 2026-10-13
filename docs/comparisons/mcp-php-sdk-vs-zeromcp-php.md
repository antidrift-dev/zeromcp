PHP

# Faster than bare echo.  
593 lines.

`zeromcp` vs `mcp/sdk` — side by side.

Tested April 7, 2026 · zeromcp-benchmarks v1.0 · Reviewed by ZeroMCP Team

Dependencies

0 ZeroMCP

vs.

22 Official SDK

Throughput

1.30K req/s ZeroMCP

vs.

16 req/s Official SDK

Memory

33 MB ZeroMCP

vs.

64 MB Official SDK

## This is a hello world

Use statement, server instantiation, class-based registration, schema array, and transport setup. 9 lines of ceremony before your tool does anything.

mcp/sdk 9 lines

```
use Mcp\Server\McpServer;

$server = new McpServer('test', '1.0.0');
$server->registerTool('hello',
    'Say hello',
    ['name' => ['type' => 'string']],
    function($args) {
        return "Hello, {$args['name']}!";
    });
$server->runStdio();
```

## This is the whole server

No use statement. No server class. No registration closures.  
Drop it in a folder and run `zeromcp serve`.

ZeroMCP 9 lines

```
<?php
// tools/hello.php
$TOOL = [
    'description' => 'Say hello',
    'input' => ['name' => 'string']
];

function execute($args, $ctx) {
    return "Hello, {$args['name']}!";
}
```

## HTTP Performance — Head to Head

Mixed workload across all 7 MCP method types. 5-minute sustained load in Docker. Slim for ZeroMCP, stdio proxy for the official SDK.

req/s CPU Memory Ratio

ZeroMCP (Slim) 1.30K 0.00% 33 MB 81x

Official SDK 16 0.36% 64 MB

The official PHP SDK processes 16 requests per second (54ms each). ZeroMCP on Slim handles 1.30K — 81x faster.

## The tradeoff

Choose mcp/sdk

If you want the official Composer package and are building on the standard PHP MCP transport layer.

-   Class registration — OOP class-based tool registration
-   Spec parity — tracks every spec change immediately
-   Enterprise support — maintained by the MCP specification team at Anthropic

Choose ZeroMCP

If you want 81x the throughput, zero Composer dependencies, and a .php file that just works.

-   0 Composer dependencies
-   File-based tools — drop a .php file, it's live
-   Slim HTTP embedding
-   Built-in sandbox with enforced permissions
-   1.30K req/s on Slim

## Drop a .php file. It's an MCP tool.

[Get started](https://github.com/antidrift-dev/zeromcp/blob/main/docs/getting-started.md) [All comparisons →](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/README.md) [See all benchmarks →](https://github.com/antidrift-dev/zeromcp-benchmarks/blob/main/writeups/README.md)

## Other languages

[Node.js](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/modelcontextprotocol-sdk-vs-zeromcp-nodejs.md) [Python](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/fastmcp-vs-zeromcp-python.md) [Go](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-go-sdk-vs-zeromcp-go.md) [Rust](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/rmcp-vs-zeromcp-rust.md) [Java](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-java-sdk-vs-zeromcp-java.md) [Kotlin](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-kotlin-sdk-vs-zeromcp-kotlin.md) [Swift](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-swift-sdk-vs-zeromcp-swift.md) [C#](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/modelcontextprotocol-dotnet-vs-zeromcp-csharp.md) [Ruby](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-ruby-gem-vs-zeromcp-ruby.md) [PHP](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-php-sdk-vs-zeromcp-php.md)
