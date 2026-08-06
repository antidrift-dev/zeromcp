# Framework-neutral tool registry — Ruby

## Status

**Spec — not yet implemented.** This is a port plan for the capability shipped in Node.js (`nodejs/src/registry.ts`, commit `f440f41` → `764af3b` → `e3b134b`; see `specs/lang/nodejs/registry.md` for the as-built reference). Nothing described below exists in `ruby/lib/` yet.

## Motivation

Ruby's built-in HTTP server (`ruby/lib/zeromcp/server.rb`, class `ZeroMcp::Server`) already does two things beyond stdio JSON-RPC dispatch:

1. Mounts a `POST /mcp` JSON-RPC endpoint and per-tool routes (`tool.route`) directly onto a `WEBrick::HTTPServer` (`Server#serve_http`, `Server#register_tool_route`).
2. Builds `/openapi.json` from routed tools (`Server#build_openapi_spec`, private, lines 602-640 of `server.rb`).

Both are locked inside `Server#serve_http`'s WEBrick loop. A Ruby consumer who wants ZeroMCP tools inside Rails, Sinatra, Rack middleware, or a Lambda handler has no way to get at the routing data or the OpenAPI doc without instantiating a full `Server`, calling `serve_http`, and fighting WEBrick for control of the process — there is no way to embed.

This spec adds a second, additive entry point — `ZeroMcp::Registry` — that hands back plain data (`routes`, `openapi`) and a reusable JSON-RPC callable (`mcp`), built from the *same* dispatch and OpenAPI logic `Server` already has, so a Ruby engineer can wire ZeroMCP tools into their own framework instead of using `serve_http`.

`Server#serve_http` and `ZeroMcp.serve`/`ZeroMcp.serve_http` (`ruby/lib/zeromcp.rb`) are unchanged. This is not a replacement.

## Public API

New file: `ruby/lib/zeromcp/registry.rb`.

```ruby
module ZeroMcp
  module Registry
    RouteDefinition = Struct.new(:name, :method, :path, :tool, keyword_init: true)
    ToolRegistry     = Struct.new(:routes, :openapi, :mcp, keyword_init: true)

    # tools:  Hash[String, ZeroMcp::Tool] — already-constructed Tool instances,
    #         the same object Scanner#load_tool produces. Not raw hashes, and
    #         not file paths — this is the "already loaded" entry point,
    #         distinct from Scanner's file-scanning path.
    # config: optional ZeroMcp::Config. Defaults to ZeroMcp::Config.new (in-memory
    #         defaults, no zeromcp.config.json file read — see Behavior).
    def self.create(tools, config: nil)
      # ...
    end
  end

  # Top-level convenience, mirroring ZeroMcp.serve / ZeroMcp.serve_http.
  def self.create_registry(tools, config: nil)
    Registry.create(tools, config: config)
  end
end
```

Usage:

```ruby
require 'zeromcp'

tools = {
  'echo' => ZeroMcp::Tool.new(
    name: 'echo', description: 'Echo a message', input: { message: 'string' },
    route: { method: 'POST', path: '/echo' }
  ) { |args, _ctx| { message: args['message'], echoed: true } }
}

registry = ZeroMcp.create_registry(tools)

registry.routes   # => [#<struct ZeroMcp::Registry::RouteDefinition name="echo", method="POST", path="/echo", tool=#<ZeroMcp::Tool ...>>]
registry.openapi  # => { 'openapi' => '3.0.0', 'info' => {...}, 'paths' => {...} }
registry.mcp.call({ 'jsonrpc' => '2.0', 'id' => 1, 'method' => 'tools/list' })
```

`registry.mcp` is a `Proc`/lambda of arity 1: `->(request_hash) { ... }` returning a response `Hash` or `nil` for notifications — same contract as `Server#handle_request`, called the same way. It is a plain callable (`.call(request)`), not a `Method` object bound in a way that leaks the internal `Server`.

### `ZeroMcp::Tool#route_method` / `#route_path` (new, small)

`server.rb` currently normalizes `tool.route[:method] || tool.route['method']` (symbol-or-string key) in two places independently (`register_tool_route` and `build_openapi_spec`). The registry's `routes` filter needs the same normalization a third time. Rather than triplicate it, add two reader methods to `ZeroMcp::Tool` (`ruby/lib/zeromcp/tool.rb`):

```ruby
def route_method
  return nil unless @route.is_a?(Hash)
  (@route[:method] || @route['method'] || 'POST').upcase
end

def route_path
  return nil unless @route.is_a?(Hash)
  @route[:path] || @route['path'] || '/'
end
```

`Server#serve_http`, `Server#build_openapi_spec`, and `Registry.create` all use these instead of re-deriving. This is a pure refactor of existing call sites — no behavior change.

## Behavior

- **Tool input, not file input.** `Registry.create` takes a `Hash[String, ZeroMcp::Tool]` — already-built `Tool` objects, the same class `Scanner#load_tool` instantiates (`ruby/lib/zeromcp/scanner.rb:56`). It does **not** scan a directory. This is the deliberate split the task called out: `Scanner` (file-based, `Dir.entries` + `instance_eval` of `.rb` DSL files) stays exactly as-is and is untouched by this spec; `Registry` is for a caller who already has `Tool` instances in hand (built by hand, generated, or loaded some other way) and wants routing/OpenAPI/dispatch without going through the filesystem scanner at all.

- **Dispatch reuse — extend `Server`, don't duplicate it.** Ruby's `Server` has no `createState`/`handleRequest` split the way Node's does; `Server` is a single class whose instance variables (`@tools`, `@resources`, `@templates`, `@prompts`, `@config`, `@icon`, `@credential_cache`, ...) *are* the "state," and `#handle_request` (already public, `server.rb:153`) is the dispatcher that closes over them. Reusing it without duplicating JSON-RPC logic means constructing a `Server` whose `@tools` is the caller's hash instead of scanner output, then handing out `server.method(:handle_request)`-equivalent as `mcp`.

  This requires one small, backward-compatible change to `Server#initialize`:

  ```ruby
  # Before
  def initialize(config = nil)
    @config = config || Config.load
    @scanner = Scanner.new(@config)
    @resource_scanner = ResourceScanner.new(@config)
    @prompt_scanner = PromptScanner.new(@config)
    @tools = {}
    ...
    @icon = nil
    @credential_cache = {}
  end

  # After
  def initialize(config = nil, tools: nil)
    @config = config || Config.load
    @scanner = Scanner.new(@config)
    @resource_scanner = ResourceScanner.new(@config)
    @prompt_scanner = PromptScanner.new(@config)
    @tools = tools || {}
    ...
    @icon = tools ? Config.resolve_icon(@config.icon) : nil
    @credential_cache = {}
  end
  ```

  Existing callers (`ZeroMcp.serve`, `ZeroMcp.serve_http`, `Server.new` with no args) pass no `tools:` kwarg, so `@tools` and `@icon` initialize exactly as before — no behavior change to `#serve` / `#serve_http` / `#load_tools`. `Registry.create` becomes:

  ```ruby
  def self.create(tools, config: nil)
    cfg = config || Config.new
    server = Server.new(cfg, tools: tools)
    ToolRegistry.new(
      routes:  build_routes(tools),
      openapi: OpenApi.build(tools, cfg),
      mcp:     ->(request) { server.handle_request(request) }
    )
  end
  ```

  `@resources`, `@templates`, `@prompts` stay `{}` on this `Server` instance (never populated, since `Registry` never calls `load_tools`), so `initialize`/`tools/list` responses from `registry.mcp` correctly advertise no resources/prompts capability — a registry built from a tools-only hash *is* tools-only. `resources/list`, `prompts/list`, etc. still work via `#handle_request` (empty results), they're just never populated — matches Node's registry, which is also tools-only.

- **OpenAPI reuse — extract, don't reach into `private`.** `Server#build_openapi_spec` and its three helpers (`build_openapi_parameters`, `build_openapi_request_body`, `input_field_to_openapi_schema`, `server.rb:602-699`) are private instance methods on `Server`, closed over `@tools`/`@config`. Reusing them from `Registry` either means making them public (leaks server internals) or reaching in via `send` (fragile, un-idiomatic). Instead, extract them verbatim into a new module:

  New file: `ruby/lib/zeromcp/openapi.rb`

  ```ruby
  module ZeroMcp
    module OpenApi
      module_function

      def build(tools, config)
        # body of the old Server#build_openapi_spec, taking tools/config
        # as arguments instead of reading @tools/@config
      end

      # build_openapi_parameters, build_openapi_request_body,
      # input_field_to_openapi_schema move here unchanged (as module_function),
      # updated to use Tool#route_method / #route_path per above.
    end
  end
  ```

  `Server#build_openapi_spec` (the `/openapi.json` mount_proc at `server.rb:57-60`) becomes a one-line delegate: `OpenApi.build(@tools, @config)`. `Registry.create` calls the same `OpenApi.build(tools, cfg)`. One implementation, two callers — matches the Node spec's "reuses the exact OpenAPI-building logic... extract/reuse it, don't reimplement" instruction precisely.

- **`routes` — plain data, no routing.** `Registry.create` filters the `tools` hash down to entries where `tool.route.is_a?(Hash)`, in hash-iteration order (Ruby hashes preserve insertion order, same as JS `Object.entries` — the two languages already have matching semantics here, no extra work needed to match Node's ordering guarantee). Each surviving entry becomes a `RouteDefinition.new(name:, method:, path:, tool:)` using `tool.route_method` / `tool.route_path`. No path-param extraction, no HTTP method matching, no request/response handling — identical scope to Node. The caller (Rails router, Sinatra `get`/`post` block, Rack middleware, Lambda handler) is responsible for turning `:name` segments (ZeroMCP's route-path convention, e.g. `/greet/:name` — see `tests/conformance/route-tools/greet.rb`) into whatever param syntax their framework/router uses, extracting args, and calling `route.tool.call(args, ctx)`.

- **No `getEnv` equivalent — and why.** Node's `Tool#execute(args, env)` takes a free-form `env` value the registry threads through from `options.getEnv`. Ruby's `Tool#call(args, ctx)` second argument is not free-form — it is always a `ZeroMcp::Context` (`tool_name`, `credentials`, `permissions`, `bypass`; `tool.rb:24-33`), and building one requires the credential-resolution logic that today lives as private methods on `Server` (`_resolve_credentials`, `_resolve_credentials_for_ns`, `_resolve_credential_source`, `server.rb:501-533`, duplicated verbatim between `#call_tool` and `#register_tool_route`). There is no generic "environment" slot in `Tool`/`Context` today, and adding one would be a breaking change to both — out of scope for an additive spec.

  Instead, extract the credential-resolution trio into a small reusable module (same shape as the `OpenApi` extraction above):

  New file: `ruby/lib/zeromcp/credentials.rb`

  ```ruby
  module ZeroMcp
    module Credentials
      module_function

      def resolve(tool_name, config, cache: nil)
        # body of Server#_resolve_credentials / _resolve_credentials_for_ns /
        # _resolve_credential_source, parameterized on config + optional cache hash
      end
    end
  end
  ```

  `Server#call_tool` and `Server#register_tool_route` both switch to calling `Credentials.resolve(name, @config, cache: @credential_cache)`. `Registry::ToolRegistry` gains one more field/method so a caller building their own framework handler for a routed tool can get a correctly-populated `Context` without reimplementing credential lookup:

  ```ruby
  ToolRegistry = Struct.new(:routes, :openapi, :mcp) do
    def context_for(tool)
      ZeroMcp::Context.new(
        tool_name: tool.name,
        permissions: tool.permissions,
        bypass: @config.bypass_permissions,
        credentials: ZeroMcp::Credentials.resolve(tool.name, @config, cache: @credential_cache)
      )
    end
  end
  ```

  (Exact mechanism — closure vs. stored `@config`/`@credential_cache` on the struct — is an implementation detail; the contract is `registry.context_for(route.tool)` returns a ready-to-use `Context` so a caller's framework code can do `route.tool.call(args, registry.context_for(route.tool))` without hand-rolling credential/permission wiring.) This is the Ruby-shaped analog of `getEnv`: instead of the caller supplying an opaque env value, the registry supplies a helper that builds the *same* structured `Context` the built-in server already builds, using the *same* config-driven credential/permission rules — no new auth concept, no duplication.

- **Validation/timeout are not applied on the `routes` path**, matching Node exactly: a caller invoking `route.tool.call(args, ctx)` directly gets no `Schema.validate` and no `Timeout.timeout` wrapping — those are `Server#call_tool`'s job (used internally by `registry.mcp`, i.e. the `tools/call` JSON-RPC path), not the raw `Tool#call`. If a caller wants validation/timeout on their own framework's routes, they call `Schema.validate(args, tool.cached_schema)` (already public, `Schema` module) and wrap in `Timeout.timeout` themselves — same primitives `Server` uses, no registry-specific behavior to learn.

- **Config default: `Config.new`, not `Config.load`.** `ZeroMcp.serve`/`ZeroMcp.serve_http` default to `Config.load`, which reads `./zeromcp.config.json` relative to the process's cwd (`config.rb:36-45`). A `Registry` is meant to be embedded inside another app's process (Rails, Sinatra, a Lambda) where that cwd-relative file read is very likely to be either absent or *wrong* (picking up an unrelated file, or silently no-op'ing via the rescue-and-return-defaults path). `Registry.create`/`ZeroMcp.create_registry` default `config` to `Config.new` (in-memory defaults — 30s `execute_timeout`, no credentials, `bypass_permissions: false`, etc.) instead, and accept an explicit `config:` keyword for a caller who does want file-backed or hand-built config. This is a deliberate divergence from `ZeroMcp.serve`'s default and should be called out in the registry's docs/README so it isn't surprising.

### Non-goals

- Does not replace or call into `Server#serve_http`'s WEBrick loop.
- Does not do HTTP request/response handling, routing, or body parsing — `routes` is data, not wired handlers (no Rack app, no WEBrick mount).
- Does not add a Rack, Sinatra, or Rails dependency.
- Does not touch `Scanner`, `ResourceScanner`, or `PromptScanner` — file-based tool loading is completely orthogonal and unchanged.
- No auth hook (matches Node) — auth is the caller's framework's concern. `context_for` (above) is credential/permission wiring the framework already does for its own routes, not an auth mechanism.

## Packaging

- New files:
  - `ruby/lib/zeromcp/registry.rb` (`ZeroMcp::Registry.create`, `RouteDefinition`, `ToolRegistry`)
  - `ruby/lib/zeromcp/openapi.rb` (`ZeroMcp::OpenApi.build`, extracted from `Server`)
  - `ruby/lib/zeromcp/credentials.rb` (`ZeroMcp::Credentials.resolve`, extracted from `Server`)
- Modified files:
  - `ruby/lib/zeromcp/server.rb` — `Server#initialize` gains `tools:` kwarg (backward compatible); `build_openapi_spec` and the three `_resolve_credentials*` methods become thin delegates to the new modules (or are deleted in favor of the extracted versions).
  - `ruby/lib/zeromcp/tool.rb` — add `Tool#route_method` / `Tool#route_path`.
  - `ruby/lib/zeromcp.rb` — add `require_relative 'zeromcp/registry'` (which itself requires `openapi` and `credentials`) and the `ZeroMcp.create_registry` top-level convenience, alongside the existing `ZeroMcp.serve` / `ZeroMcp.serve_http`.
- No new gem dependencies. `zeromcp.gemspec`'s `s.files = Dir['lib/**/*.rb'] + [...]` already globs the whole `lib/` tree, so the new files ship automatically with no gemspec edit needed — unlike Node, there is no subpath-export entry to add and no framework dependency (Hono-equivalent) to remove, because none was ever added on the Ruby side.
- Consumers use it as `require 'zeromcp'` then `ZeroMcp.create_registry(tools)` or `ZeroMcp::Registry.create(tools)` — same gem, same `require`, no separate import path (Ruby has no package-level subpath-export mechanism analogous to Node's `"./registry"` export map entry).

## Porting notes (Ruby-specific adaptations from the Node spec)

- **Keyword args over an options object.** Node's `RegistryOptions<TEnv>` now carries four fields — `getEnv?`, `title?`, `version?`, `executeTimeout?` (the latter three added after the initial as-built version, to fix hardcoded server metadata; see `specs/lang/nodejs/registry.md`'s "Fixed since the original as-built version"). Ruby's `getEnv` analog is `context_for` (see above), not a keyword arg, so it doesn't carry over to `Registry.create`'s options — but `title:`, `version:`, and `execute_timeout:` are plain metadata knobs with no Ruby-specific complication, and should be added as keyword arguments on `Registry.create` alongside `config:`, threaded into `Server#initialize`'s existing `Config#title`/executor-timeout handling the same way `serve`/`serve_http` already read them from `Config`. Left as a small addition for the implementer; not a design fork the way `getEnv` was.
- **No `getEnv` hook**, replaced by `ToolRegistry#context_for(tool)` — see Behavior above for the rationale (Ruby's `Context` is structured and credential-resolution-backed, not a free-form value like Node's `TEnv`).
- **Blocks, not lambdas, for `execute`.** `Tool#call` already takes `&block` at construction (`Tool.new(...) { |args, ctx| ... }`) — no change needed; `Registry.create` just receives pre-built `Tool` instances, it doesn't construct them.
- **`mcp` is a synchronous callable, not a `Promise`-returning function.** Ruby's entire dispatch stack (`Server#handle_request` → `#call_tool` → `Timeout.timeout { tool.call(args, ctx) }`) is blocking, single-threaded per call — there are no Fibers, no `async`/`await`, no event loop anywhere in `ruby/lib/zeromcp`. `registry.mcp.call(request)` blocks the calling thread for up to `tool.permissions[:execute_timeout] || config.execute_timeout` seconds (default 30s) if a tool call is slow, exactly like `Server#handle_request` does today for stdio/HTTP. A caller embedding `registry.mcp` inside a threaded server (Puma, Rails) gets normal thread-blocking behavior; a caller embedding it inside a fiber-scheduler-based server (e.g. Falcon) should be aware `Timeout.timeout` uses `Thread#raise` under the hood and does not yield to a fiber scheduler — this is pre-existing `Server` behavior, not something this spec introduces or fixes.
- **Struct, not a class, for the two new value types.** `RouteDefinition` and `ToolRegistry` are `Struct.new(..., keyword_init: true)` — plain data carriers matching Node's `interface`s, cheap to construct, no custom behavior needed beyond `ToolRegistry#context_for`.

## Open questions for the implementer

- Whether `OpenApi.build`/`Credentials.resolve` should be `module_function` (as sketched) or instance methods on small service objects — `module_function` matches the existing `Schema` module's style (`ruby/lib/zeromcp/schema.rb` is `module Schema; def self.to_json_schema...`) and is recommended for consistency, but this is a low-stakes style choice.
- Whether `ToolRegistry#context_for` should store `@config`/`@credential_cache` as hidden struct state (via a `Struct.new(...) do ... end` block, as sketched) or whether `Registry.create` should instead return a small dedicated class instead of a `Struct` once it needs behavior beyond field access — a `Struct` with an added method works fine in Ruby and is the minimal change, but if more behavior accretes later a plain class may be cleaner. Not a blocker either way.

## Fixed: existing `build_openapi_spec` had the same non-GET path-param bug as Node

Auditing all 10 languages for the Node bug above found the exact same bug already shipped in Ruby's own `build_openapi_spec` (`ruby/lib/zeromcp/server.rb:602`, pre-dating this registry spec entirely — it's used by `serve_http`'s `/openapi.json` route today, `server.rb:57-60`). For a non-GET route with a `:param` segment (e.g. `PUT /items/:id`), the `else` branch (`server.rb:627-629`, prior to this fix) called `build_openapi_request_body(input)`, which ran `Schema.to_json_schema` over *every* input field — including path-param ones — and never added a `parameters` array documenting them at all. `:id` was undocumented as a path parameter and silently duplicated into the JSON request body schema instead.

**Fixed directly** (not just specified) in `server.rb`:
- `build_openapi_request_body` (`server.rb:684-693`) now takes a second `path_param_names` argument and filters them out of `input` before calling `Schema.to_json_schema`, via `input.reject { |key, _| path_param_names.include?(key.to_s) }` — matching the file's existing convention of normalizing to string keys with `.to_s` when comparing against `path_param_names` (the same pattern `build_openapi_parameters` already used at line 659/669).
- The call site (`server.rb:625-639`) now also adds a `'parameters'` array to `operation` when `route_method != 'GET'` and `path_param_names` is non-empty, one entry per path param: `{ 'name' => name, 'in' => 'path', 'required' => true, 'schema' => { 'type' => 'string' } }` — the plain-string-type shape, not `input_field_to_openapi_schema`, since path segments are always strings regardless of the tool's declared input type (matching the plain-`{type: "string"}` choice already made in Swift's analogous fix).
- The GET branch (`build_openapi_parameters`, `server.rb:652-682`) is unchanged.

Verified with the existing Minitest suite (`ruby -Ilib -Itest test/test_server.rb`, all 26 runs/78 assertions green) plus a new `test_openapi_non_get_route_documents_path_param` case (`ruby/test/test_server.rb`) asserting a `PUT /items/:id` tool now gets `id` in `operation['parameters']` (`in: 'path'`, `required: true`) and excluded from `requestBody`'s JSON schema `properties`. Also manually booted `Server#serve_http` against `tests/conformance/route-tools` and confirmed `/openapi.json` is unchanged for the existing POST-with-no-path-param and GET-with-path-param fixtures.

This means the registry port's planned extraction of `build_openapi_spec` into `openapi.rb` (`OpenApi.build`, see "Packaging" above) now gets the corrected behavior for free — no divergent logic for the registry to carry.
