# ZeroMCP &mdash; Ruby

Drop a `.rb` file in a folder, get a sandboxed MCP server. Stdio out of the box, zero dependencies.

## Getting started

```ruby
# tools/hello.rb — this is a complete MCP server
tool description: "Say hello to someone",
     input: { name: "string" }

execute do |args, ctx|
  "Hello, #{args['name']}!"
end
```

```sh
ruby -I lib bin/zeromcp serve ./tools
```

That's it. Stdio works immediately. Drop another `.rb` file to add another tool. Delete a file to remove one.

## vs. the official SDK

The official Ruby SDK requires server setup, transport configuration, and explicit tool registration. ZeroMCP is file-based &mdash; each tool is its own file, discovered automatically. Zero external dependencies.

In benchmarks, ZeroMCP Ruby handles 15,327 requests/second over stdio versus the official SDK's 12,935 &mdash; 1.2x faster with 50% less memory (12 MB vs 24 MB). Over HTTP (Rack+Puma), ZeroMCP serves 3,217 rps at 26 MB versus the official SDK's 2,163 rps at 49&ndash;56 MB. The official SDK crashed on binary garbage input and corrupted responses under slow tools in chaos testing. ZeroMCP survived 22/22 attacks.

The official SDK has **no sandbox**. ZeroMCP lets tools declare network, filesystem, and exec permissions.

Ruby passes all 10 conformance suites.

## HTTP / Streamable HTTP

ZeroMCP doesn't own the HTTP layer and ships no HTTP server. You mount it in the framework you already run. `ZeroMcp.create_registry` gives you everything as plain data:

- `registry.routes`: one entry per tool with a `route:` (`name`, `method`, `path`, `tool`)
- `registry.openapi`: an OpenAPI 3.0 document (a Hash) for the routed tools
- `registry.mcp`: a callable that takes a JSON-RPC Hash and returns a response Hash (or `nil` for notifications)
- `registry.context_for(tool)`: a ready-made `ctx` (credentials, permissions, runtime) for calling a routed tool yourself

A config with an `http` transport now fails at startup and points you here.

**Sinatra**

```ruby
require 'sinatra'
require 'json'
require 'zeromcp'

config = ZeroMcp::Config.load
tools = ZeroMcp::Scanner.new(config).scan
registry = ZeroMcp.create_registry(tools, config: config)

# MCP over HTTP
post '/mcp' do
  response = registry.mcp.call(JSON.parse(request.body.read))
  halt 204 if response.nil?
  content_type :json
  response.to_json
end

# OpenAPI
get '/openapi.json' do
  content_type :json
  registry.openapi.to_json
end

# One HTTP route per routed tool. Sinatra uses the same :param syntax.
registry.routes.each do |route|
  send(route.method.downcase, route.path) do
    body = request.body.read
    args = request.GET.merge(body.empty? ? {} : JSON.parse(body))
    args = args.merge(params.slice(*route.path.scan(/:(\w+)/).flatten))
    result = route.tool.call(args, registry.context_for(route.tool))
    content_type :json
    { ok: true, result: result }.to_json
  end
end
```

`Server#handle_request` is still there if you only need `/mcp`: `server = ZeroMcp::Server.new(config); server.load_tools; server.handle_request(hash)`.

## Runtime context

Pass `get_runtime:` to hand your tools something from your app (a DB handle, the current request's user). It is called on every local tool execution, and its return value is `ctx.runtime`:

```ruby
registry = ZeroMcp.create_registry(tools, get_runtime: -> { { db: DB } })
# or: ZeroMcp::Server.new(config, get_runtime: -> { { db: DB } })

# tools/report.rb
execute do |args, ctx|
  ctx.runtime[:db].query(args['sql'])
end
```

Without `get_runtime:`, `ctx.runtime` is `nil`. Remote tools never call it.

## Remote servers

ZeroMCP can federate other MCP servers over HTTP. Their tools appear as `<name>.<tool>`; a local tool with the same name wins.

```json
{
  "tools": "./tools",
  "remote": [
    { "name": "probeo", "url": "https://mcp.example.com/mcp", "auth": "env:PROBEO_TOKEN", "tools": ["list_pages"] }
  ]
}
```

`auth` is sent as `Authorization: Bearer <token>`; `env:VAR` reads it from the environment. `tools` is an optional allowlist of upstream tool names. A server that fails to connect is logged and skipped. The registry takes the same list: `ZeroMcp.create_registry(tools, remote: [...])` (it connects before returning). Remote tools have no route, so they are served from `mcp` only.

## Hot reload

Set `"autoload_tools": true` and `zeromcp serve` polls the tool directories once a second. When a `.rb` file is added or changed it rescans, loads the new tools, and sends `notifications/tools/list_changed` over stdio. Removed files keep their tools until restart.

## Tool sources and namespacing

`tools` takes a path, or an array of paths and `{ "path": ..., "prefix": ... }` entries. A prefix is prepended to every tool from that source:

```json
{
  "tools": ["./tools", { "path": "./vendor/github-tools", "prefix": "gh" }],
  "namespacing": { "math": { "prefix": "m" } }
}
```

`namespacing` renames a subdirectory's prefix (`math/add.rb` becomes `m_add`; `""` drops it). Credentials stay keyed by the directory name. `resources` and `prompts` accept the same entry shapes.

`icon` accepts a data URI, a file path, or an `http(s)` URL.

## Requirements

- Ruby 3.0+
- No external dependencies

## Install

```sh
gem build zeromcp.gemspec
gem install zeromcp-0.2.2.gem
```

## Sandbox

```ruby
tool description: "Fetch from our API",
     input: { url: "string" },
     permissions: {
       network: ["api.example.com", "*.internal.dev"],
       fs: false,
       exec: false
     }

execute do |args, ctx|
  # ...
end
```

## Directory structure

Tools are discovered recursively. Subdirectory names become namespace prefixes:

```
tools/
  hello.rb          -> tool "hello"
  math/
    add.rb          -> tool "math_add"
```

## Testing

The tests use WEBrick for fake upstream servers (`gem 'webrick'`, in the Gemfile's test group). The gem itself doesn't need it.

```sh
ruby -I lib -I test -e 'Dir["test/**/test_*.rb"].each { |f| require_relative f }'
```
