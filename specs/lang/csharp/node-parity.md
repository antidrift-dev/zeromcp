# Node parity — C#

## Status

Not started. Spec only.

## Gaps

1. Remote federation (`remote` config) in `ZeroMcpServer`
2. Remote allowlist (`remote[].tools`)
3. Remote in the `HandleRequest` embedding path
4. Remote in the registry (`Registry.CreateAsync`)
5. Runtime context injection (`ToolContext.Runtime`)
6. ~~Multiple transports from config (`transport`)~~ (dropped: no built-in HTTP server)
7. Missing config keys: `page_size`, `icon`

## 1. Remote federation in `ZeroMcpServer`

**Node does:** `serve()` connects each `config.remote` server before local tools (server.ts:23-28) via `RemoteManager.connect` (remote.ts:20-38): reject non-http(s) URL (remote.ts:41-43); POST JSON-RPC `initialize` (id 1, params {}) then `tools/list` (id 2) with `Content-Type: application/json` and `Authorization: Bearer <auth>` when `resolveAuth(auth)` yields a value (`env:VAR` → env var, else literal; config.ts:153-166); non-2xx throws `HTTP <status>` (remote.ts:87-99). Each remote tool's `inputSchema` goes through `schemaToInput` (type defaults to `string`, `description` kept, not-in-required → optional; remote.ts:101-121) and its execute POSTs `tools/call` {name, arguments} with id `Date.now()`, returning `result.content[0].text` if truthy else `result` (remote.ts:69-79). Tools are named `<server.name>.<toolName>`; a failing server logs `[mcp] Failed to connect to <name>: <msg>` and is skipped. Local tools override remote with `[zeromcp] Local tool "<name>" overrides remote` (server.ts:33-36). Remote tools have no route.

**C# today:** `ZeroMcpConfig` has no `remote` key (Config.cs:6-27). No HTTP client code anywhere in `csharp/` (grep for `HttpClient` returns nothing). `Serve()` (Server.cs:118) and `ServeHttp()` (Server.cs:170) dispatch only tools registered via `Tool()` (Server.cs:41, 47).

**Change:**

- `Config.cs`: add the config class, the `remote` key, and `ResolveAuth`.

```csharp
public class RemoteServer
{
    [JsonPropertyName("name")]  public string Name { get; set; } = "";
    [JsonPropertyName("url")]   public string Url { get; set; } = "";
    [JsonPropertyName("auth")]  public string? Auth { get; set; }
    [JsonPropertyName("tools")] public List<string>? Tools { get; set; }   // see gap 2
}

// on ZeroMcpConfig
[JsonPropertyName("remote")]
public List<RemoteServer>? Remote { get; set; }

// "env:VAR" -> Environment.GetEnvironmentVariable(VAR) (warn "[zeromcp] Warning: environment variable VAR not set" if empty); else literal; null -> null
internal static string? ResolveAuth(string? auth);
```

- New file `csharp/ZeroMcp/Remote.cs`: `internal static class RemoteManager` with one shared `static readonly HttpClient`.

```csharp
internal static class RemoteManager
{
    // Returns "<server.Name>.<toolName>" -> ToolDefinition. Never throws; per-server failures are logged and skipped.
    internal static Task<Dictionary<string, ToolDefinition>> Connect(IEnumerable<RemoteServer> servers);
}
```

- Behavior of `Connect`, port of remote.ts as-is:
  - URL not starting with `http://` or `https://` → throw `Remote server "<name>" must have an HTTP/HTTPS URL, got: <url>` (caught by the per-server loop).
  - `HttpRpc`: POST `StringContent(json, UTF8, "application/json")`; add `Authorization: Bearer <auth>` when `ResolveAuth(server.Auth)` is non-empty; non-success status → throw `HTTP <statusCode as int>`; parse body as `JsonDocument`.
  - Send `initialize` (id 1, params {}), then `tools/list` (id 2, params {}). Read `result.tools` (missing → empty list).
  - `SchemaToInput(JsonElement inputSchema)` → `Dictionary<string, InputField>`: for each `properties` entry, type = `type` string or `"string"` if absent, parsed case-insensitively to `SimpleType`; an unparseable type throws `Unknown type "<t>" for field "<key>"` (matches Node's `toJsonSchema` throwing, which fails the whole server). `Description` kept; `Optional = !required.Contains(key)`.
  - Each remote tool becomes a `ToolDefinition { Description, Input, Route = null, Permissions = null, Execute }`. `Execute` ignores `ctx`, POSTs `tools/call` with id `DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()` and params `{ name, arguments }` (arguments = the `Dictionary<string, JsonElement>` it was given). Returns `result.content[0].text` when it is a non-empty string, otherwise `result` as a cloned `JsonElement` (or `null` when `result` is absent).
  - Logs, to stderr: `[mcp] Remote tool: <ns>` per tool, `[mcp] Connected to <name> (HTTP): <n> tool(s)` per server, `[mcp] Failed to connect to <name>: <message>` on failure.
- `Server.cs`:
  - Add `private readonly HashSet<string> _remoteTools = new();`.
  - Add `internal async Task ConnectRemotes(IEnumerable<RemoteServer> servers)`: for each returned tool, compute `CachedSchema` as `Tool()` does. If `_tools` already holds a local tool with that name → log `[zeromcp] Local tool "<name>" overrides remote` and keep the local one. Otherwise add it and record it in `_remoteTools`.
  - Both `Tool(...)` overloads: if `name` is in `_remoteTools` → log the same override line, remove it from `_remoteTools`, then register as today. This keeps "local wins" true whichever order the caller uses.
  - Add `public Task Prepare()` (details in gap 3). `Serve()` and `ServeHttp()` `await Prepare()` before their startup log lines, so the tool counts include remote tools.
- Remote tools have `Route == null`, so the existing filters in `HandleHttpContext` (Server.cs:251) and `BuildOpenApiSpec` (Server.cs:888) already exclude them. No change needed there.
- Node's "No tools directory and no remote servers configured" exit is N/A: C# has no tool scan that can fail.

**Tests:** new `csharp/ZeroMcp.Tests/RemoteTests.cs` (xunit, same style as `RegistryTests.cs`). Add a stub upstream: an `HttpListener` on `http://127.0.0.1:<free port>/` that answers `initialize`, `tools/list` (`list_pages` {domain: string, required}, `get_page` {url: string, required}) and `tools/call` (`content: [{type:"text", text:"{\"pages\":[]}"}]`), echoing the request id, the same as `nodejs/test/handler-remote.test.js:6-18`. Cases:
- `Prepare()` with `remote: [{name:"probeo", url}]` → `tools/list` via `HandleRequest` lists `probeo.list_pages`, `probeo.get_page`; `tools/call probeo.list_pages` returns the stub's text.
- A local `Tool("probeo.list_pages", ...)` registered before and after `Prepare()` → the local result wins and stderr contains `overrides remote` (capture with `Console.SetError`).
- Two servers, one `ftp://...` and one valid → only the valid server's tools are present; stderr contains `Failed to connect to <bad>`.
- Stub returns 500 for one server → `Failed to connect to <name>: HTTP 500`.
- `auth: "env:ZEROMCP_TEST_TOKEN"` → the stub sees `Authorization: Bearer <value>`; a literal `auth` is sent as-is.
- `SchemaToInput`: a property with no `type` becomes `string`; `description` is preserved in `tools/list`; a non-required property is optional (call without it passes validation).
- The remote tool is absent from `BuildOpenApiSpec()["paths"]`.

## 2. Remote allowlist

**Node does:** `remote[].tools?: string[]` filters upstream `tools/list` to the named tools; omitted means all (config.ts:9, remote.ts:61).

**C# today:** No `remote` config at all (Config.cs:6-27).

**Change:** `RemoteServer.Tools` (gap 1). In `RemoteManager`, after reading `result.tools`, keep a tool only if `server.Tools == null || server.Tools.Contains(tool.name)`. An empty list exposes nothing, the same as Node's `[].includes`.

**Tests:** in `RemoteTests.cs`: `tools: ["list_pages"]` → `tools/list` returns only `probeo.list_pages` (the same assertion as `handler-remote.test.js:31-32`). `tools` omitted → both tools.

## 3. Remote in the `HandleRequest` embedding path

**Node does:** `createHandler(config)` is the framework-agnostic entry point. It connects `config.remote` first, then merges local tools with the same override log (handler.ts:36-49).

**C# today:** The README's documented bring-your-own-HTTP entry point is `ZeroMcpServer.HandleRequest(JsonDocument)` (README.md "HTTP / Streamable HTTP" section; Server.cs:373). There is no async setup step, so nothing connects remotes for an embedder.

**Change:** `Server.cs`:

```csharp
/// Connects config "remote" servers and resolves config "icon" (gap 7).
/// Idempotent: concurrent and repeat calls await the same Task.
/// Called automatically by Serve()/ServeHttp(); embedders calling HandleRequest directly await it once.
public Task Prepare();
```

- Implemented as `_prepare ??= PrepareCore()` behind a lock. `PrepareCore` calls `ConnectRemotes(_config.Remote)` when `_config.Remote` is non-empty.
- `HandleRequest` does not call `Prepare()` implicitly. Embedders call it, as Node's caller awaits `createHandler`.
- README "HTTP / Streamable HTTP" snippet gains `await server.Prepare();` before `app.MapPost`.

**Tests:** covered by the `RemoteTests.cs` cases in gaps 1-2, which drive `Prepare()` and then `HandleRequest`. Add one case: calling `Prepare()` twice connects once (the stub counts `initialize` hits == 1).

## 4. Remote in the registry

**Node does:** `createRegistry(tools, { remote })` is async. It connects remotes, adds local tools on top with the override log, and dispatches remote tools through `mcp` while `routes` and `openapi` are built from local routed tools only (registry.ts:42-90, `RegistryOptions.remote` at registry.ts:33).

**C# today:** `Registry.Create` is synchronous, and `RegistryOptions` has only `GetContext` (Registry.cs:11-20, 29-52). `Registry.Create` shipped in `Antidrift.ZeroMcp` 0.3.0: `git tag --contains 1baf4f4` → `v0.3.0`, and NuGet's flat-container index lists `0.3.0`.

**Change:** `Registry.cs`. `Create` keeps its signature because it is published API. Add an async sibling:

```csharp
public class RegistryOptions
{
    public Func<string, Permissions?, ToolContext>? GetContext { get; set; }
    /// Remote MCP servers to federate as "<name>.<tool>"; a local tool with the same name overrides.
    public List<RemoteServer>? Remote { get; set; }
}

public static class Registry
{
    public static ToolRegistry Create(Dictionary<string, ToolDefinition> tools, RegistryOptions? options = null);
    public static Task<ToolRegistry> CreateAsync(Dictionary<string, ToolDefinition> tools, RegistryOptions? options = null);
}
```

- `CreateAsync`: build the internal `ZeroMcpServer` as `Create` does. If `options.Remote` is non-empty, `await server.ConnectRemotes(options.Remote)` (the internal method from gap 1, not `Prepare()`, so a `remote` in the cwd `zeromcp.config.json` is not picked up). Then register local tools via `server.Tool(...)`, which logs overrides. `Routes` is built from the `tools` argument only, and `OpenApi = server.BuildOpenApiSpec()`. Remote tools have no route, so they never appear in either.
- `Create`: unchanged when `options?.Remote` is null or empty. Otherwise throw `InvalidOperationException("RegistryOptions.Remote requires Registry.CreateAsync")` rather than silently ignore it.

**Tests:** in `RegistryTests.cs`, using the stub from `RemoteTests.cs` (move it to a shared `StubMcpServer` helper in the test project). These mirror `nodejs/test/registry.test.js:180-230`:
- `CreateAsync({}, { Remote = [probeo] })` → `Mcp` `tools/list` has `probeo.list_pages`; `tools/call` returns the stub text.
- A local `probeo.list_pages` overrides; stderr contains `overrides remote`.
- `Routes` is empty and `OpenApi["paths"]` is empty.
- `Create(..., { Remote = [...] })` throws `InvalidOperationException`.

## 5. Runtime context injection

**Node does:** `createHandler(config, { getRuntime })` calls `getRuntime()` on every local tool execution and sets the result as `ctx.runtime` (skipped when `undefined`), alongside `credentials` and `fetch` (handler.ts:19-23, 44; scanner.ts:9-13, 167-171). `serve()` takes no `getRuntime`.

**C# today:** `ToolContext` has `ToolName`, `Credentials`, `Permissions` and no runtime slot (Tool.cs:13-18). The server builds contexts at Server.cs:303 (HTTP route dispatch) and Server.cs:550-551 (`CallTool`, after `ContextFactory`). Neither has a hook for a caller-supplied value.

**Change:** `ToolContext.Runtime` is untyped `object?`, the same as the existing `Credentials`. A generic `ToolContext<T>` would force `ToolDefinition.Execute` to be generic, which breaks the published API.

```csharp
// Tool.cs, on ToolContext
public object? Runtime { get; set; }

// Server.cs, on ZeroMcpServer
/// Called on every local tool execution; the result is set as ctx.Runtime.
public Func<object?>? GetRuntime { get; set; }
```

- In both default `ToolContext` constructions (Server.cs:303 and 551), set `Runtime = GetRuntime?.Invoke()`.
- When `ContextFactory` is set (registry path), it builds the whole context and `GetRuntime` is not consulted. `RegistryOptions.GetContext` already lets the caller fill anything, and it is the registry's `getEnv` equivalent.
- Remote tools ignore `ctx`, so they never see `Runtime`, the same as Node.
- One C#-specific difference: Node's `serve()` cannot take `getRuntime`, but C# uses one object for both `Serve()` and `HandleRequest`, so `GetRuntime` applies on every path. It is null by default, so existing behavior is unchanged.

**Tests:** in `ServerDispatchTests.cs`:
- `GetRuntime = () => "rt"`, tool returns `ctx.Runtime` → `tools/call` text is `rt`.
- `GetRuntime` unset → `ctx.Runtime` is null.
- `GetRuntime` is invoked once per call (a counter goes up across two calls).

## 6. Multiple transports from config (dropped)
Dropped (2026-10-13): no language ships a built-in HTTP server (decisions log, 2026-10-13), so there's no HTTP transport to configure or run alongside stdio.

## 7. Missing config keys: `page_size`, `icon`

**Node does:** `page_size` (default 0, no pagination) feeds dispatch (config.ts:46, server.ts:62). `icon` is resolved by `resolveIcon` (config.ts:66-102): a `data:` URI passes through; an `http(s)` URL is fetched and becomes `data:<content-type or image/png>;base64,...`; anything else is read as a file (`~` expanded, mime from extension, default `image/png`). Failures log `[zeromcp] Warning: ...` and yield no icon. The result is applied to tools, resources and prompts (server.ts:53, 64).

**C# today:** `page_size` exists only as a constructor argument (`ZeroMcpServer(ZeroMcpConfig? config = null, int pageSize = 0)`, Server.cs:35-38), not as a config key. `icon` exists only as a raw `Icon` property applied verbatim to list entries (Server.cs:18, 504, 612, 696, 724), not as a config key and with no resolution step.

**Change:** `Config.cs`:

```csharp
[JsonPropertyName("page_size")] public int? PageSize { get; set; }
[JsonPropertyName("icon")]      public string? Icon { get; set; }

internal static Task<string?> ResolveIcon(string? icon);   // port of config.ts:66-102, same mime table and warnings
```

- Constructor: `_pageSize = pageSize != 0 ? pageSize : _config.PageSize ?? 0`, so an explicit argument still wins.
- `PrepareCore()` (gap 3): if `Icon` is null and `_config.Icon` is set, `Icon = await ResolveIcon(_config.Icon)`. An `Icon` set in code wins.

**Tests:** extend `PaginationTests.cs`: `new ZeroMcpServer(new ZeroMcpConfig { PageSize = 2 })` paginates 5 tools; an explicit `pageSize: 1` overrides config. New cases in `ServerDispatchTests.cs`:
- A `data:` icon passes through to `tools/list` `icons[0].uri` after `Prepare()`.
- A temp `.svg` file becomes `data:image/svg+xml;base64,...`.
- A missing file leaves `icons` absent.

## Already at parity

- Registry per-call env (`getEnv`): `RegistryOptions.GetContext` → `ContextFactory` (Registry.cs:19, 35; Server.cs:550)
- `title`: Config.cs:26-27, used by OpenAPI (Server.cs:890)
- `execute_timeout`: Config.cs:20-21, used by `CallTool` (Server.cs:552)
- `logging`, `bypass_permissions`, `cache_credentials`: keys present (Config.cs:14-15, 17-18, 23-24)
- N/A, hot reload (`autoload_tools`): tools are registered in code via `Tool()` (Server.cs:41, 47; README "Getting started"); no directory loading in `csharp/ZeroMcp` (grep for `Directory.`/`GetFiles`/`FileSystemWatcher` hits only Config.cs:31, the config path)
- N/A, tool sources and naming (`tools` array/`{path,prefix}`, `separator`, `namespacing`): no directory scan, same evidence as above
- N/A, `resources`/`prompts` as directory config: registered in code (Server.cs:67, 84, 103)
- N/A, `credentials` keyed by tool directory: no tool directories, same evidence as above
- N/A, "No tools directory and no remote servers configured" exit: no scan step that can fail

## Verify
All build and test runs happen in the local all-language Docker image (repo-root `Dockerfile`, per `engineering/testing.md`), not on host toolchains. The image copies the source in at build time, so rebuild it after every change.

```sh
docker build -t zeromcp-tests .
docker run --rm zeromcp-tests sh -c 'cd csharp && dotnet test ZeroMcp.Tests/ZeroMcp.Tests.csproj'
docker run --rm zeromcp-tests node tests/conformance/run-all.js --language "C#"
```

Baseline: 3 `TemplateTests` failures already exist on `main` and are not part of this work.
