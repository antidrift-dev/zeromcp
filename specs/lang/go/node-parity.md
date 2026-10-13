# Node parity — Go

## Status
Not started. Spec only.

## Gaps
1. Remote federation (`remote` config)
2. Remote allowlist (`remote[].tools`)
3. Remote in the handler entry point (`(*Server).HandleRequest` / `HandleRequestBytes`)
4. Remote in the registry (`(*Server).Registry()`)
5. Runtime context injection (`Ctx.Runtime`)
6. Hot reload (`autoload_tools`)
7. Tool sources and namespacing (`tools`, `namespacing`)
8. Resource and prompt directories (`resources`, `prompts`)

## 1. Remote federation

**Node does:** `RemoteServer = { name, url, auth?, tools? }` (`nodejs/src/config.ts:5-11`). For each server, `RemoteManager.connect` rejects non-http(s) URLs, POSTs `initialize` (id 1, params `{}`) then `tools/list` (id 2) with `Content-Type: application/json` and `Authorization: Bearer <auth>` when auth resolves (`resolveAuth`, `config.ts:153-166`); non-2xx throws `HTTP <status>`. Each upstream `inputSchema` goes through `schemaToInput` and `toJsonSchema`; `execute` POSTs `tools/call` and returns `result.content[0].text` if truthy, else `result`. Tools are named `<server>.<tool>`; a failing server logs `[mcp] Failed to connect to <name>: <msg>` and is skipped (`nodejs/src/remote.ts:20-121`). `serve()` adds remote tools first, then local tools override with `[zeromcp] Local tool "<name>" overrides remote` (`nodejs/src/server.ts:20-36`). Remote tools have no `route`.

**Go today:** `Config` has no `remote` field (`go/pkg/zeromcp/config.go:11-22`). There is no remote client anywhere in `go/pkg/zeromcp` (grep for `remote`/`Remote` in `go/pkg` and `go/cmd` returns nothing). `ResolveAuth` already exists with Node's `env:VAR` semantics (`config.go:121-135`).

**Change:**
- `config.go`: add the config type and field.
  ```go
  // RemoteServer is an upstream MCP server whose tools are federated in.
  type RemoteServer struct {
      Name  string   `json:"name"`
      URL   string   `json:"url"`
      Auth  string   `json:"auth,omitempty"`  // literal or "env:VAR", resolved with ResolveAuth
      Tools []string `json:"tools,omitempty"` // allowlist, see §2
  }

  type Config struct {
      // ...existing fields...
      Remote []RemoteServer `json:"remote,omitempty"`
  }
  ```
- New file `go/pkg/zeromcp/remote.go`, unexported. Use only the standard library, since `go/go.mod` has no `require` entries today.
  - `connectRemotes(servers []RemoteServer) []remoteTool` connects to the servers in slice order. A `remoteTool` holds the namespaced name and the `Tool` value.
  - `connectRemote(srv RemoteServer) ([]remoteTool, error)`:
    - If the URL has neither an `http://` nor an `https://` prefix, return `Remote server "<name>" must have an HTTP/HTTPS URL, got: <url>`.
    - Call `auth := ResolveAuth(srv.Auth)`.
    - Send `initialize` with `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`, then `tools/list` with id 2. Ignore the initialize result, as Node does.
    - Read `result.tools`. If it is missing, treat it as empty.
    - Apply the §2 filter, then build one `Tool` per upstream tool in list order.
    - Recover a panic from `ToJsonSchema` (an unknown upstream type, `schema.go:57,65`) and return it as an error. Node's `toJsonSchema` throws in the same case (`nodejs/src/schema.ts:38,43`), which fails the whole server.
    - Log `[mcp] Connected to <name> (HTTP): <n> tool(s)`.
  - `httpRPC(url string, body any, auth string) (map[string]any, error)`: POST with `Content-Type: application/json`, plus `Authorization: Bearer <auth>` when `auth != ""`.
    - A status outside 200–299 returns the error `HTTP <code>`.
    - A body that is not valid JSON returns an error.
    - Use a plain `&http.Client{}` with no timeout, as Node's `fetch` has none.
  - `schemaToInput(schema map[string]any) Input`. For each property:
    - The type defaults to `"string"` when missing.
    - If the property has a description or is not in `required`, emit `InputField{Type, Description, Optional: !required}`.
    - Otherwise emit the bare type string.
  - The remote `Execute` is `func(args map[string]any, _ *Ctx) (any, error)`:
    - It POSTs `tools/call` with `id: time.Now().UnixMilli()` and `params: {"name": <upstream name>, "arguments": args}`.
    - It returns `result.content[0].text` when that is a non-empty string, otherwise `result` (nil when absent).
    - The ctx is ignored, as in Node.
  - Log `[mcp] Remote tool: <server>.<tool>` per tool, and `[mcp] Failed to connect to <name>: <err>` per failed server. A failed server is skipped and the others continue.
- `server.go`:
  - Add `remote bool` to `registeredTool` (`server.go:87-91`).
  - In `newServer` (`server.go:138-153`), call `connectRemotes(cfg.Remote)` when `len(cfg.Remote) > 0`. Insert each result into `s.tools` with `remote: true`, `Route: nil`, `Permissions: nil` and `cachedSchema: ToJsonSchema(input)`. Its ctx comes from `NewContext(name, nil, SandboxOptions{...}, nil)`.
  - This makes `NewServerWithConfig` block on the network when remotes are configured, the Go equivalent of Node's `await remoteManager.connect` in `serve`/`createHandler`/`createRegistry`. It is the one construction point that `Serve()`, `HandleRequest` and `Registry()` all share, so §3 and §4 come from this change.
  - In `(*Server).Tool` (`server.go:200-219`), if `s.tools[name]` exists and has `remote == true`, log `[zeromcp] Local tool "<name>" overrides remote` before replacing it.
  - Remote-first ordering then holds naturally. Remotes are inserted at construction, and every local registration (`Tool()`, or `Scanner.RegisterAll` in `cmd/zeromcp/main.go:68`) comes after.
- Remote tools have `Route == nil`, so `handleToolRoute` (`server.go:925`) and `buildOpenAPISpec` (`server.go:992`) already skip them. No change there.
- `tools/call` for remote tools goes through the existing `callTool` (`server.go:830-914`), which handles validation against `cachedSchema`, the config-default timeout, and string vs JSON text. No change.

**Tests:** new `go/pkg/zeromcp/remote_test.go` (package `zeromcp`, `net/http/httptest` upstream):
- Port `nodejs/test/handler-remote.test.js`. Upstream offers `list_pages` and `get_page`, with config `Remote: []RemoteServer{{Name: "probeo", URL: ts.URL, Tools: []string{"list_pages"}}}`.
  - `tools/list` returns exactly `probeo.list_pages`.
  - `tools/call` returns `[{type:"text", text:"{\"pages\":[]}"}]`.
- With `Auth: "env:X"` and `X` set, the upstream sees `Authorization: Bearer <value>` and `Content-Type: application/json` on every request.
- One server with `ftp://…` and one that returns 500 are both skipped, and a third valid server's tools are still listed.
- After `s.Tool("probeo.list_pages", …)`, `tools/call` runs the local tool.
- `schemaToInput` is unit-tested for the default type, a kept description, and required vs optional.

## 2. Remote allowlist

**Node does:** `remote[].tools?: string[]`. Only upstream tools whose name is in the list are exposed, and omitting it exposes all (`nodejs/src/config.ts:9-10`, `nodejs/src/remote.ts:61`). A present-but-empty array exposes none, because `!server.tools` is false for `[]`.

**Go today:** no `remote` config at all (`config.go:11-22`).

**Change:** in `connectRemote`, use `RemoteServer.Tools == nil` to mean all tools. A non-nil slice, including an empty one from JSON `[]`, keeps only names that appear in it. The filter applies to the upstream name, before namespacing.

**Tests:** in `remote_test.go`:
- nil `Tools` exposes both upstream tools.
- `Tools: []string{}` exposes none.
- The allowlist case is already covered in §1.

## 3. Remote in the handler entry point

**Node does:** `createHandler(config, options)` connects `config.remote`, adds remote tools, then lets local tools override with the same log (`nodejs/src/handler.ts:36-49`).

**Go today:** Go's framework-agnostic entry point is `(*Server).HandleRequest` / `HandleRequestBytes` (`server.go:457,487`; `go/README.md:49`). It dispatches over `s.tools` only, which never contains remote tools because nothing connects them (§1).

**Change:** none beyond §1. Remotes are connected in `NewServerWithConfig`, so `HandleRequest` sees them with no further change.

**Tests:** the §1 tests call `HandleRequest`, which covers this path.

## 4. Remote in the registry

**Node does:** `createRegistry(tools, { remote })` is async. It connects remotes, merges them, lets local tools override, and remote tools show up in `mcp` `tools/list` and `tools/call` but never in `routes` or `openapi` (`nodejs/src/registry.ts:42-65`). `routes` iterates only the local `tools` argument (`registry.ts:69`).

**Go today:** `(*Server).Registry()` derives `Routes`, `OpenAPI` and `MCP` from `s.tools` (`go/pkg/zeromcp/registry.go:33-65`). It has no remote input.

**Change:**
- No signature change. `Registry()` stays synchronous with no arguments. The remote input is `Config.Remote` on `NewServerWithConfig`, which already blocks during connect (§1). That is Go's equivalent of Node making `createRegistry` async.
- `Routes` (`registry.go:46`) and `OpenAPI` (`buildOpenAPISpec`, `server.go:992`) already skip `Route == nil`, so remote tools are excluded.
- `MCP` is `s.HandleRequestBytes`, so remote tools are included.

**Tests:** in `registry_test.go`, build a server with an httptest remote plus one local routed tool, then assert:
- `Routes` and `OpenAPI.paths` contain only the local tool.
- `MCP` `tools/list` contains both.
- `MCP` `tools/call` on the remote name returns the upstream text.

## 5. Runtime context injection

**Node does:**
- `createHandler(config, { getRuntime })` passes `getRuntime` to `ToolScanner` (`nodejs/src/handler.ts:19-21,44`).
- On every local tool execution, `getRuntime()` is called. If the result is not `undefined`, it is set as `ctx.runtime` next to `credentials` and `fetch` (`nodejs/src/scanner.ts:9-13,167-172`). Remote tools ignore ctx.
- `serve()` does not take `getRuntime` (`server.ts:11`).
- The registry's equivalent hook is `getEnv`, called per execution and passed as the second argument to `execute` (`nodejs/src/registry.ts:46,63`).

**Go today:**
- `Ctx` has `Credentials any` and unexported fields, with no runtime slot (`go/pkg/zeromcp/sandbox.go:38-44`).
- A single `*Ctx` is built once per tool in `Tool()` (`server.go:212-217`) and passed unchanged on every call: `callTool` at `server.go:875`, `handleToolRoute` at `server.go:961`, and `Registry().Routes[i].Invoke` at `registry.go:55`.
- The registry has no `getEnv` equivalent. That was deliberate (`specs/lang/go/registry.md`, "No `RegistryOptions`/`getEnv` equivalent").

**Change:**
- `sandbox.go`: add an exported field. `Runtime any` matches the existing `Credentials any`. A generic `Ctx[T]` would ripple into `Tool`, `PluginTool` and every `Execute` signature.
  ```go
  type Ctx struct {
      Credentials any
      Runtime     any // set per call from (*Server).SetRuntime; nil when unset
      // ...unexported fields unchanged...
  }
  ```
- `server.go`: add a hook on `Server`.
  ```go
  // SetRuntime installs a function called on every local tool execution;
  // a non-nil result is exposed to the tool as ctx.Runtime.
  func (s *Server) SetRuntime(get func() any)
  ```
  - Store it as `getRuntime func() any` on `Server`, guarded by `s.mu`.
  - Add a helper `func (s *Server) execCtx(rt *registeredTool) *Ctx`. If `getRuntime` is nil, or returns nil, it returns `rt.ctx` unchanged. Otherwise it returns a shallow copy, `c := *rt.ctx; c.Runtime = v; return &c`. Copying per call keeps the shared `*Ctx` free of data races across concurrent calls.
  - Use `execCtx(rt)` at all three call sites: `server.go:875`, `server.go:961` and `registry.go:55`. This one hook covers Node's `getRuntime` (handler) and `getEnv` (registry `mcp` and `routes`).
  - Skip remote tools (`rt.remote`), since their `Execute` ignores ctx anyway.
- Node's `serve()` has no hook. In Go, `Serve()` uses whatever `SetRuntime` installed, and with nothing set, behavior is unchanged.

**Tests:**
- In `server_test.go`:
  - Set `SetRuntime` to return a counter. Two `tools/call`s see `ctx.Runtime` values 1 and 2, which proves the hook is called per execution.
  - With no `SetRuntime`, `ctx.Runtime == nil`.
  - With `SetRuntime` returning nil, `ctx.Runtime == nil`.
- In `registry_test.go`: `Routes[0].Invoke` and `MCP` `tools/call` both see the runtime value.

## 6. Hot reload

**Node does:** when `autoload_tools` is set, `serve()` calls `toolScanner.watch`, which watches each tool source directory recursively (`nodejs/src/server.ts:72-81`, `nodejs/src/scanner.ts:184-206`).
- On a change to a tool file (`.js`/`.mjs`), it logs `[zeromcp] Change detected: <file>` and rescans.
- After the rescan, `serve()` sets each scanned tool into the live map with add/overwrite only, so removed tools are not deleted.
- It then sends `notifications/tools/list_changed` with params `{}`.
- Startup logs `[zeromcp] autoload_tools enabled — watching for changes`.
- `state.notify` is set only by the stdio transport and writes one JSON line to stdout (`server.ts:107-111`).

**Go today:**
- Go does load tools from a directory at runtime: `.so` plugins via `Scanner` (`go/pkg/zeromcp/scanner.go:45-125`), wired in `cmd/zeromcp/main.go:61-69`. So this item applies.
- There is no `autoload_tools` field (`config.go:11-22`), no watcher, and no outbound notification path. `serveStdio` writes responses directly at `server.go:298`, and nothing in `go/` sends `notifications/tools/list_changed`; grep only finds the inbound `roots/list_changed` case at `server.go:561`.

**Change:**
- `config.go`: add `AutoloadTools bool \`json:"autoload_tools,omitempty"\``.
- `server.go`, notification path:
  ```go
  // Notify sends a JSON-RPC notification on the stdio transport; no-op if stdio isn't running.
  func (s *Server) Notify(method string, params any)
  ```
  - `serveStdio` installs an unexported `notify` func when it starts.
  - Both `notify` and the response write at `server.go:298` go through one `stdoutMu sync.Mutex`, so lines never interleave.
  - The notification shape is `{"jsonrpc":"2.0","method":<method>,"params":<params>}`, and `params` is omitted when nil.
- `scanner.go`, watcher:
  ```go
  // Watch polls the scanner's source directories for .so changes and calls onChange after rescanning.
  func (s *Scanner) Watch(onChange func()) (stop func())
  ```
  - Poll recursively once a second, comparing `.so` path → modtime/size. That needs only the standard library; `go/go.mod` has no dependencies today.
  - On any added or changed `.so`, log `[zeromcp] Change detected: <rel path>`, call `s.Scan()`, then `onChange()`. Other extensions are ignored.
- `cmd/zeromcp/main.go`, after `RegisterAll` (`main.go:68`): if `cfg.AutoloadTools`, call `scanner.Watch(func() { scanner.RegisterAll(srv); srv.Notify("notifications/tools/list_changed", map[string]any{}) })` and log `[zeromcp] autoload_tools enabled — watching for changes`.
- Behavior to keep as in Node:
  - Tools are only added or overwritten, never removed.
  - Only stdio receives the notification.
- Runtime limit (verified):
  - `plugin.Open` returns the already-loaded plugin for a path it has opened before (`$(go env GOROOT)/src/plugin/plugin_dlopen.go:55-60`), so a `.so` rebuilt in place at the same path keeps its old code.
  - Loading a second plugin with an already-loaded pluginpath fails with `plugin already loaded` (`$(go env GOROOT)/src/runtime/plugin.go:28-35`).
  - In practice only `.so` files at new paths take effect. Do not work around this, and say so in the README under `autoload_tools`.

**Tests:**
- New `go/pkg/zeromcp/scanner_test.go`, using a temp dir and placeholder (non-loadable) `.so` files. Load errors are only logged.
  - `Watch` calls `onChange` after a `.so` is added and again after one is touched.
  - It does not fire for a `.txt` file.
  - `stop()` ends polling.
- In `server_test.go`: with `notify` capturing into a buffer, `Notify("notifications/tools/list_changed", map[string]any{})` emits the exact line `{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{}}`.

## 7. Tool sources and namespacing

**Node does:**
- `tools` is a string or an array of `string | {path, prefix}`, defaulting to `./tools` (`nodejs/src/config.ts:28-35,104-108`). Each source is scanned, and its `prefix` is prepended with the separator.
- `separator` defaults to `_`.
- `namespacing: { <dir>: { prefix } }` overrides the top-level directory prefix. A prefix of `""` drops the prefix (`nodejs/src/scanner.ts:90-113`).
- The CLI's positional tool dirs override `config.tools` (`nodejs/bin/mcp.js:45-48`).

**Go today:**
- `Config` has `Separator` (`config.go:15`, default `_` applied in `scanner.go:31-34`).
- There is no `tools` field and no `namespacing` field (`config.go:11-22`).
- `Scanner` takes one `dir` (`scanner.go:30`). `buildName` always uses the directory name as the prefix and has no source prefix (`scanner.go:78-90`).
- The CLI takes a single `--tools` dir, defaulting to `./tools` (`cmd/zeromcp/main.go:35,45-49,62-63`).

**Change:**
- `config.go`:
  ```go
  type ToolSource struct {
      Path   string `json:"path"`
      Prefix string `json:"prefix,omitempty"`
  }
  type NamespaceOverride struct {
      Prefix *string `json:"prefix,omitempty"` // nil = use dir name; "" = no prefix
  }
  type Config struct {
      // ...
      Tools       any                          `json:"tools,omitempty"`       // string | []string | []ToolSource (mixed), like Transport
      Namespacing map[string]NamespaceOverride `json:"namespacing,omitempty"`
  }
  // ResolveToolSources normalizes Config.Tools; nil → [{Path: "./tools"}].
  func ResolveToolSources(tools any) []ToolSource
  ```
  - `ResolveToolSources` takes `any` so that §8 can reuse it for `Resources` and `Prompts`.
  - Parse it with the same re-marshal approach `ResolveTransports` uses (`config.go:62-83`). Array elements may be strings or objects.
- `scanner.go`:
  - Replace `dir string` with `sources []ToolSource`.
  - Keep `NewScanner(dir string, cfg Config)` as a single-source constructor, and add `NewScannerFromConfig(cfg Config) *Scanner`, which uses `ResolveToolSources(cfg.Tools)`.
  - `Scan` iterates the sources, and an unreadable source is logged and skipped.
  - `buildName(filePath, rootDir, sourcePrefix)`: take the top-level dir prefix from `cfg.Namespacing[dir].Prefix` when non-nil, otherwise the dir name. Skip the dir segment when that is `""`. Then prepend `sourcePrefix + separator` when `sourcePrefix != ""`.
- `cmd/zeromcp/main.go`: when `--tools` is given, use `NewScanner(abs, cfg)`, so the CLI overrides config as in Node. Otherwise use `NewScannerFromConfig(cfg)`, resolving relative paths against the cwd.

**Tests:**
- In `config_test.go`, `ResolveToolSources` handles nil, a string, `[]string`, and a mixed array with `{path, prefix}`.
- In `scanner_test.go`, `buildName` handles:
  - the default dir prefix
  - a `namespacing` override to `"x"`
  - an override to `""`
  - a source prefix
  - a custom separator

## 8. Resource and prompt directories

**Node does:** `resources` and `prompts` take the same `string | (string | {path, prefix})[]` shape (`nodejs/src/config.ts:47-48`). `serve()` and `createHandler()` scan them (`server.ts:44-50`, `handler.ts:51-55`).
- **ResourceScanner** (`nodejs/src/resource-scanner.ts:55-148`) recurses through each dir and builds `name` as the relative path without extension, with path separators replaced by `separator`.
  - Dynamic files (`.js`/`.mjs`) export either `uriTemplate` (registered as a template, `mimeType` default `text/plain`) or `uri` (default `resource:///<name>`, `mimeType` default `application/json`), plus `read`.
  - Any other file is a static resource:
    - `uri` is `resource:///<relPath>`.
    - The description is `Static resource: <relPath>`.
    - The MIME type comes from `MIME_MAP`, otherwise `application/octet-stream`.
    - `read` returns the file contents.
  - Load failures log `[zeromcp] Failed to load resource <path>: <msg>`.
- **PromptScanner** (`nodejs/src/prompt-scanner.ts:29-115`) loads dynamic files only and uses the same naming.
  - A file with no `render` logs `[zeromcp] Prompt <path>: missing render() function`.
  - Other failures log `[zeromcp] Failed to load prompt <path>: <msg>`.

**Go today:**
- `Config` has no `resources` or `prompts` field (`config.go:11-22`).
- Resources, templates and prompts can only be registered in code: `Resource`, `ResourceTemplate` and `Prompt` (`server.go:222-243`), using `ResourceDef`, `ResourceTemplateDef` and `PromptDef` (`server.go:38-72`).
- There is no resource or prompt scanner.

**Change:**
- `config.go`: add `Resources any \`json:"resources,omitempty"\`` and `Prompts any \`json:"prompts,omitempty"\``, resolved with `ResolveToolSources` (§7). Only `path` is used, as in Node.
- New `go/pkg/zeromcp/resource_scanner.go`:
  ```go
  type ResourceScanner struct { /* dirs, separator */ }
  func NewResourceScanner(cfg Config) *ResourceScanner
  func (r *ResourceScanner) Scan()
  func (r *ResourceScanner) RegisterAll(srv *Server) // calls srv.Resource / srv.ResourceTemplate
  ```
  - `.so` files are dynamic. They export a `Resource` symbol of type `*ResourceDef` or a `ResourceTemplate` symbol of type `*ResourceTemplateDef`, reusing the existing types the same way `PluginTool` is looked up (`scanner.go:100-112`).
    - An empty `URI` defaults to `resource:///<name>`.
    - An empty `MimeType` defaults to `application/json` for a resource and `text/plain` for a template.
  - Every other file is static. Port `MIME_MAP` verbatim, with `Read` doing `os.ReadFile`.
  - Failures log `[zeromcp] Failed to load resource <path>: <err>`.
- New `go/pkg/zeromcp/prompt_scanner.go`, with the same shape: `NewPromptScanner(cfg)`, `Scan()`, `RegisterAll(srv)`.
  - Only `.so` files are loaded. Each exports a `Prompt` symbol of type `*PromptDef`.
  - A nil `Render` logs `[zeromcp] Prompt <path>: missing render() function` and is skipped.
  - Other failures log `[zeromcp] Failed to load prompt <path>: <err>`.
- `cmd/zeromcp/main.go`: after the tool scan, run both scanners and call `RegisterAll(srv)`.

**Tests:**
- New `resource_scanner_test.go`, using a temp dir with `a.md` and `sub/b.json`.
  - Names are `a` and `sub_b`, and a custom separator is honored.
  - URIs are `resource:///a.md` and `resource:///sub/b.json`.
  - MIME types are `text/markdown` and `application/json`, and an unknown extension gives `application/octet-stream`.
  - `resources/read` returns the file contents.
- Dynamic `.so` loading for resources and prompts is not unit-tested, because it needs a `-buildmode=plugin` build. Tool plugins have no scanner test today either; there is no `scanner_test.go` in `go/pkg/zeromcp`.

## Already at parity
- Multiple transports at once (object or array, stdio + http together): `go/pkg/zeromcp/config.go:62-83`, `go/pkg/zeromcp/server.go:247-267`.
- `title`: `config.go:21`, used at `server.go:976-979`.
- `logging`: `config.go:13`.
- `bypass_permissions`: `config.go:14`.
- `cache_credentials`: `config.go:17`, default true at `config.go:52-56`.
- `execute_timeout`: `config.go:18`, used at `server.go:860-867`.
- `page_size`: `config.go:19`, used at `server.go:603`.
- `icon`: `config.go:20`, resolved at `server.go:139-141`.
- `credentials`: `config.go:16`.
- `separator`: `config.go:15`, `scanner.go:31-34`.
- `resolveAuth` (`env:VAR` or literal): `config.go:121-135`.
- The "no tools directory" exit. Node's exit branch (`nodejs/src/server.ts:37-41`) never runs, because `ToolScanner._scanDir` catches `readdir` errors and returns (`nodejs/src/scanner.ts:66-71`), so `scan()` does not throw. Node logs and continues with 0 tools. Go does the same (`go/pkg/zeromcp/scanner.go:51-54`, `go/cmd/zeromcp/main.go:64-66`).

## Verify
All build and test runs happen in the local all-language Docker image (repo-root `Dockerfile`, per `engineering/testing.md`), not on host toolchains. The image copies the source in at build time, so rebuild it after every change.

```sh
docker build -t zeromcp-tests .
docker run --rm zeromcp-tests sh -c 'cd go && go build ./pkg/... ./cmd/... && go vet ./pkg/... && go test ./pkg/...'
docker run --rm zeromcp-tests node tests/conformance/run-all.js --language "Go"
```
