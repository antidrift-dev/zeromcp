# ZeroMCP &mdash; C#

Sandboxed MCP server library for .NET. Register tools, call `server.Serve()`, done.

## Getting started

```csharp
using ZeroMcp;

var server = new ZeroMcpServer();

server.Tool("hello", new ToolDefinition
{
    Description = "Say hello to someone",
    Input = new Dictionary<string, InputField>
    {
        ["name"] = new InputField(SimpleType.String)
    },
    Execute = async (args, ctx) =>
    {
        var name = args["name"].GetString() ?? "world";
        return $"Hello, {name}!";
    }
});

await server.Serve();
```

Stdio works immediately. No transport configuration needed.

## vs. the official SDK

The official C# SDK (backed by Microsoft) requires server setup, transport configuration, and schema definition. ZeroMCP handles the protocol, transport, and schema generation with a clean async/await API.

In benchmarks, ZeroMCP C# handles 14,013 requests/second over stdio versus the official SDK's 9,776 — 1.4x faster with 34% less memory (33 MB vs 50 MB). Over HTTP (ASP.NET), ZeroMCP serves 4,421 rps versus the official SDK's 2,517 rps.

C# passes all 10 conformance suites and survives 21/22 chaos monkey attacks.

The official SDK has **no sandbox**. ZeroMCP lets tools declare network, filesystem, and exec permissions.

## HTTP / Streamable HTTP

ZeroMCP doesn't own the HTTP layer. You bring your own framework; ZeroMCP gives you an async `HandleRequest` method that takes a `JsonDocument` and returns a response dictionary (or `null` for notifications).

```csharp
// var response = await server.HandleRequest(request);
```

**ASP.NET Minimal API**

```csharp
var builder = WebApplication.CreateBuilder(args);
var app = builder.Build();

app.MapPost("/mcp", async (HttpContext ctx) =>
{
    var doc = await JsonDocument.ParseAsync(ctx.Request.Body);
    var response = await server.HandleRequest(doc);
    if (response == null)
    {
        ctx.Response.StatusCode = 204;
        return;
    }
    ctx.Response.ContentType = "application/json";
    await ctx.Response.WriteAsJsonAsync(response);
});

app.Run("http://0.0.0.0:4242");
```

## Requirements

- .NET 8

## Build & run

```sh
dotnet run --project Example
```

Or publish a self-contained binary:

```sh
dotnet publish Example -c Release -o ./out
./out/Example
```

## Sandbox

```csharp
server.Tool("fetch_data", new ToolDefinition
{
    Description = "Fetch from our API",
    Input = new Dictionary<string, InputField>
    {
        ["url"] = new InputField(SimpleType.String)
    },
    Permissions = new ToolPermissions
    {
        Network = new[] { "api.example.com", "*.internal.dev" },
        Fs = FsPermission.None,
        Exec = false
    },
    Execute = async (args, ctx) => { /* ... */ }
});
```

## Project reference

```xml
<ProjectReference Include="../ZeroMcp/ZeroMcp.csproj" />
```

## Testing

```sh
dotnet test
```
