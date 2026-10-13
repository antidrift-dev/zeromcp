Rust

# 2.6 MB of memory.  
That's the whole runtime.

`zeromcp` vs `rmcp` — side by side.

Tested April 7, 2026 · zeromcp-benchmarks v1.0 · Reviewed by ZeroMCP Team

Dependencies

3 ZeroMCP

vs.

6 Official SDK

Throughput

5.40K req/s ZeroMCP

vs.

2.19K req/s Official SDK

Memory

4 MB ZeroMCP

vs.

2.42 GB Official SDK

## This is a hello world

Proc-macro imports, a server builder, tool attribute macros, and transport setup. 12 lines before your tool does anything.

rmcp 12 lines

```
use rmcp::{Server, Tool, tool};

#[tool(description = "Say hello")]
async fn hello(name: String) -> String {
    format!("Hello, {name}!")
}

#[tokio::main]
async fn main() {
    Server::new("test", "1.0.0")
        .tool(hello)
        .serve_stdio()
        .await;
}
```

## This is the whole server

No proc macros. No server builder. No attribute ceremony.  
Register a closure and serve.

ZeroMCP 8 lines

```
let mut server = Server::new();
server.add_tool("hello", "Say hello",
    Input::new().required("name", "string"),
    |args: Value, _ctx: Ctx| Box::pin(async move {
        let name = args["name"].as_str().unwrap_or("world");
        Ok(Value::String(format!("Hello, {name}!")))
    })
);
server.serve().await;
```

## HTTP Performance — Head to Head

Mixed workload across all 7 MCP method types. 5-minute sustained load in Docker. Actix for ZeroMCP, stdio proxy for the official SDK.

req/s CPU Memory Ratio

ZeroMCP (Actix) 5.40K 0.17% 4 MB 2.5x

Official SDK 2.19K 0.03% 2.42 GB

The official Rust SDK leaks memory — 2.42 GB over 5 minutes. ZeroMCP Actix holds steady at 4 MB.

## The tradeoff

Choose rmcp

If you want the macro-based tool registration system and don't mind pinning to nightly-adjacent Rust versions.

-   Macro-based tools — derive macros for tool definitions
-   Spec parity — tracks every spec change immediately
-   Enterprise support — maintained by the MCP specification team at Anthropic

Choose ZeroMCP

If you want stable Rust (1.78+), predictable memory (4 MB flat), and a handler that embeds in Actix or Axum.

-   Stable Rust 1.78+
-   Actix + Axum
-   4 MB memory — flat under sustained load
-   Built-in sandbox with enforced permissions
-   5.40K req/s on Actix

## Register a function. It's an MCP tool.

[Get started](https://github.com/antidrift-dev/zeromcp/blob/main/docs/getting-started.md) [All comparisons →](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/README.md) [See all benchmarks →](https://github.com/antidrift-dev/zeromcp-benchmarks/blob/main/writeups/README.md)

## Other languages

[Node.js](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/modelcontextprotocol-sdk-vs-zeromcp-nodejs.md) [Python](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/fastmcp-vs-zeromcp-python.md) [Go](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-go-sdk-vs-zeromcp-go.md) [Rust](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/rmcp-vs-zeromcp-rust.md) [Java](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-java-sdk-vs-zeromcp-java.md) [Kotlin](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-kotlin-sdk-vs-zeromcp-kotlin.md) [Swift](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-swift-sdk-vs-zeromcp-swift.md) [C#](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/modelcontextprotocol-dotnet-vs-zeromcp-csharp.md) [Ruby](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-ruby-gem-vs-zeromcp-ruby.md) [PHP](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-php-sdk-vs-zeromcp-php.md)
