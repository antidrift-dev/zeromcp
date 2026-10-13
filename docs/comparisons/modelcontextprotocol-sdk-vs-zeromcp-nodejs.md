Node.js

# 91 packages installed  
for a hello world.

`zeromcp` vs `@modelcontextprotocol/sdk` — side by side.

Tested April 7, 2026 · zeromcp-benchmarks v1.0 · Reviewed by ZeroMCP Team

Dependencies

0 ZeroMCP

vs.

91 Official SDK

Throughput

4.19K req/s ZeroMCP

vs.

2.59K req/s Official SDK

Memory

26 MB ZeroMCP

vs.

174 MB Official SDK

## This is a hello world

3 imports. A server class. A Zod schema. A transport. 12 lines before your tool does anything.

@modelcontextprotocol/sdk 12 lines

```
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const server = new McpServer({ name: "test", version: "1.0.0" });

server.tool("hello", { name: z.string() }, async ({ name }) => ({
  content: [{ type: "text", text: `Hello, ${name}!` }],
}));

const transport = new StdioServerTransport();
await server.connect(transport);
```

## This is the whole server

No server class. No schema library. No transport setup.  
Drop it in a folder and run `zeromcp serve`.

ZeroMCP 9 lines

```
// tools/hello.js
export default {
  description: "Say hello to someone",
  input: {
    name: 'string',
  },
  execute: async ({ name }) => {
    return `Hello, ${name}!`;
  },
};
```

## HTTP Performance — Head to Head

Mixed workload across all 7 MCP method types. 5-minute sustained load in Docker. bare http for ZeroMCP, stdio proxy for the official SDK.

req/s CPU Memory Ratio

ZeroMCP (bare http) 4.19K 0.02% 26 MB 1.6x

Official SDK 2.59K 0.02% 174 MB

## The tradeoff

Choose the official SDK

If you need same-day MCP spec update tracking or enterprise support contracts. The official SDK is maintained by the spec team at Anthropic and ships new spec features the day they're announced.

-   Zod schemas — native runtime type checking if your team standardizes on Zod
-   Spec parity — tracks every spec change immediately
-   Enterprise support — maintained by the MCP specification team at Anthropic

Choose ZeroMCP

If you want to ship fast. Drop a file, embed in your existing HTTP server, zero dependencies. Production performance without the ceremony.

-   0 dependencies
-   File-based tools — drop a .js file, it's live
-   19 HTTP frameworks supported
-   Built-in sandbox with enforced permissions
-   4.19K req/s on bare http

## Drop a .js file. It's an MCP tool.

[Get started](https://github.com/antidrift-dev/zeromcp/blob/main/docs/getting-started.md) [All comparisons →](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/README.md) [See all benchmarks →](https://github.com/antidrift-dev/zeromcp-benchmarks/blob/main/writeups/README.md)

## Other languages

[Node.js](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/modelcontextprotocol-sdk-vs-zeromcp-nodejs.md) [Python](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/fastmcp-vs-zeromcp-python.md) [Go](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-go-sdk-vs-zeromcp-go.md) [Rust](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/rmcp-vs-zeromcp-rust.md) [Java](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-java-sdk-vs-zeromcp-java.md) [Kotlin](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-kotlin-sdk-vs-zeromcp-kotlin.md) [Swift](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-swift-sdk-vs-zeromcp-swift.md) [C#](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/modelcontextprotocol-dotnet-vs-zeromcp-csharp.md) [Ruby](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-ruby-gem-vs-zeromcp-ruby.md) [PHP](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-php-sdk-vs-zeromcp-php.md)
