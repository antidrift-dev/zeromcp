# Framework-neutral tool registry — C#

## Status

**Spec — not yet implemented.** This document is the port design for the framework-neutral registry that Node.js already shipped (`nodejs/src/registry.ts`, see `specs/lang/nodejs/registry.md`). It targets the C# implementation at `csharp/ZeroMcp/`.

## Motivation

`csharp/ZeroMcp/Server.cs` (`ZeroMcpServer`) already does two things beyond stdio JSON-RPC:

- `ServeHttp(int port)` starts an `HttpListener` and, per request, dispatches to route-tagged tools (`HandleHttpContext`, lines 177–332) — matching `tool.Route.Method`/`tool.Route.Path` against the incoming request, extracting path/query/body params, and calling `tool.Execute`.
- `BuildOpenApiSpec()` (private, lines 879–961) builds an OpenAPI 3.0 document from every tool that has a `Route`, reusing `tool.Input`/`InputField` to produce parameter/request-body schemas.

Both are locked inside `ZeroMcpServer`'s own `HttpListener` loop. A consumer who wants ZeroMCP tools mounted inside ASP.NET Core minimal APIs, an Azure Function app, an AWS Lambda handler, or any other .NET HTTP surface has no way to get at the route list or the OpenAPI document without instantiating a `ZeroMcpServer` and reverse-engineering its private HTTP-handling internals.

This is **additive** — `ZeroMcpServer.ServeHttp`/`Serve` are unchanged. The registry is a second, composable entry point for embedding, matching Node's `registry.ts` shape and rationale.

## Public API

New file: `csharp/ZeroMcp/Registry.cs`, namespace `ZeroMcp` (same namespace as `Server.cs`, `Tool.cs`, `Schema.cs`, `Config.cs`).

```csharp
namespace ZeroMcp;

/// <summary>A single JSON-RPC request/response round trip, reusing ZeroMcpServer's own dispatch.</summary>
public delegate Task<Dictionary<string, object?>?> McpHandler(JsonDocument request);

/// <summary>One route-tagged tool, exposed as plain data — no HTTP binding is done here.</summary>
public record RouteDefinition(string Name, string Method, string Path, ToolDefinition Tool);

public class RegistryOptions
{
    /// <summary>
    /// Supplies the ToolContext passed to every tool's Execute when invoked through
    /// ToolRegistry.Mcp or a caller-driven route dispatch. Defaults to a context with
    /// only ToolName/Permissions populated (Credentials left null), matching what
    /// ZeroMcpServer.CallTool already constructs.
    /// </summary>
    public Func<string, Permissions?, ToolContext>? GetContext { get; set; }
}

public class ToolRegistry
{
    public IReadOnlyList<RouteDefinition> Routes { get; init; } = Array.Empty<RouteDefinition>();
    public Dictionary<string, object> OpenApi { get; init; } = new();
    public McpHandler Mcp { get; init; } = null!;
}

public static class Registry
{
    public static ToolRegistry Create(
        Dictionary<string, ToolDefinition> tools,
        RegistryOptions? options = null);
}
```

Usage:

```csharp
var registry = Registry.Create(new Dictionary<string, ToolDefinition>
{
    ["greet"] = new ToolDefinition { Description = "...", Route = new ToolRoute { Method = "GET", Path = "/greet/:name" }, Execute = ... },
});

// registry.Routes  -> wire into ASP.NET Core minimal APIs, an Azure Function, a Lambda handler, etc.
// registry.OpenApi -> serve as static JSON at whatever path the caller wants.
// registry.Mcp     -> app.MapPost("/mcp", async (JsonDocument body) => await registry.Mcp(body));
```

### Behavior

- `tools` is the same `Dictionary<string, ToolDefinition>` shape used by `ZeroMcpServer.Tool(name, ToolDefinition)` — no new tool type. `ToolDefinition` (in `Tool.cs`) already carries `Description`, `Input`, `Permissions`, optional `Route`, and `Execute`.
- `Registry.Create` builds an internal `ZeroMcpServer` and registers every entry via the existing `server.Tool(name, def)` overload (Server.cs line 33), so schema caching (`CachedSchema`, computed once at registration — Server.cs line 35) happens exactly as it does for `Serve`/`ServeHttp`. No dispatch logic is duplicated.
- `Mcp` is `server.HandleRequest` (Server.cs line 365, already `public async Task<Dictionary<string, object?>?> HandleRequest(JsonDocument request)`) exposed directly as the `McpHandler` delegate — it is a drop-in JSON-RPC handler for any transport the caller already has (an ASP.NET Core endpoint reading the request body into a `JsonDocument`, a Lambda handler, etc.).
- `Routes` is derived by filtering the tool dictionary down to entries where `Route != null`, in dictionary-iteration order, projecting each into a `RouteDefinition(name, tool.Route.Method, tool.Route.Path, tool)`. This is the same filter `HandleHttpContext` (line 251: `if (tool.Route == null) continue;`) and `BuildOpenApiSpec` (line 886) already apply inline — the registry just externalizes the result as data instead of consuming it internally. No path matching (`MatchRoutePath`, Server.cs line 338), query/body param extraction, or response writing is done by the registry — that stays the caller's framework's job, same as Node's port note.
- `OpenApi` reuses `ZeroMcpServer.BuildOpenApiSpec()` (Server.cs lines 879–961) verbatim. That method is currently `private`; it must be changed to `internal` so `Registry.Create` (same assembly, `ZeroMcp` namespace) can call it without exposing it as public API on `ZeroMcpServer`. No other change to `BuildOpenApiSpec` is needed — `:param` → `{param}` conversion, path-vs-query parameter inference, and request-body schema generation via `BuildOpenApiPropertySchema` all carry over unchanged. `OpenApi` is computed once at `Registry.Create` time (not per-request), same as Node.
- `RegistryOptions.GetContext`: **judgment call, no direct Node equivalent.** Node's `Tool<TEnv>.execute(args, env)` is generic over an arbitrary `TEnv`; C#'s `ToolDefinition.Execute` is fixed as `Func<Dictionary<string, JsonElement>, ToolContext, Task<object>>` (Tool.cs line 32) — `ToolContext` (already carrying `ToolName`, `Credentials`, `Permissions`) is the existing "env" concept in this codebase, not a caller-supplied generic type. Making the registry generic over `TEnv` would require making `ToolDefinition`/`Execute` generic too, a breaking change to the whole package far outside this port's scope. Instead, `RegistryOptions.GetContext` is an optional factory that lets the caller override how the per-call `ToolContext` is constructed (e.g. to populate `Credentials` from their framework's request context) when a tool is invoked through `registry.Mcp`. If omitted, the registry builds `ToolContext` exactly as `ZeroMcpServer.CallTool` already does today (Server.cs line 542: `new ToolContext { ToolName = name, Permissions = tool.Permissions }` — `Credentials` left `null`, since no existing dispatch path in this codebase populates it either).
- No auth hook, matching Node — auth is left to the caller's ASP.NET Core middleware / Azure Function auth binding / API Gateway authorizer, etc.

### Non-goals

- Does not replace or call into `ZeroMcpServer.Serve()` or `ZeroMcpServer.ServeHttp()`.
- Does not perform any HTTP request/response handling, routing, or body parsing — `Routes` is data (`RouteDefinition` records), not wired ASP.NET Core endpoints. In particular, this spec does not add `Microsoft.AspNetCore.*` route registration helpers; a thin adapter (e.g. an extension method that maps `RouteDefinition[]` onto `IEndpointRouteBuilder`) could be a *later*, separate addition, but is out of scope here to keep the registry dependency-free.
- Does not depend on any web framework package. `ZeroMcp.csproj` currently has no dependencies beyond the BCL (`System.Text.Json` is part of the shared framework on net8.0) — that remains true.

## Packaging

- New source file: `csharp/ZeroMcp/Registry.cs`, added to the existing `ZeroMcp` project (`csharp/ZeroMcp/ZeroMcp.csproj`) — no new `.csproj`, no new NuGet package. It ships as part of `Antidrift.ZeroMcp` (current version `0.2.2`) the same way `Server.cs`/`Tool.cs`/`Schema.cs`/`Config.cs` do.
- Visibility change required: `ZeroMcpServer.BuildOpenApiSpec()` goes from `private` to `internal` so `Registry.cs` (same assembly) can call it. No public surface of `ZeroMcpServer` changes.
- No new dependencies added to `ZeroMcp.csproj`.
- Consumers use it as `using ZeroMcp; var registry = Registry.Create(tools);` after `dotnet add package Antidrift.ZeroMcp` — same package, no new install.
- A conformance example analogous to `csharp/RouteTest/Program.cs` (which currently exercises `ServeHttp` directly) should get a sibling, e.g. `csharp/RegistryTest/Program.cs`, that builds a registry from the same two tools (`greet`, `echo`) and exercises `registry.Routes`/`registry.OpenApi`/`registry.Mcp` directly (mirroring how the Node port would be conformance-tested) rather than going through `ServeHttp`.

## Porting notes / what this port reused vs. added

Reused, unchanged:
1. `ToolDefinition` and its optional `Route` field (`Tool.cs`) — no new tool type introduced.
2. `ZeroMcpServer.Tool(name, ToolDefinition)` for registration and schema caching.
3. `ZeroMcpServer.HandleRequest(JsonDocument)` for the `Mcp` handler — the exact same JSON-RPC dispatch used by `Serve()`/`ServeHttp()`'s `/mcp` endpoint.
4. `ZeroMcpServer.BuildOpenApiSpec()` for the `OpenApi` document — same output shape `/openapi.json` already returns, just changed from `private` to `internal`.

New in this port:
1. `Registry.cs` with the `Registry.Create(...)` static factory, `ToolRegistry` class, `RouteDefinition` record, `McpHandler` delegate, and `RegistryOptions` class.
2. The `RegistryOptions.GetContext` hook, since C#'s dispatch (unlike Node's `execute(args, env)`) threads context through a fixed `ToolContext` type rather than an arbitrary generic — this is the one place the port diverges in shape from Node, documented above.

## Fixed: existing `BuildOpenApiSpec()` had the same non-GET path-param bug as Node

Auditing all 10 languages for the Node bug above found the exact same bug already shipped in C#'s own `BuildOpenApiSpec()` (`csharp/ZeroMcp/Server.cs`, method starts line 879), pre-dating this registry spec entirely — it's used by `ServeHttp`'s `/openapi.json` route today. For a non-GET route with a `:param` segment (e.g. `PUT /items/:id`), the `else` branch (`Server.cs:929-947`, prior to this fix) built `requestBody` from *every* `tool.Input` field, including path-param ones, and never added a `parameters` array for them at all — `id` was undocumented as a path parameter and silently duplicated into the JSON body schema instead.

**Fixed directly** (not just specified) in `Server.cs`: the `else` branch's `foreach` loop (line 933-937) now `continue`s past any `fieldName` present in `pathParamNames` before adding it to `properties`/`required`, and — when `pathParamNames.Count > 0` (line 949-959) — adds a `parameters` array documenting each path param as `{ name, in: "path", required: true, schema: { type: "string" } }`, matching the `if (routeMethod == "get")` branch's existing path-parameter shape (line 910-928). `dotnet build` was not available to run in this environment (no `dotnet` SDK installed on the host used for the fix), so the change was verified by code review only: brace/type matching against the surrounding method, and confirming `pathParamNames.Select(...)` (line 951) follows the same `System.Linq` usage already present just above it (line 895-897) under this project's `ImplicitUsings` setting. This means the C# port's reuse of `BuildOpenApiSpec()` (point 4 above) now gets the corrected behavior for free — no divergent logic for the registry to carry.
