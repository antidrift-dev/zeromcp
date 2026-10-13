# Node parity — Kotlin

## Status

Not started. Spec only.

## Gaps

1. Remote federation (`remote` config) in the built-in server
2. Remote allowlist (`remote[].tools`)
3. Remote on the `handleRequest` path (Kotlin's `createHandler` equivalent)
4. Remote in `ZeroMcp.registry()`
5. Runtime context injection (`ctx.runtime`)
6. ~~Multiple transports, and `auth` on the http transport~~ (dropped: no built-in HTTP server)
7. `icon` and `page_size` config keys

## 1. Remote federation (`remote` config) in the built-in server

**Node does:** `RemoteManager.connect` (`nodejs/src/remote.ts:20-38`) runs, for each `RemoteServer { name, url, auth?, tools? }` (`config.ts:5-11`): it rejects non-http(s) URLs (`remote.ts:41-43`), then POSTs `initialize` (id 1) and `tools/list` (id 2) with `Content-Type: application/json` and `Authorization: Bearer <resolveAuth(auth)>`. A non-2xx response throws `HTTP <status>` (`remote.ts:49-59,87-99`). Each upstream schema becomes local input through `schemaToInput` (`remote.ts:101-121`), and each tool's `execute` POSTs `tools/call` and returns `result.content[0].text` when it is truthy, else `result` (`remote.ts:69-79`). Tools are registered as `<server.name>.<toolName>`. A failed server logs `[mcp] Failed to connect to <name>: <msg>` and the rest continue (`remote.ts:32-34`). `serve()` adds remote tools first, then local tools override them with the log `[zeromcp] Local tool "<name>" overrides remote` (`server.ts:23-36`). Remote tools have no `route`.

**Kotlin today:** No remote support. `ZeroMcpConfig` (`kotlin/src/main/kotlin/io/antidrift/zeromcp/Config.kt:7-19`) has no `remote` field. `grep -rn "remote\|Remote" kotlin/src/main` returns no matches. `resolveAuth` already exists with Node's semantics (`Config.kt:42-53`). Tools are registered only in code, through `tool()`/`register()` (`Server.kt:47-63`).

**Change:**
- `Config.kt`: add the config type and field.
  ```kotlin
  @Serializable
  data class RemoteServer(
      val name: String,
      val url: String,
      val auth: String? = null,
      val tools: List<String>? = null   // gap 2
  )

  data class ZeroMcpConfig(
      // ...existing fields...
      val remote: List<RemoteServer> = emptyList()
  )
  ```
- New `kotlin/src/main/kotlin/io/antidrift/zeromcp/Remote.kt`:
  ```kotlin
  internal class RemoteManager {
      /** Connects each server in order; returns namespaced tools in insertion order. */
      suspend fun connect(servers: List<RemoteServer>): LinkedHashMap<String, ToolDefinition>
  }
  ```
  - HTTP uses `java.net.http.HttpClient` (JDK, no new Gradle dependency), with a blocking `send` inside `withContext(Dispatchers.IO)`.
  - `connectOne`: if `url` starts with neither `http://` nor `https://`, throw `Remote server "<name>" must have an HTTP/HTTPS URL, got: <url>`.
  - `httpRpc(url, body, auth)`: POST the JSON body with `Content-Type: application/json`, plus `Authorization: Bearer <auth>` when `resolveAuth(server.auth)` is non-null. If the status is not 2xx, throw `HTTP <status>`. Parse the response as `JsonObject`.
  - Send `initialize` `{jsonrpc:"2.0", id:1, method:"initialize", params:{}}` and ignore its result. Then send `tools/list` with id 2. The tool list is `result.tools`, or empty when that is missing.
  - `schemaToInput(inputSchema)`: for each property, `type = SimpleType.fromString(p.type ?: "string")`, keep `description`, and set `optional = key !in required`. Build it inside the per-server `try`. `SimpleType.fromString` throws on unknown types (`Types.kt:24-26`), as Node's `toJsonSchema` does (`nodejs/src/schema.ts:42-43`), so an unknown type fails that whole server.
  - Each remote tool is `ToolDefinition(name = "<server>.<tool>", description, input, permissions = Permissions(), route = null, execute = …)`. Its `execute` POSTs `{jsonrpc:"2.0", id: System.currentTimeMillis(), method:"tools/call", params:{name:<upstream name>, arguments: toJsonElement(args)}}`. It returns `result.content[0].text` as a `String` if that is present and non-empty. Otherwise it returns `jsonElementToAny(result)`, so that `callTool`'s `toJsonElement` re-encodes it correctly.
  - Logs: `[mcp] Remote tool: <ns>` per tool, `[mcp] Connected to <name> (HTTP): <n> tool(s)` per server, and `[mcp] Failed to connect to <name>: <message>` on any exception. A failed server is skipped.
- `Server.kt`: change `toJsonElement` (`Server.kt:778`) and `jsonElementToAny` (`Server.kt:761`) from `private` to `internal` so that `Remote.kt` can use them.
- `Server.kt`, `ZeroMcp`: add a public, idempotent, Mutex-guarded merge.
  ```kotlin
  /** Connects config.remote and merges its tools. No-op after the first call or when remote is empty. */
  suspend fun connectRemotes()
  ```
  - Rebuild `tools`/`schemas` as remote tools first, then the existing local tools. When a local name collides, log `[zeromcp] Local tool "<name>" overrides remote` and let the local tool win. `LinkedHashMap` keeps the slot of the remote entry, which matches Node's `Map.set` order.
  - Track `private val remoteNames = mutableSetOf<String>()` holding the names whose current entry is remote. If `tool()`/`register()` (`Server.kt:47-63`) is later called with one of those names, log the same override line and drop the name from `remoteNames`.
  - `serve()` (`Server.kt:116`) and `serveHttp()` (`Server.kt:144`) call `runBlocking { connectRemotes() }` before they log the counts and start the transport.
- Remote tools have `route = null`, so `handleToolRoute` (`Server.kt:222`) and `buildOpenApiSpecJson` (`Server.kt:612`) already skip them.
- Node's "No tools directory and no remote servers configured" exit (`server.ts:37-41`) does not apply. Kotlin has no tool directory to fail on.

**Tests:** New `kotlin/src/test/kotlin/io/antidrift/zeromcp/RemoteTest.kt`. It runs a fake upstream on `com.sun.net.httpserver.HttpServer` (the same JDK server `serveHttp` uses) that answers `initialize`/`tools/list`/`tools/call` like `nodejs/test/handler-remote.test.js:5-17`. Cases:
- `tools/list` shows `probeo.list_pages`.
- `tools/call` returns the upstream `content[0].text`.
- A local tool named `probeo.list_pages` wins, and stderr contains `overrides remote`.
- A `ftp://` URL and a non-2xx upstream are both skipped while a second, good server still connects.
- The upstream receives `Authorization: Bearer <token>` when `auth` is set, including the `env:VAR` form.

## 2. Remote allowlist (`remote[].tools`)

**Node does:** keeps only the upstream tools whose name is in `server.tools`. When `tools` is omitted, all tools are kept (`nodejs/src/remote.ts:61`, `config.ts:9-10`).

**Kotlin today:** There is no `RemoteServer` type (see gap 1).

**Change:** In `RemoteManager.connectHttp`, filter `result.tools` with `server.tools == null || name in server.tools` before mapping to `ToolDefinition`. The filter matches upstream (un-namespaced) names.

**Tests:** In `RemoteTest.kt`, with `tools = listOf("list_pages")` against an upstream that serves `list_pages` and `get_page`, `tools/list` returns only `probeo.list_pages`. This mirrors `nodejs/test/handler-remote.test.js:30-33`.

## 3. Remote on the `handleRequest` path (Kotlin's `createHandler` equivalent)

**Node does:** `createHandler(config, options)` connects remotes and merges them the same way as `serve()` before it returns the handler (`nodejs/src/handler.ts:36-49`).

**Kotlin today:** The framework-agnostic entry point is the public `suspend fun ZeroMcp.handleRequest(request: JsonObject): JsonObject?` (`Server.kt:270`). The README presents it as the way to use your own HTTP framework (`kotlin/README.md:39-66`). It has no remote support (gap 1).

**Change:**
- No new entry point. Callers who use `handleRequest` directly call `server.connectRemotes()` once before serving, as the Kotlin counterpart of `await createHandler(...)`.
- `kotlin/README.md` "HTTP / Streamable HTTP" section: add `server.connectRemotes()` before `embeddedServer(...)`, plus a one-line note that this is needed only when `remote` is configured.

**Tests:** In `RemoteTest.kt`, construct `ZeroMcp(ZeroMcpConfig(remote = …))`, call `connectRemotes()`, then call `handleRequest` for `tools/list` and `tools/call`. This mirrors `nodejs/test/handler-remote.test.js:19-37`. Also call `connectRemotes()` twice and assert that the upstream saw `tools/list` once.

## 4. Remote in `ZeroMcp.registry()`

**Node does:** `createRegistry(tools, { remote })` is `async`. It connects remotes, adds them to the MCP tool map first, and lets local tools override them with the same log (`nodejs/src/registry.ts:42-65`). Remote tools appear in `mcp` `tools/list`/`tools/call` but never in `routes`/`openapi`. `routes` is built from the local `tools` only (`registry.ts:67-74`).

**Kotlin today:** `fun registry(): Registry` is non-suspend. It reads `tools`/`schemas` and wraps `handleRequest` (`Server.kt:69-81`). There is no remote support.

**Change:**
- Make it `suspend fun registry(): Registry`, calling `connectRemotes()` first. There is no new parameter: remotes come from `config.remote`, as `title` already does (`Server.kt:78`).
- `routes` and `openapi` stay as they are. Remote tools have `route = null`, so the `filter { it.route != null }` (`Server.kt:71`) and `buildOpenApiSpecJson` (`Server.kt:612`) exclude them.
- Update the existing non-coroutine call sites in `RegistryTest.kt` (`:30`, `:48`, `:55`, `:117`) to run inside `runBlocking`.

**Tests:** In `RegistryTest.kt`, using the fake upstream from `RemoteTest.kt` (move it into a shared test helper):
- `mcp` lists and calls `probeo.list_pages`.
- A local `probeo.list_pages` overrides it and logs `overrides remote`.
- With only remote tools, `routes` is empty and `openapi["paths"]` is `{}`.

These mirror `nodejs/test/registry.test.js:180-226`.

## 5. Runtime context injection (`ctx.runtime`)

**Node does:** `createHandler(config, { getRuntime })` passes the provider to `ToolScanner` (`nodejs/src/handler.ts:19-21,44`). On every local tool execution it calls `getRuntime()`, and if the result is not `undefined` it sets `ctx.runtime` next to `credentials` and `fetch` (`scanner.ts:9-13,167-172`). Remote tools never call it (`remote.ts:69`). `serve()` takes no `getRuntime`. The registry does the same through `getEnv`, passed as the second `execute` argument (`registry.ts:46,63`).

**Kotlin today:** `data class Ctx(val toolName: String, val permissions: Permissions = Permissions())` (`Types.kt:68-71`) has no runtime slot. `Ctx` is built in exactly two places: `callTool` (`Server.kt:455`) and `handleToolRoute` (`Server.kt:247`). The registry has no `getEnv` equivalent. `specs/lang/kotlin/registry.md` (Behavior, second bullet) leaves this as an open question to be "threaded through `Ctx` for `ZeroMcp` as a whole". This change does that, so it also covers Node's registry `getEnv` for `registry().mcp`.

**Change:**
- `Types.kt`: add the runtime field to `Ctx`.
  ```kotlin
  data class Ctx(
      val toolName: String,
      val permissions: Permissions = Permissions(),
      val runtime: Any? = null
  )
  ```
  `Any?` fits the existing non-generic `Ctx`/`ToolDefinition`/`ToolBuilder.execute` shape. Making it generic would change every `execute` lambda's type. Tools cast it: `ctx.runtime as MyRuntime`. The default `null` keeps the existing `Ctx("adder")` and `Ctx(toolName=…, permissions=…)` call sites compiling (`ServerTest.kt:75`, `RegistryTest.kt:65`).
- `Server.kt`, `ZeroMcp`: add a provider property, next to `icon`/`pageSize` (`Server.kt:39,42`).
  ```kotlin
  /** Called on every local tool execution; the result is passed as ctx.runtime. */
  var runtimeProvider: (() -> Any?)? = null
  ```
- In `callTool` (`Server.kt:455`) and `handleToolRoute` (`Server.kt:247`), build `Ctx(toolName, permissions, runtime = runtimeProvider?.invoke())`. Skip the call for names in `remoteNames` (gap 1), so that the provider is invoked only for local tools, as in Node.

**Tests:** In `ServerTest.kt`:
- With `runtimeProvider = { "rt-1" }`, a tool returning `ctx.runtime` yields `rt-1` through `tools/call`.
- A counter in the provider increments once per call.
- With no provider set, `ctx.runtime == null`.

In `RegistryTest.kt`, `registry().mcp` `tools/call` sees the runtime. This mirrors `nodejs/test/registry.test.js:130-141`.

## 6. Multiple transports, and `auth` on the http transport (dropped)
Dropped (2026-10-13): no language ships a built-in HTTP server (decisions log, 2026-10-13), so there's no HTTP transport to configure or run alongside stdio.

## 7. `icon` and `page_size` config keys

**Node does:** `icon` (`nodejs/src/config.ts:49`) is resolved by `resolveIcon` (`config.ts:66-102`):
- a `data:` value passes through
- an `http(s)` URL is fetched and becomes `data:<content-type or image/png>;base64,…`
- anything else is read as a file path (`~` expanded) and becomes `data:<mime by extension, default image/png>;base64,…`
- a failure logs a `[zeromcp] Warning: …` and gives no icon

`page_size` (`config.ts:46`) defaults to 0. Both feed the dispatch state (`server.ts:53-64`).

**Kotlin today:** Neither key is in `ZeroMcpConfig` (`Config.kt:7-19`). `loadConfig` uses `ignoreUnknownKeys = true` (`Config.kt:21`), so both keys are silently dropped from `zeromcp.config.json`. The behavior exists only as code-set properties: `var icon: String? = null` and `var pageSize: Int = 0` (`Server.kt:39,42`). Both are already used in list responses and `paginate` (`Server.kt:319,322,723`).

**Change:**
- `Config.kt`:
  - Add `val icon: String? = null` and `val page_size: Int = 0` to `ZeroMcpConfig`.
  - Add `fun resolveIcon(icon: String?): String?` with Node's three branches, the same MIME table (`.png .jpg .jpeg .gif .svg .ico .webp`) and the same warning text. Use `java.net.http.HttpClient` for URLs and `java.util.Base64` for encoding.
- `Server.kt`:
  - `var icon: String? = resolveIcon(config.icon)`
  - `var pageSize: Int = config.page_size`

  These are initializers only, so code can still override them by assignment.

**Tests:**
- `ConfigTest.kt`: `resolveIcon` passes `data:` through, turns a temp `.svg` file into `data:image/svg+xml;base64,…`, and returns `null` for a missing file.
- `ServerTest.kt`:
  - `ZeroMcp(ZeroMcpConfig(page_size = 1))` with two tools returns one tool and a `nextCursor` from `tools/list`.
  - `ZeroMcp(ZeroMcpConfig(icon = "data:image/png;base64,AA=="))` puts that URI in `icons`.

## Already at parity

These items are already at parity or do not apply to Kotlin:
- Hot reload (`autoload_tools`) does not apply. Tools are registered in code through `tool()`/`register()` (`Server.kt:47-63`), and nothing scans or watches a directory (`grep -rn "watch" kotlin/src/main` returns no matches).
- Tool sources, `separator` naming and `namespacing` do not apply because there is no directory scanning. `separator` is declared but unused (`Config.kt:13`).
- `resources`/`prompts` config dirs do not apply. They are registered in code through `resource()`/`resourceTemplate()`/`prompt()` (`Server.kt:86-111`).
- `credentials` config does not apply. Node keys credentials by the tool's first source subdirectory (`nodejs/src/scanner.ts:115-120`), and Kotlin has no tool directories.
- `title` is at parity: `Config.kt:16`, used for OpenAPI at `Server.kt:78,173`.
- `execute_timeout` is at parity: `Config.kt:17`, used in `callTool` at `Server.kt:451-452` with a per-tool override.
- `logging`, `bypass_permissions` and `cache_credentials` are present as config keys (`Config.kt:11,12,18`).

## Verify
All build and test runs happen in the local all-language Docker image (repo-root `Dockerfile`, per `engineering/testing.md`), not on host toolchains. The image copies the source in at build time, so rebuild it after every change.

```sh
docker build -t zeromcp-tests .
docker run --rm zeromcp-tests sh -c 'cd kotlin && gradle test'
docker run --rm zeromcp-tests node tests/conformance/run-all.js --language "Kotlin"
```
