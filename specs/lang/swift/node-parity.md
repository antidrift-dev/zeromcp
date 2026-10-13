# Node parity — Swift

## Status
Done (2026-10-13). Docker (Linux): `swift test` 109/109 (new RemoteTests 20, RegistryTests +4, ServerTests +14); conformance Swift 8/8 stdio suites + route 5/5.

## Gaps
1. Remote federation (`remote` config) in the built-in server
2. Remote allowlist (`remote[].tools`)
3. Remote in the `handleRequest` entry point (Swift's `createHandler` equivalent)
4. Remote in `createRegistry`
5. Runtime context injection (`getRuntime` → `ctx.runtime`)
6. ~~Config-driven transports, including stdio + HTTP together~~ (dropped: no built-in HTTP server)
7. Missing config keys: `page_size`, `icon`

All async config work (remotes, icon) goes through one new public method, `prepare()`, described in §1 and reused by §3, §4 and §7.

## 1. Remote federation in the built-in server
**Node does:** `serve()` connects every `config.remote` server before local tools load, and merges them in as `<server>.<tool>`. A local tool with the same name wins and logs `[zeromcp] Local tool "<name>" overrides remote` (server.ts:23-36). For each server, `RemoteManager` (remote.ts:20-121) does the following:
- Rejects a non-http(s) URL.
- POSTs `initialize` (id 1, params `{}`) and then `tools/list` (id 2), with `Content-Type: application/json`. When `auth` is set it adds `Authorization: Bearer <resolveAuth(auth)>`, where `resolveAuth` maps `env:VAR` to that env var and returns anything else as the literal value (config.ts:153-166).
- Treats a non-2xx response as an error (`HTTP <status>`).
- Converts each remote `inputSchema` back to input with `schemaToInput`.
- Gives each remote tool an `execute` that POSTs `tools/call` and returns `result.content[0].text` if present, else `result`.
- Skips a server that fails, logging `[mcp] Failed to connect to <name>: <msg>`, and carries on with the others.
- Gives remote tools no `route`.

**Swift today:** `ZeroMcpConfig` has no `remote` key (Config.swift:3-20). No HTTP client exists in the module (`grep -rn "URLSession\|FoundationNetworking" Sources` returns nothing). `serve()` goes straight to the stdin loop (Server.swift:77-98). `serveHttp(port:)` is a synchronous accept loop (HttpServer.swift:13-52).

**Change:**
- New `Sources/ZeroMcp/Remote.swift`:
  ```swift
  public struct RemoteServer: Codable {
      public var name: String
      public var url: String
      public var auth: String?
      public var tools: [String]?   // §2
      public init(name: String, url: String, auth: String? = nil, tools: [String]? = nil)
  }

  /// `env:VAR` → ProcessInfo env value (logs `[zeromcp] Warning: environment variable VAR not set` if missing); else literal; nil → nil.
  func resolveAuth(_ auth: String?) -> String?

  final class RemoteManager {
      /// Returns namespaced `"<server.name>.<toolName>"` → ToolDefinition. Never throws; per-server failures are logged and skipped.
      func connect(_ servers: [RemoteServer]) async -> [String: ToolDefinition]
  }
  ```
- `Config.swift`: add `public var remote: [RemoteServer]?` (CodingKey `remote`) and an `init` parameter `remote: [RemoteServer]? = nil`.
- `RemoteManager` behavior, ported line for line from remote.ts:
  - URL must start with `http://` or `https://`. Otherwise fail that server with `Remote server "<name>" must have an HTTP/HTTPS URL, got: <url>`.
  - Requests use `URLSession.shared.data(for:)`, POST, with the JSON body from `JSONSerialization`. Set the `Content-Type` header, and the `Authorization: Bearer …` header when resolved auth is non-nil. A non-2xx status throws `HTTP <status>`. Add `#if canImport(FoundationNetworking) import FoundationNetworking #endif` for Linux. Whether async `URLSession.data(for:)` is available on swift-corelibs-foundation is unverified.
  - Send `initialize` `{jsonrpc:"2.0", id:1, method:"initialize", params:{}}`, then `tools/list` with id 2. Read `result.tools`, defaulting to `[]`.
  - `schemaToInput`: for each `properties` key, take `type`, defaulting to `"string"`, and map it through `SimpleType(rawValue:) ?? .string`. The enum can't hold other JSON Schema types (Schema.swift:3-9). Not in `required`, or has a `description` → `.extended(type:, description:, optional: !isRequired)`. Otherwise → `.simple(type)`.
  - Build each tool with `ToolDefinition(description:input:execute:)`, with no `route` and default `Permissions()`. `execute` ignores `ctx`. It POSTs `{jsonrpc:"2.0", id:<ms since epoch>, method:"tools/call", params:{name, arguments: args}}` and returns `result.content[0].text` when that is a non-empty `String`, else `result`.
  - Logs go to stderr: `[mcp] Remote tool: <ns>` per tool, `[mcp] Connected to <name> (HTTP): <n> tool(s)` per server, and `[mcp] Failed to connect to <name>: <message>` on failure.
- `Server.swift`, on `ZeroMcp`:
  ```swift
  /// Resolves async, config-driven state: connects `config.remote` (and resolves `config.icon`, §7).
  /// Idempotent. Called automatically by serve(), serveHttp(port:auth:) and createRegistry.
  public func prepare() async
  ```
  - Merge: for each remote tool, if `tools[name]` already exists, log `[zeromcp] Local tool "<name>" overrides remote` and keep the local one. Otherwise insert it and record the name in an internal `remoteToolNames: Set<String>`, which §5 uses. Local tools registered after `prepare()` replace remote ones silently, so local still wins.
  - `serve()` calls `await prepare()` before reading stdin.
  - `serveHttp(port:)` becomes `async` and calls `await prepare()` before binding. Existing callers already `await` it (RouteTest/main.swift:25, README.md:49).
- Remote tools have `route == nil`, so they are skipped by the HTTP route loop (HttpServer.swift:170) and by OpenAPI (HttpServer.swift:229).

**Tests:** new `Tests/ZeroMcpTests/RemoteTests.swift`. The upstream is a second `ZeroMcp` with `.tool()` registrations, run with `serveHttp(port:)` on a `Thread` on a fixed test port, following RouteTest's fixed-port pattern. It is unverified whether that runs cleanly inside XCTest. Cases:
- `tools/list` shows `up.<name>` for each upstream tool.
- `tools/call` returns the upstream text.
- A local tool `up.x` overrides the remote one and the override line is logged.
- A `ws://` URL and an unreachable port are each skipped while a good server still connects.
- `schemaToInput`: simple vs extended, kept description, missing type → `.string`.
- `resolveAuth`: `env:` set, `env:` unset, literal, nil.
- The Bearer header is sent: the upstream uses `serveHttp(port:auth:)` from §6, and a call with no auth gets zero tools.

## 2. Remote allowlist
**Node does:** `remote[].tools?: string[]` keeps only upstream tools whose name is in the list. If the key is omitted, everything is kept (config.ts:9, remote.ts:61).

**Swift today:** No remote support (see §1).

**Change:** `RemoteServer.tools: [String]?` (§1). In `RemoteManager`, filter the `tools/list` result before building definitions: keep a tool when `server.tools == nil || server.tools!.contains(name)`. Matching is on the upstream (un-namespaced) name.

**Tests:** in `RemoteTests.swift`, with `tools: ["list_pages"]`, only `up.list_pages` is listed. With `tools` omitted, all upstream tools are listed.

## 3. Remote in the `handleRequest` entry point
**Node does:** `createHandler(config)` connects remotes and merges them, with local overriding remote, before returning the JSON-RPC handler (handler.ts:36-49).

**Swift today:** The framework-agnostic entry point is `ZeroMcp.handleRequest(_:)` (Server.swift:109), documented under "Bring your own framework" (README.md:59-78). It only ever sees `tools` registered through `.tool()` (Server.swift:30-60).

**Change:** No new entry point. A caller who uses `handleRequest` without `serve()` or `serveHttp` calls `await server.prepare()` (§1) once, after registering tools and before handling requests. `handleRequest` itself does not connect lazily. Update the README "Bring your own framework" snippet to show the `prepare()` call.

**Tests:** in `RemoteTests.swift`:
- `ZeroMcp(config: ZeroMcpConfig(remote: [...]))` + `prepare()` + `handleRequest` `tools/list` and `tools/call` give the namespaced, allowlisted results. This mirrors nodejs/test/handler-remote.test.js.
- Calling `prepare()` twice does not duplicate tools or reconnect.

## 4. Remote in the registry
**Node does:** `createRegistry(tools, { remote })` is `async`. It connects remotes and merges them with local overriding remote, logging the override. Remote tools appear in `mcp` `tools/list` and `tools/call` but never in `routes` or `openapi` (registry.ts:42-90).

**Swift today:** `createRegistry(_:options:)` is synchronous. `RegistryOptions` carries only `config` (Registry.swift:18-31, 45-65). `routes` comes from the `tools` argument alone (Registry.swift:52-58).

**Change (`Registry.swift`):**
```swift
public func createRegistry(
    _ tools: [String: ToolDefinition],
    options: RegistryOptions = RegistryOptions()
) async -> Registry
```
- Remotes come from `options.config.remote`. There is no separate `remote` field, since `RegistryOptions` already folds Node's title/timeout options into `config`.
- After `instance.tools = tools`, call the internal remote-connect step of `prepare()` (remotes only, no icon), then build `openapi` and `mcp` as today.
- `routes` stays derived from the `tools` argument, so remote tools never appear in it. `openapi` already skips route-less tools (HttpServer.swift:229).
- This breaks source compatibility: existing call sites need `await`.

**Tests:** in `RegistryTests.swift`:
- Add `await` to the 8 existing `createRegistry` calls (lines 22, 33, 42, 48, 56, 66, 76, 82) and make those test methods `async`.
- New cases: remote tools are merged into `mcp` `tools/list` and `tools/call`; a local tool overrides a remote one of the same name; remote tools are absent from `routes` and `openapi["paths"]`. Use the upstream helper from §1.

## 5. Runtime context injection
**Node does:**
- `createHandler(config, { getRuntime })` calls `getRuntime()` on every local tool execution. When the result isn't `undefined`, it sets it as `ctx.runtime` alongside `credentials` and `fetch` (handler.ts:19-23, 44; scanner.ts:9-13, 167-171). Remote tools don't receive it, because their `execute` ignores ctx.
- `serve()` does not take `getRuntime`.
- The registry has an equivalent: `getEnv` is passed as the second argument to each tool's `execute` (registry.ts:26, 46, 63).

**Swift today:**
- `ToolContext` is `{ toolName, credentials: Any?, permissions }` with no runtime field (Tool.swift:34-44).
- Contexts are built as `ToolContext(toolName:permissions:)` in `callTool` (Server.swift:432) and in the HTTP route path (HttpServer.swift:186).
- `RegistryOptions` has no env or runtime hook (Registry.swift:18-31).

**Change:**
- `Tool.swift`: add `public let runtime: Any?` to `ToolContext`, and an init parameter `runtime: Any? = nil`, which is source-compatible with every existing call site. `Any?` matches the existing `credentials: Any?`. A generic would spread through `ZeroMcp`, `ToolDefinition` and `Registry`.
- `Server.swift`: add `public var getRuntime: (() -> Any?)?` on `ZeroMcp`, set after init like the existing `icon` and `pageSize` (Server.swift:20, 23).
- In `callTool` (Server.swift:432) and the HTTP route loop (HttpServer.swift:186), when `name` is not in `remoteToolNames`, build the context as `ToolContext(toolName:permissions:runtime: getRuntime?())`. Call it once per execution. For remote tools, don't call it.
- In Swift, the server and the handler are the same object, so a `getRuntime` set on an instance also applies to `serve()` and `serveHttp`. Node has no equivalent knob on `serve()`.
- Registry (the `getEnv` equivalent): add `public var getRuntime: (() -> Any?)?` to `RegistryOptions`, with an `init` parameter defaulting to nil. `createRegistry` assigns it to the internal instance, so `mcp` `tools/call` delivers it as `ctx.runtime`. Direct `routes[i].tool.execute` calls are the caller's own, as today.

**Tests:**
- `ServerTests.swift`:
  - With `getRuntime` set, `tools/call` sees `ctx.runtime`.
  - With it unset, `ctx.runtime == nil`.
  - `getRuntime` is called once per call.
- `RegistryTests.swift`: `RegistryOptions(getRuntime:)` reaches `ctx.runtime` through `mcp` `tools/call`, mirroring Node's "tools/call invokes execute with the env from getEnv".

## 6. Config-driven transports (stdio + HTTP together) (dropped)
Dropped (2026-10-13): no language ships a built-in HTTP server (decisions log, 2026-10-13), so there's no HTTP transport to configure or run alongside stdio.

## 7. Missing config keys: `page_size`, `icon`
**Node does:**
- `page_size` (default 0) feeds pagination (config.ts:46; handler.ts:65; server.ts:62).
- `icon` is resolved by `resolveIcon` (config.ts:66-102):
  - A `data:` URI passes through.
  - An `http(s)` URL is fetched and becomes `data:<content-type>;base64,…`.
  - Anything else is a file path (`~` → HOME), read and given a MIME type by extension: png, jpg/jpeg, gif, svg, ico, webp, defaulting to `image/png`.
  - On failure it logs `[zeromcp] Warning: …` and leaves the icon unset.

**Swift today:**
- `ZeroMcpConfig` has neither key (Config.swift:3-20).
- `pageSize` and `icon` exist only as public instance vars set in code (Server.swift:20, 23), and `icon` is used verbatim.

**Change:**
- `Config.swift`: add `pageSize: Int?` (CodingKey `page_size`) and `icon: String?` (CodingKey `icon`), plus init parameters.
- `Server.swift` `init(config:)`: `pageSize = config.pageSize ?? 0`.
- New internal `func resolveIcon(_ icon: String?) async -> String?` in `Config.swift`, porting config.ts:66-102. URL fetch uses `URLSession` (§1) and takes the `Content-Type` response header, defaulting to `image/png`. The log text matches Node's.
- `prepare()` (§1): if `self.icon == nil`, set `self.icon = await resolveIcon(config.icon)`. An icon set in code wins.

**Tests:** in `ServerTests.swift`:
- `page_size` decodes and paginates `tools/list`.
- `icon` cases: a data URI passes through; a temp `.svg` file becomes `data:image/svg+xml;base64,…`; a missing file leaves `icon` nil; an icon set in code is not overwritten by `prepare()`.

## Already at parity / N/A
- `title`, `execute_timeout`, `logging`, `bypass_permissions`, `cache_credentials` config keys: present (Config.swift:4-19).
- Hot reload (`autoload_tools`): N/A, because tools are registered in code via `.tool()` (Server.swift:30-60). There is no directory loader.
- Tool sources / `separator` / `namespacing`: N/A, no directory scanner. `ZeroMcpConfig.tools`/`separator` are decoded (Config.swift:4-5) but no scanner reads them (`grep` over Sources/ZeroMcp).
- `resources` / `prompts` directory config: N/A, registered in code (Server.swift:63-75).
- `credentials` config (per tool directory, scanner.ts:115-133): N/A, since it is keyed by tool subdirectory and Swift has none.
- "No tools directory and no remote servers configured" exit: N/A, no scan step to fail.
- Remote tools excluded from REST routes and OpenAPI: falls out of `route == nil` (HttpServer.swift:170, 229; Registry.swift:52-53).

## Verify
All build and test runs happen in the local all-language Docker image (repo-root `Dockerfile`, per `engineering/testing.md`), not on host toolchains. The image copies the source in at build time, so rebuild it after every change.

```sh
docker build -t zeromcp-tests .
docker run --rm zeromcp-tests sh -c 'cd swift && swift build && swift test'
docker run --rm zeromcp-tests node tests/conformance/run-all.js --language "Swift"
```
