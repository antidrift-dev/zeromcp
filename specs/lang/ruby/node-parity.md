# Node parity — Ruby

## Status
Done (2026-10-13). Docker: Ruby unit suite 167 runs / 0 failures (new `test_remote.rb`, `test_autoload.rb`, plus remote/runtime/sources/icon cases in existing files); Ruby conformance suites all pass.

## Gaps
1. Remote federation (`remote` config) in `Server` (serve, serve_http, load_tools + handle_request)
2. Remote allowlist (`remote[].tools`)
3. Remote in the registry (`Registry.create(..., remote:)`)
4. Runtime context injection (`get_runtime:` → `ctx.runtime`)
5. Hot reload (`autoload_tools`)
6. Tool sources with prefix, and `namespacing`
7. ~~Multiple transports at once~~ (dropped: no built-in HTTP server, see `remove-builtin-http.md`)
8. `icon` as an http(s) URL

## 1. Remote federation in `Server`
**Node does:** `RemoteManager#connect` (`nodejs/src/remote.ts:20-38`) connects each `{ name, url, auth?, tools? }` in turn. Per server: non-http(s) URL raises (`remote.ts:41-43`); `auth` goes through `resolveAuth` (`env:VAR` → env var with a warning if unset, else literal; `config.ts:153-166`); POSTs `initialize` (id 1, params `{}`) then `tools/list` (id 2) with `Content-Type: application/json` and `Authorization: Bearer <auth>` when set; non-2xx raises `HTTP <status>` (`remote.ts:87-98`). Each remote tool's `inputSchema` is converted back to local input (`schemaToInput`, `remote.ts:101-121`), its `execute` POSTs `tools/call` `{name, arguments}` (id `Date.now()`) and returns `result.content[0].text` if present, else `result` (`remote.ts:69-79`). Registered as `<server.name>.<toolName>`, logging `[mcp] Remote tool: <ns name>`, then `[mcp] Connected to <name> (HTTP): <n> tool(s)`. A failing server logs `[mcp] Failed to connect to <name>: <msg>` and is skipped. `serve()` adds remotes first, then local tools override with `[zeromcp] Local tool "<name>" overrides remote` (`server.ts:23-36`); if the local scan throws and there are no remotes/resources/prompts it logs `[zeromcp] No tools directory and no remote servers configured` and exits 1 (`server.ts:37-42`). `createHandler` merges the same way but lets a scan error propagate (`handler.ts:39-49`). Remote tools have no `route`.

**Ruby today:** No remote support. `grep -rniE "remote|Net::HTTP" ruby/lib ruby/bin` returns nothing. `Config` has no `remote` reader (`Config.new('remote' => [...]).respond_to?(:remote)` → `false`; readers at `ruby/lib/zeromcp/config.rb:8-10,34`). Ruby's framework-agnostic handler path is `Server.new(config)` + `#load_tools` + `#handle_request` (README "HTTP / Streamable HTTP"; `ruby/lib/zeromcp/server.rb:90-101,153`), so Node's `createHandler` maps onto `load_tools`. `#serve` re-implements the `load_tools` body inline (`server.rb:109-118`); `#serve_http` calls `load_tools` (`server.rb:38`). `Scanner#scan` does not raise for a missing dir (`ruby/lib/zeromcp/scanner.rb:21-24`).

**Change:**
- New file `ruby/lib/zeromcp/remote.rb` (stdlib `net/http` + `json` only; no new gem dependency):
  ```ruby
  module ZeroMcp
    module Remote
      module_function

      # servers: Array<Hash> ('name', 'url', 'auth', 'tools'; string or symbol keys)
      # => Hash[String, ZeroMcp::Tool], keyed "<server name>.<tool name>"
      def connect(servers); end

      # JSON Schema properties/required -> ZeroMcp input hash
      def schema_to_input(schema); end
    end
  end
  ```
- `config.rb`: `attr_reader :remote` (`opts[:remote] || opts['remote'] || []`); add `Config.resolve_auth(auth)` next to `Config.resolve_icon` (`env:VAR` → `ENV[VAR]`, warning `[zeromcp] Warning: environment variable VAR not set` when unset; otherwise the literal; `nil` passes through).
- `Remote.connect` behavior, per server, in order, each wrapped in `rescue => e` → `$stderr.puts "[mcp] Failed to connect to #{name}: #{e.message}"` and continue:
  - Raise `Remote server "<name>" must have an HTTP/HTTPS URL, got: <url>` unless the URL starts with `http://` or `https://`.
  - POST `{jsonrpc: '2.0', id: 1, method: 'initialize', params: {}}`, then `{..., id: 2, method: 'tools/list', params: {}}`. Headers `Content-Type: application/json`, plus `Authorization: Bearer <token>` when `resolve_auth` returns a value. Non-2xx → raise `HTTP <code>`. Body parsed with `JSON.parse`.
  - For each `result['tools']` entry: `input = schema_to_input(inputSchema)`; build `Tool.new(name: "<server>.<tool>", description:, input:, permissions: {}, route: nil) { |args, _ctx| ... }`. The block POSTs `tools/call` with `params: {name: <upstream name>, arguments: args}` and id `(Time.now.to_f * 1000).to_i`, returns `result['content'][0]['text']` when truthy, else `result['result']`.
  - `schema_to_input`: for each property, `type = prop['type'] || 'string'`; when the property has a `description` or is not in `required`, emit `{ type:, description: (if present), optional: true (if not required) }`; otherwise emit the bare type string. No `properties` → `{}`.
  - Log `[mcp] Remote tool: <ns name>` per tool and `[mcp] Connected to <name> (HTTP): <n> tool(s)` per server.
- `server.rb`:
  - `load_tools`: when `@config.remote` is non-empty, start the tool map from `Remote.connect(@config.remote)`, then merge `@scanner.scan` over it, logging `[zeromcp] Local tool "<name>" overrides remote` for each collision. Scan errors propagate (handler path, like `createHandler`).
  - `serve`: replace the inline block at `server.rb:109-118` with a call to the same loading path so stdio gets remotes too.
  - `serve` / `serve_http` only: if the local scan raises and `@config.remote`, `@config.resources_dir` and `@config.prompts_dir` are all empty, `$stderr.puts "[zeromcp] No tools directory and no remote servers configured"` and `exit 1`; otherwise continue without local tools.
  - Remote tools have `route: nil`, so the existing route loop (`server.rb:77-80`) and `OpenApi.build` (`ruby/lib/zeromcp/openapi.rb:13`) already skip them.
- `ruby/lib/zeromcp.rb`: `require_relative 'zeromcp/remote'`.

**Tests:** new `ruby/test/test_remote.rb` (Minitest). Start a `WEBrick::HTTPServer` on `Port: 0` in a thread that answers `initialize` / `tools/list` (two tools) / `tools/call` like `nodejs/test/handler-remote.test.js:6-17`. Cases: `load_tools` + `handle_request` `tools/list` shows `<server>.<tool>` names; `tools/call` returns the upstream `content[0].text`; Bearer header sent when `auth` is set, and `env:VAR` resolves from `ENV`; non-http URL and a 500 response are logged and skipped while a second good server still loads; a local tool with the same name overrides and logs; `schema_to_input` unit cases (default `'string'`, description kept, optional when not required).

## 2. Remote allowlist
**Node does:** `remote[].tools?: string[]` keeps only upstream tools whose name is in the list; omitted → all (`nodejs/src/config.ts:9-10`, `nodejs/src/remote.ts:61`).

**Ruby today:** No remote config at all (see 1).

**Change:** In `Remote.connect`, filter `result['tools']` by `server['tools']` (upstream, un-namespaced names) when it is present; `nil` → keep all.

**Tests:** in `test_remote.rb`, `tools: ['list_pages']` against a two-tool upstream yields only `<server>.list_pages` (mirrors `handler-remote.test.js:28-31`).

## 3. Remote in the registry
**Node does:** `createRegistry(tools, { remote })` connects remotes first, merges local tools over them with the same override log, and serves the merged map from `mcp`; `routes` is built from the local `tools` only and remote tools carry no route, so they never appear in `routes` or `openapi` (`nodejs/src/registry.ts:49-65,69-74,87`). `createRegistry` is async because of this.

**Ruby today:** `Registry.create(tools, config: nil, title: nil, execute_timeout: nil)` builds `Server.new(cfg, tools: tools)` with no remote step (`ruby/lib/zeromcp/registry.rb:38-55`).

**Change:**
```ruby
def create(tools, config: nil, title: nil, execute_timeout: nil, remote: nil)
def self.create_registry(tools, config: nil, title: nil, execute_timeout: nil, remote: nil)
```
- `remote:` is threaded into `Config.new` when no `config:` is given, same pattern as `title:` / `execute_timeout:` (`registry.rb:39`); with `config:`, `config.remote` is used.
- When `cfg.remote` is non-empty: `merged = Remote.connect(cfg.remote)`, then each local tool is set over it with the override log. `Server.new(cfg, tools: merged)` backs `mcp`; `openapi` is `OpenApi.build(merged, cfg)` (route-less remotes are skipped); `routes` stays built from the caller's local `tools`.
- Stays synchronous: `create` blocks while connecting. The Ruby dispatch stack is blocking throughout (registry.md, "Porting notes"), so there is no async variant.

**Tests:** in `ruby/test/test_registry.rb`, with the same WEBrick fake upstream: remote tools appear in `registry.mcp` `tools/list` and answer `tools/call`; a same-named local tool overrides and logs; remote tools are absent from `registry.routes` and `registry.openapi['paths']` (mirrors `nodejs/test/registry.test.js:156-230`).

## 4. Runtime context injection
**Node does:** `createHandler(config, { getRuntime })` passes `getRuntime` to `ToolScanner`. On every local tool execution it is called, and if the result is not `undefined` it is set as `ctx.runtime` next to `credentials` and `fetch` (`nodejs/src/handler.ts:19-23,44`; `nodejs/src/scanner.ts:9-13,167-171`). Remote tools never call it. `serve()` does not accept it. Node's registry does the same job with `getEnv`, whose result is the second argument to each tool's `execute` on the `mcp` path (`nodejs/src/registry.ts:46,63`).

**Ruby today:** `Context` has `tool_name`, `credentials`, `permissions`, `bypass` and no runtime slot (`ruby/lib/zeromcp/tool.rb:34-43`). `Server#initialize(config = nil, tools: nil)` (`server.rb:17`) takes no hook. Contexts are built in `call_tool` (`server.rb:484`) and `register_tool_route` (`server.rb:540-542`). The registry has no `getEnv` equivalent: `registry.mcp` goes through `Server#call_tool` with no caller-supplied value, and `ToolRegistry#context_for` builds credentials/permissions only (`registry.rb:16-23`).

**Change:**
```ruby
class Context
  attr_reader :credentials, :tool_name, :permissions, :bypass, :runtime
  def initialize(tool_name:, credentials: nil, permissions: {}, bypass: false, runtime: nil)
end

class Server
  # get_runtime: optional callable (lambda/proc/method), arity 0. Its return value becomes ctx.runtime.
  def initialize(config = nil, tools: nil, get_runtime: nil)
end

module Registry
  def create(tools, config: nil, title: nil, execute_timeout: nil, remote: nil, get_runtime: nil)
end
```
- `runtime` is an untyped Ruby object; `nil` (hook absent or returns `nil`) matches Node leaving `ctx.runtime` unset.
- `Server#call_tool` and `#register_tool_route` call `@get_runtime&.call` per execution of a **local** tool and pass it as `runtime:`. Remote tools (item 1) skip the call; `Server` records the remote names when it merges them.
- `ZeroMcp.serve` / `ZeroMcp.serve_http` and `bin/zeromcp` do not take it (matches Node `serve()`).
- Registry: `get_runtime:` is passed through to the internal `Server.new`, so `registry.mcp` `tools/call` sets `ctx.runtime`, and `ToolRegistry#context_for(tool)` sets `runtime:` from the same hook. This is how Ruby gets Node's `getEnv` (the value goes in `ctx.runtime` because Ruby's second argument is always a `Context`). `context_for` stays.

**Tests:** `ruby/test/test_server.rb`: `Server.new(@config, get_runtime: -> { { 'db' => :x } })` and a tool that returns `ctx.runtime`; assert it arrives through `tools/call`; with no hook, `ctx.runtime` is `nil`; the hook is called once per call. `ruby/test/test_registry.rb`: `create_registry(tools, get_runtime: ...)` reaches the tool via `registry.mcp` and via `context_for`.

## 5. Hot reload (`autoload_tools`)
**Node does:** if `autoload_tools`, `serve()` watches each tool source dir recursively. On a change to a tool file (`.js`/`.mjs`) it logs `[zeromcp] Change detected: <file>`, rescans, sets every rescanned tool into the live map (it never removes entries), and calls `state.notify('notifications/tools/list_changed', {})`, logging `[zeromcp] autoload_tools enabled — watching for changes` at startup (`nodejs/src/server.ts:72-81`; `nodejs/src/scanner.ts:184-206`). `notify` is only installed by the stdio transport (`server.ts:107-111`), so HTTP-only gets no notification. `createHandler` does not watch.

**Ruby today:** tools are loaded from directories at runtime (`instance_eval` of `.rb` files, `scanner.rb:14-28,70-74`), so this applies. No `autoload_tools` reader (`respond_to?(:autoload_tools)` → `false`), no watcher, and no outbound notifications. `grep -rniE "watch|autoload|list_changed" ruby/lib` only hits the inbound `notifications/roots/list_changed` handler (`server.rb:215`).

**Change:**
- `config.rb`: `attr_reader :autoload_tools` (default `false`).
- `server.rb`: in `serve` / `serve_http` (not `load_tools`), when `@config.autoload_tools`, start a background polling thread and log the startup line above. Ruby stdlib has no recursive fs watcher and the gem has no dependencies (`ruby/zeromcp.gemspec`), so poll: every 1s, snapshot `File.mtime` of `Dir.glob('**/*.rb')` under each tool source; on any added/changed/removed path, log `[zeromcp] Change detected: <relative path>`, run `@scanner.scan`, and set each result into `@tools` (no deletions, no override log, same as Node).
- After a reload, when the stdio transport is running, write `{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{}}` to stdout. Writes from the watcher thread and the stdin loop share a `Mutex` around `$stdout.puts`.
- The thread is stopped on shutdown (INT/TERM, end of `serve`).

**Tests:** `ruby/test/test_server.rb` (or new `test_autoload.rb`): copy a tool into a tmp dir, start the watcher via a test seam with a short interval, add a second `.rb` file, and assert it appears in `tools/list` and a `list_changed` notification is emitted to a captured stdout.

## 6. Tool sources with prefix, and `namespacing`
**Node does:** `tools` may be a string or an array of `string | { path, prefix }` (`nodejs/src/config.ts:28-35,104-108`). A tool name is `<dirPrefix><sep><file>` for files under a subdir, where `dirPrefix` is `namespacing[<top dir>].prefix` when that key is defined (an empty string means no prefix) and the dir name otherwise. A source `prefix` is then prepended as `<prefix><sep><name>` (`nodejs/src/scanner.ts:90-113`). Credentials for scanned tools are keyed by the top-level directory, not the name (`scanner.ts:115-133`). `resources` / `prompts` accept the same `string | {path, prefix}` shapes and use only `path` (`nodejs/src/resource-scanner.ts:61-64`, `nodejs/src/prompt-scanner.ts:35-38`). `separator` defaults to `_`.

**Ruby today:** `tools_dir` / `resources_dir` / `prompts_dir` take strings only (`config.rb:13-20`). A `{ 'path' => ..., 'prefix' => ... }` entry raises `TypeError: no implicit conversion of Hash into String` in `Scanner#scan`, `ResourceScanner#scan` and `PromptScanner#scan` (checked by running each). `namespacing` is read (`config.rb:28,34`) and never used: `build_name` always uses the raw dir name (`scanner.rb:76-87`), and `namespacing: { 'math' => { 'prefix' => 'm' } }` still yields `math_add` (checked by running). Credentials are matched by tool-name prefix (`ruby/lib/zeromcp/credentials.rb:9-17`).

**Change:**
- `config.rb`: normalize each `tools` entry to a source hash `{ 'path' => String, 'prefix' => String|nil }`. Add `attr_reader :tool_sources` (Array of those). Keep `tools_dir` returning the path strings so existing callers/tests (`test/test_config.rb:12,35,53,65`) are unchanged. `resources` / `prompts` accept the same shapes and keep only `path` in `resources_dir` / `prompts_dir`.
- `scanner.rb`: `scan` iterates `@config.tool_sources`, passing the source prefix down. `build_name(file_path, root_dir, source_prefix)`:
  ```ruby
  # inner = filename, or "#{dir_prefix}#{sep}#{filename}" when under a subdir, where
  # dir_prefix = namespacing[dir]['prefix'] if namespacing[dir] has a prefix key (string or symbol), else dir;
  # an empty dir_prefix means no prefix.
  # result = source_prefix ? "#{source_prefix}#{sep}#{inner}" : inner
  ```
- Credential lookup for scanned tools follows Node, keyed by the top-level directory, so a renamed prefix still finds its credentials. `Tool.new` gets an optional `credentials_ns:` keyword (set by `Scanner` to `parts[0]` when the file is in a subdir, else `nil`). `Credentials.resolve` uses `config.credentials[credentials_ns]` when the tool has one. Tools built by hand (registry) keep today's name-prefix matching.

**Tests:** `ruby/test/test_config.rb`: mixed `['./a', { 'path' => './b', 'prefix' => 'x' }]` normalizes, and `tools_dir` still returns paths. `ruby/test/test_scanner.rb`: source prefix → `x_hello`; `namespacing` override → `m_add`; empty-string override → `add`; credentials resolve by dir under a namespacing override. `test_resource_scanner.rb` / `test_prompt_scanner.rb`: `{ 'path' => ... }` entries load.

## 7. Multiple transports at once (dropped)
Ruby won't ship a built-in HTTP server (`remove-builtin-http.md`), so there is no second transport to run alongside stdio. Users mount `ZeroMcp.create_registry` in their own server. Where other sections mention `serve_http`, that applies only until `remove-builtin-http.md` lands.

## 8. `icon` as an http(s) URL
**Node does:** `resolveIcon` accepts a data URI, an `http(s)` URL (fetched; `content-type` header or `image/png`; non-2xx or error logs `[zeromcp] Warning: failed to fetch icon <url>: <status|msg>` and returns undefined), or a file path (`nodejs/src/config.ts:66-102`).

**Ruby today:** `Config.resolve_icon` handles data URIs and file paths only (`config.rb:51-66`). `Config.resolve_icon('https://example.com/icon.png')` returns `nil` (checked by running), because the URL is treated as a missing file.

**Change:** in `Config.resolve_icon`, before the file-path branch, add: for `http://` / `https://`, `Net::HTTP.get_response`; on 2xx return `"data:#{content_type || 'image/png'};base64,#{Base64.strict_encode64(body)}"`; otherwise warn with Node's message and return `nil`.

**Tests:** `ruby/test/test_config.rb`: WEBrick on port 0 serving a PNG with `image/png` → data URI; a 404 → `nil` plus a warning on `$stderr`.

## Already at parity
- `title` — `config.rb:31`, used by `openapi.rb:54`
- `logging` — read at `config.rb:23` (`Sandbox.check_network_access` takes it, `sandbox.rb:7`)
- `bypass_permissions` — `config.rb:24`, passed into `Context` at `server.rb:484,541`
- `cache_credentials` — `config.rb:27`, honored at `credentials.rb:20`
- `execute_timeout` — `config.rb:25`, used at `server.rb:487-491` (Ruby unit is seconds)
- `page_size` — `config.rb:29`, `server.rb:417-426`
- `resources` / `prompts` (string or string array) — `config.rb:16-20`, `scanner.rb:157-169,272-283`
- `credentials` (env/file) — `credentials.rb:27-41`
- `separator` — `config.rb:22`, `scanner.rb:83,184,297`
- Framework-agnostic handler entry point exists (`Server#load_tools` + `#handle_request`, `server.rb:90,153`), so Node's `createHandler` maps onto it. Its remote merge and runtime hook are covered by items 1 and 4, and no new entry point is needed.

## Verify
All build and test runs happen in the local all-language Docker image (repo-root `Dockerfile`, per `engineering/testing.md`), not on host toolchains. The image copies the source in at build time, so rebuild it after every change.

```sh
docker build -t zeromcp-tests .
docker run --rm zeromcp-tests sh -c 'cd ruby && ruby -I lib -I test -e 'Dir["test/**/test_*.rb"].each { |f| require File.expand_path(f) }''
docker run --rm zeromcp-tests node tests/conformance/run-all.js --language "Ruby"
```
