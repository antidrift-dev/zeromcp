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

ZeroMCP doesn't ship an HTTP server. It gives you stdio (`Serve()`), a registry and a request handler; you mount those in the HTTP server you already run.

`Registry.Create(tools)` returns plain data:

- `Routes`: every tool with a `Route`, as `(Name, Method, Path, Tool)`
- `OpenApi`: an OpenAPI 3.0 document for those routes
- `Mcp`: a JSON-RPC handler, `JsonDocument` in, response dictionary out (`null` for notifications)

**ASP.NET Minimal API**

```csharp
using System.Text.Json;
using ZeroMcp;

var registry = Registry.Create(new Dictionary<string, ToolDefinition>
{
    ["greet"] = new ToolDefinition
    {
        Description = "Greet a person by name",
        Input = new() { ["name"] = new InputField(SimpleType.String) },
        Route = new ToolRoute { Method = "GET", Path = "/greet/:name" },
        Execute = (args, ctx) => Task.FromResult<object>($"Hello, {args["name"].GetString()}!")
    }
});

var app = WebApplication.CreateBuilder(args).Build();

// MCP over HTTP
app.MapPost("/mcp", async (HttpContext ctx) =>
{
    var doc = await JsonDocument.ParseAsync(ctx.Request.Body);
    var response = await registry.Mcp(doc);
    if (response == null) { ctx.Response.StatusCode = 204; return; }
    await ctx.Response.WriteAsJsonAsync(response);
});

// OpenAPI
app.MapGet("/openapi.json", () => Results.Json(registry.OpenApi));

// REST routes ("/greet/:name" -> "/greet/{name}")
foreach (var route in registry.Routes)
{
    var pattern = System.Text.RegularExpressions.Regex.Replace(route.Path, @":(\w+)", "{$1}");
    app.MapMethods(pattern, new[] { route.Method }, async (HttpContext ctx) =>
    {
        var input = new Dictionary<string, JsonElement>();
        foreach (var (k, v) in ctx.Request.RouteValues)
            input[k] = JsonSerializer.SerializeToElement(v?.ToString());
        foreach (var (k, v) in ctx.Request.Query)
            input[k] = JsonSerializer.SerializeToElement(v.ToString());
        if (ctx.Request.HasJsonContentType())
        {
            var body = await JsonDocument.ParseAsync(ctx.Request.Body);
            foreach (var p in body.RootElement.EnumerateObject()) input[p.Name] = p.Value.Clone();
        }
        var result = await route.Tool.Execute!(input, new ToolContext { ToolName = route.Name });
        return Results.Json(new { ok = true, result });
    });
}

app.Run("http://0.0.0.0:4242");
```

`RegistryOptions.GetContext` builds the `ToolContext` for every `Mcp` call, so you can put per-request credentials or runtime state on it.

If you prefer a `ZeroMcpServer` you've already built, `await server.Prepare()` once, then call `server.HandleRequest(doc)` from your `/mcp` endpoint.

A config with `"transport": [{"type": "http"}]` makes `Serve()` throw `InvalidOperationException`: the built-in HTTP transport was removed in 0.4.0 (`ServeHttp` is gone). Mount `Registry.Create` or `HandleRequest` as shown above.

## Remote servers

Federate tools from other MCP servers over HTTP. Each remote tool is exposed as `<name>.<tool>`; a local tool with the same name wins.

```json
{
  "remote": [
    { "name": "probeo", "url": "https://mcp.example.com/mcp", "auth": "env:PROBEO_TOKEN", "tools": ["list_pages"] }
  ]
}
```

- `auth`: `env:VAR` reads the environment variable; anything else is sent as-is. Both go out as `Authorization: Bearer <value>`.
- `tools`: optional allowlist of upstream tool names. Omit it to expose everything.
- A server that fails to connect is logged and skipped.

`Serve()` connects remotes from `zeromcp.config.json` on startup. When embedding, call `await server.Prepare()` before `HandleRequest`. For the registry, use the async form:

```csharp
var registry = await Registry.CreateAsync(tools, new RegistryOptions
{
    Remote = new() { new RemoteServer { Name = "probeo", Url = "https://mcp.example.com/mcp" } }
});
```

Remote tools are reachable through `registry.Mcp` only; they have no route and don't appear in `Routes` or `OpenApi`. `Registry.Create` throws if `Remote` is set.

## Runtime context

Set `GetRuntime` to hand every local tool call a value of your choosing as `ctx.Runtime` (a DB handle, request-scoped state, a clock). It is called once per tool execution.

```csharp
var server = new ZeroMcpServer { GetRuntime = () => services };

server.Tool("count_users", new ToolDefinition
{
    Description = "Count users",
    Execute = async (args, ctx) => await ((MyServices)ctx.Runtime!).Users.CountAsync()
});
```

With the registry, use `RegistryOptions.GetContext` instead; it builds the whole context, including `Runtime`.

## Config

`zeromcp.config.json` in the working directory (all keys optional):

| Key | Meaning |
| --- | --- |
| `remote` | Remote MCP servers to federate (see above) |
| `page_size` | Page size for list methods; `0` (default) disables pagination. A `pageSize` constructor argument wins. |
| `icon` | Data URI, `http(s)` URL, or file path; resolved to a data URI and applied to every tool, resource and prompt. An `Icon` set in code wins. |
| `execute_timeout` | Tool timeout in ms (default 30000) |
| `title` | OpenAPI title |
| `logging`, `bypass_permissions`, `cache_credentials` | As in the other ZeroMCP languages |

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
    Permissions = new Permissions
    {
        Network = new[] { "api.example.com", "*.internal.dev" },
        Fs = false,
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
