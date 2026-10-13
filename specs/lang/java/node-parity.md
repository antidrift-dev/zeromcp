# Node parity — Java

## Status
Not started. Spec only.

## Gaps
1. Remote federation (`remote` config, incl. per-server `tools` allowlist) in `serve()` / `serveHttp()` / `handleRequest()`
2. Remote federation in `registry()`
3. Runtime context injection (`ctx.runtime()`)
4. ~~Multiple transports from config (`transport` as object or array)~~ (dropped: no built-in HTTP server)
5. `page_size` and `icon` config keys

## 1. Remote federation
**Node does:** `config.remote: RemoteServer[]` (`{name, url, auth?, tools?}`, `nodejs/src/config.ts:5-11,44`). `RemoteManager.connect` (`nodejs/src/remote.ts:21-39`) rejects non-http(s) URLs (`:41-46`), POSTs `initialize` (id 1) then `tools/list` (id 2) with `Content-Type: application/json` and `Authorization: Bearer <resolveAuth(auth)>` (`:48-60,87-99`), throws `HTTP <status>` on non-2xx (`:97`), keeps only tools named in `server.tools` when set (`:62`), rebuilds each input schema via `schemaToInput` (`:101-121`), and registers `<server.name>.<toolName>`. A failed server logs `[mcp] Failed to connect to <name>: <msg>` and is skipped. `serve()` and `createHandler()` add remote tools first, then local tools override with `[zeromcp] Local tool "<name>" overrides remote` (`nodejs/src/server.ts:20-36`, `nodejs/src/handler.ts:36-49`).

**Java today:** no `remote` field on `Config` (`java/src/main/java/io/antidrift/zeromcp/Config.java:15-31`); no HTTP client in `src/main` (`grep -rn HttpClient java/src/main` → no hits). `Config.resolveAuth` already exists with Node's `env:` semantics (`Config.java:74-85`). Tools live in one `LinkedHashMap<String, NamedTool>` (`ZeroMcp.java:43`) filled by `tool()` (`ZeroMcp.java:84-88`). Java's equivalent of `createHandler` is the public `handleRequest(JsonObject)` (`ZeroMcp.java:445`, documented as the bring-your-own-framework path in `java/README.md`, "HTTP / Streamable HTTP").

**Change:**
- Add `java/src/main/java/io/antidrift/zeromcp/RemoteServer.java`:
  ```java
  public record RemoteServer(String name, String url, String auth, List<String> tools) {
      public RemoteServer(String name, String url) { this(name, url, null, null); }
  }
  ```
- `Config.java`: add `private List<RemoteServer> remote;` and `public List<RemoteServer> remote()` (returns `List.of()` when null). Gson 2.11 deserializes records (checked: a scratch `javac`/`java` run of `Gson.fromJson("{\"remote\":[{...}]}")` into a `List<record>` worked).
- `ZeroMcp.java`: builder setter, same style as `pageSize`/`icon` (`ZeroMcp.java:66-77`):
  ```java
  public ZeroMcp remote(RemoteServer... servers)   // appends to the list seeded from config.remote()
  ```
- Add package-private `java/src/main/java/io/antidrift/zeromcp/RemoteManager.java`:
  ```java
  final class RemoteManager {
      Map<String, Tool> connect(List<RemoteServer> servers);   // LinkedHashMap, keys "<server>.<tool>"
  }
  ```
  Uses `java.net.http.HttpClient` (JDK, no new dependency), synchronous `send`.
- Behavior, ported as-is from `remote.ts`:
  - URL must start with `http://` or `https://`, else throw `Remote server "<name>" must have an HTTP/HTTPS URL, got: <url>`.
  - `auth` resolved with `Config.resolveAuth`; when non-null, send `Authorization: Bearer <auth>`. Always send `Content-Type: application/json`.
  - POST `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`, then `{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}`. Status outside 200-299 → throw `HTTP <status>`.
  - `result.tools` missing → empty. If `server.tools()` is non-null, drop tools whose name is not in it.
  - `schemaToInput`: for each `inputSchema.properties` entry → `Input(name, SimpleType.fromString(type ?: "string"), description, !required.contains(name))`. An unknown type throws (same as Node's `toJsonSchema`), which fails that server.
  - Each remote `Tool`: `description` from upstream, `Permissions.of()`, `route` null, executor POSTs `{"jsonrpc":"2.0","id":System.currentTimeMillis(),"method":"tools/call","params":{"name":<upstream name>,"arguments":<args>}}`; returns `result.content[0].text` as a `String` when present and non-empty, else the `result` `JsonElement` (null if absent).
  - Logs: `[mcp] Remote tool: <ns>` per tool, `[mcp] Connected to <name> (HTTP): <n> tool(s)` per server, `[mcp] Failed to connect to <name>: <msg>` on any exception (server skipped, others continue).
- Merge, in a private `synchronized void connectRemotesOnce()` on `ZeroMcp` (runs at most once): build a new `LinkedHashMap` with remote tools first, then each local entry, logging `[zeromcp] Local tool "<name>" overrides remote` when the key already exists; replace the contents of `tools`. Local overrides keep the remote entry's position (`LinkedHashMap.put` on an existing key, same as JS `Map.set`).
- Call `connectRemotesOnce()` at the start of `serve()` (`ZeroMcp.java:414`) and `serveHttp(int)` (`ZeroMcp.java:133`) before the tool count log / route mounting, and at the top of `handleRequest` (`ZeroMcp.java:445`) so direct `handleRequest` callers get remotes without a new public method.
- Remote tools have `route == null`, so they are skipped by the route-mounting loop (`ZeroMcp.java:190-194`) and `buildOpenApiSpec()` (`ZeroMcp.java:321-322`) with no further change.
- The Node "no tools directory and no remote servers → exit" path (`server.ts:37-41`) has no Java counterpart: Java does not scan a directory.

**Tests:** new `java/src/test/java/io/antidrift/zeromcp/RemoteTest.java`, using a `com.sun.net.httpserver.HttpServer` on port 0 as a fake upstream (answers `initialize`, `tools/list` with `list_pages`/`get_page`, `tools/call`):
- `tools/list` via `handleRequest` returns `probeo.list_pages` and `probeo.get_page`; with `tools: ["list_pages"]` only `probeo.list_pages` (mirrors `nodejs/test/handler-remote.test.js`).
- `tools/call` on `probeo.list_pages` returns the upstream `content[0].text`; the upstream saw the bare name `list_pages` and the `Authorization: Bearer` header when `auth` is set (including `env:` form).
- A local tool registered as `probeo.list_pages` wins over the remote one.
- A `ftp://` URL and a non-2xx upstream are skipped; a second good server still loads.
- `ConfigTest`: `remote` array parses from `zeromcp.config.json`.

## 2. Remote federation in `registry()`
**Node does:** `createRegistry(tools, { remote })` connects remotes, merges remote-first with local override and the same log, and is now `async` for it (`nodejs/src/registry.ts:42-65`). Remote tools are in `mcp` `tools/list`/`tools/call` but not in `routes`/`openapi` (routes are built from local tools only, `:67-74`).

**Java today:** `registry()` is a synchronous instance method returning `new Registry(routeDefinitions(), buildOpenApiSpec(), this::handleRequest)` (`ZeroMcp.java:97-99`); no remote handling.

**Change:**
- `registry()` calls `connectRemotesOnce()` first. It stays synchronous and blocks while remotes connect (Java's existing style; no `CompletableFuture`). Signature unchanged: `public Registry registry()`.
- Remotes come from `Config.remote()` plus `ZeroMcp.remote(...)` (section 1), the Java equivalent of Node's `RegistryOptions.remote`. No new options type.
- `routeDefinitions()` (`ZeroMcp.java:101-109`) and `buildOpenApiSpec()` already skip `route == null`, so remote tools stay out of `routes()` and `openapi()`. `mcp()` is `handleRequest`, so it lists and calls them.

**Tests:** in `RegistryTest.java`, against the same fake upstream as section 1: remote tools appear in `registry.mcp()` `tools/list` and dispatch on `tools/call`; a same-named local tool overrides; `registry.routes()` and `registry.openapi().get("paths")` contain no remote entries.

## 3. Runtime context injection
**Node does:** `createHandler(config, { getRuntime })` (`nodejs/src/handler.ts:19-23,44`). On every local tool execution the scanner calls `getRuntime()` and, if not `undefined`, sets `ctx.runtime` beside `credentials` and `fetch` (`nodejs/src/scanner.ts:9-13,167-172`). Remote tools do not get it. Node's registry passes `getEnv()` as the second `execute` arg (`nodejs/src/registry.ts:46,63`).

**Java today:** `Ctx` is `record Ctx(String toolName, Permissions permissions)` (`Ctx.java:6-9`), built in `callTool` (`ZeroMcp.java:583`) and in the `serveHttp` route handler (`ZeroMcp.java:224`). No runtime/env slot, and `registry()` has no `getEnv` equivalent (`specs/lang/java/registry.md`, porting note 1, declined a `TEnv` generic).

**Change:**
- `Ctx.java`: add an `Object runtime` component, keep both existing constructors (they pass `null`), add a typed accessor. `Object` rather than a generic, so `ToolExecutor.execute(Map<String,Object>, Ctx)` (`ToolExecutor.java:10`) and every existing tool are untouched:
  ```java
  public record Ctx(String toolName, Permissions permissions, Object runtime) {
      public Ctx(String toolName, Permissions permissions) { this(toolName, permissions, null); }
      public Ctx(String toolName) { this(toolName, Permissions.of(), null); }
      public <R> R runtime(Class<R> type) { return type.cast(runtime); }
  }
  ```
- `ZeroMcp.java`: builder setter
  ```java
  public ZeroMcp runtime(Supplier<?> getRuntime)
  ```
- Behavior: when set, `getRuntime.get()` is called once per local tool execution, at both `Ctx` construction sites (`ZeroMcp.java:224,583`), and the value goes into `ctx.runtime()` (null stays null). Remote tools (section 1) do not read `Ctx`.
- Because `serve()`, `serveHttp()`, `handleRequest()` and `registry().mcp()` all run on the same `ZeroMcp` instance, the supplier applies to all of them; Java has no separate handler factory to scope it to. This also fills the registry's `getEnv` role on the `mcp` path. `RouteDefinition` callers build `Ctx` themselves and can pass a runtime through the 3-arg constructor.

**Tests:** `ZeroMcpTest.java`: with `.runtime(() -> "prod")`, a tool returning `ctx.runtime()` yields `prod` via `tools/call`; the supplier is called once per call (counter); without a supplier `ctx.runtime()` is null. `RegistryTest.java`: same through `registry.mcp()`.

## 4. Multiple transports from config (dropped)
Dropped (2026-10-13): no language ships a built-in HTTP server (decisions log, 2026-10-13), so there's no HTTP transport to configure or run alongside stdio.

## 5. `page_size` and `icon` config keys
**Node does:** `page_size` (default 0) and `icon` are config keys (`nodejs/src/config.ts:46,49`). `icon` goes through `resolveIcon` (`config.ts:66-102`): `data:` passes through; `http(s)` is fetched and turned into `data:<content-type or image/png>;base64,...`; anything else is read as a file (`~` → `$HOME`), MIME from extension (`.png .jpg .jpeg .gif .svg .ico .webp`, else `image/png`); failures log `[zeromcp] Warning: failed to fetch icon <icon>: <status|msg>` / `[zeromcp] Warning: failed to read icon file <icon>: <msg>` and yield no icon. Applied at startup (`server.ts:53,62`, `handler.ts:57,65`).

**Java today:** both exist only as builder setters, `pageSize(int)` and `icon(String)` (`ZeroMcp.java:66-77`), with the icon used verbatim; `Config` has neither field (`Config.java:15-31`).

**Change:**
- `Config.java`: `@SerializedName("page_size") private int pageSize = 0;` and `private String icon;` with getters `pageSize()` / `icon()`.
- `ZeroMcp(Config)` (`ZeroMcp.java:57-59`) seeds `this.pageSize = config.pageSize()`.
- Config `icon` is resolved once, in the same once-only startup step as `connectRemotesOnce()` (section 1), using a package-private `static String resolveIcon(String)` on `Config` that ports Node's rules and log lines above (`HttpClient` for URLs, `Files.readAllBytes` + `Base64` for files). The result fills `this.icon` only if `icon(String)` was not called; an explicit setter value is used as-is, as today.

**Tests:** `ConfigTest.java`: `page_size` and `icon` parse; `resolveIcon` passes `data:` through, converts a temp `.svg` file to `data:image/svg+xml;base64,...`, returns null with a warning for a missing file. `ZeroMcpTest.java`: config `page_size: 1` paginates `tools/list` with a `nextCursor`.

## Already at parity
- `resolveAuth` (`env:VAR` → env var, else literal) — `java/src/main/java/io/antidrift/zeromcp/Config.java:74-85`
- `title` — `Config.java:25,42`, used in OpenAPI `info.title` at `ZeroMcp.java:313`
- `execute_timeout` (default 30000, per-tool override) — `Config.java:27-28`; `ZeroMcp.java:585-587`
- Framework-agnostic handler entry point — `ZeroMcp.handleRequest(JsonObject)` (`ZeroMcp.java:445`); covered by section 1, no new entry point
- Hot reload (`autoload_tools`) — N/A: tools are registered in code (`ZeroMcp.tool`, `ZeroMcp.java:84-88`); no directory scanning or `WatchService` in `java/src/main` (grep)
- Tool sources / `separator` / `namespacing` — N/A for the same reason (`separator` is parsed at `Config.java:22` but no tool names are built from paths)
- `resources` / `prompts` config — N/A: registered in code (`ZeroMcp.resource` / `ZeroMcp.prompt`, `ZeroMcp.java:114-123`)
- `credentials` / `cache_credentials` — N/A: Node keys credentials by tool directory (`nodejs/src/scanner.ts:115-133`); Java tools have no directory
- `logging` / `bypass_permissions` — parsed (`Config.java:17-20`); in Node they only configure the sandboxed `ctx.fetch` (`scanner.ts:155-159`), which Java's `Ctx` does not have

## Verify
All build and test runs happen in the local all-language Docker image (repo-root `Dockerfile`, per `engineering/testing.md`), not on host toolchains. The image copies the source in at build time, so rebuild it after every change.

```sh
docker build -t zeromcp-tests .
docker run --rm zeromcp-tests sh -c 'cd java && mvn test'
docker run --rm zeromcp-tests node tests/conformance/run-all.js --language "Java"
```
