Go

# Go chose zero dependencies.  
Your MCP SDK didn't.

`zeromcp` vs `go-sdk` — side by side.

Tested April 7, 2026 · zeromcp-benchmarks v1.0 · Reviewed by ZeroMCP Team

Dependencies

0 ZeroMCP

vs.

7 Official SDK

Throughput

4.88K req/s ZeroMCP

vs.

730 req/s Official SDK

Memory

23 MB ZeroMCP

vs.

44 MB Official SDK

## This is a hello world

Imports, a server constructor, a builder pattern, a schema definition, and a type assertion. Go developers expect less ceremony.

go-sdk 8 lines

```
import "github.com/modelcontextprotocol/go-sdk/mcp"

s := mcp.NewServer("test", "1.0.0")
s.AddTool(mcp.NewTool("hello",
    mcp.WithString("name", mcp.Required()),
), func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
    name := req.Params.Arguments["name"].(string)
    return mcp.NewToolResultText(fmt.Sprintf("Hello, %s!", name)), nil
})
```

## This is the whole server

No builder pattern. No type assertions. No CallToolResult wrapping.  
Register a function and serve.

ZeroMCP 8 lines

```
s := zeromcp.NewServer()
s.Tool("hello", zeromcp.Tool{
    Description: "Say hello",
    Input: zeromcp.Input{"name": "string"},
    Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
        return fmt.Sprintf("Hello, %s!", args["name"]), nil
    },
})
s.ServeStdio()
```

## HTTP Performance — Head to Head

Mixed workload across all 7 MCP method types. 5-minute sustained load in Docker. Chi for ZeroMCP, stdio proxy for the official SDK.

req/s CPU Memory Ratio

ZeroMCP (Chi) 4.88K 0.00% 23 MB 6.7x

Official SDK 730 0.03% 44 MB

The official Go SDK bottlenecks at 730 req/s through the stdio proxy. ZeroMCP on Chi runs natively at 4.88K.

## The tradeoff

Choose the official SDK

If your team already uses its module ecosystem and you want typed struct-based tool registration with auto-generated schemas.

-   Struct validation — compile-time schema validation with Go structs
-   Spec parity — tracks every spec change immediately
-   Enterprise support — maintained by the MCP specification team at Anthropic

Choose ZeroMCP

If you want zero dependencies, stdlib only, and a handler that mounts on any Go router. Simpler to audit, simpler to vendor.

-   0 dependencies — stdlib only
-   Chi + net/http + Gin
-   Built-in sandbox with enforced permissions
-   4.88K req/s on Chi

## Register a function. It's an MCP tool.

[Get started](https://github.com/antidrift-dev/zeromcp/blob/main/docs/getting-started.md) [All comparisons →](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/README.md) [See all benchmarks →](https://github.com/antidrift-dev/zeromcp-benchmarks/blob/main/writeups/README.md)

## Other languages

[Node.js](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/modelcontextprotocol-sdk-vs-zeromcp-nodejs.md) [Python](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/fastmcp-vs-zeromcp-python.md) [Go](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-go-sdk-vs-zeromcp-go.md) [Rust](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/rmcp-vs-zeromcp-rust.md) [Java](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-java-sdk-vs-zeromcp-java.md) [Kotlin](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-kotlin-sdk-vs-zeromcp-kotlin.md) [Swift](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-swift-sdk-vs-zeromcp-swift.md) [C#](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/modelcontextprotocol-dotnet-vs-zeromcp-csharp.md) [Ruby](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-ruby-gem-vs-zeromcp-ruby.md) [PHP](https://github.com/antidrift-dev/zeromcp/blob/main/docs/comparisons/mcp-php-sdk-vs-zeromcp-php.md)
