# Remove the built-in HTTP server — Ruby

## Status
Done (2026-10-13). Docker: Ruby unit suite 167 runs / 0 failures; Ruby conformance suites all pass; Route + OpenAPI Ruby 5/5 via `tests/conformance/harness/ruby/route-harness.rb`; `grep -rni webrick ruby/lib` is empty.

## Why
ZeroMCP doesn't own the HTTP layer. Users run whatever HTTP server they already have and wire ZeroMCP in. `ZeroMcp::Registry` (routes, OpenAPI, MCP handler as plain data) and `Server#handle_request` already cover that. The built-in WEBrick server is the one piece that pulls an HTTP stack into the gem.

## Remove
- `Server#serve_http` (`ruby/lib/zeromcp/server.rb:36-85`).
- Private helpers used only by it: `require_webrick`, `register_tool_route`, `route_path_prefix`, `extract_path_params`, and the `# --- HTTP route helpers ---` block they sit in.
- `Server#build_openapi_spec`: its only caller is `serve_http` (`server.rb:61`). `Registry` builds OpenAPI itself.
- `ZeroMcp.serve_http` (`ruby/lib/zeromcp.rb:13-17`).
- The `ZeroMcp.serve_http` / webrick line in `ruby/README.md` (HTTP section).
- `ruby/test/test_webrick_optional.rb`. Once nothing in `lib` mentions webrick, there is nothing for it to test.
- `test_server.rb:328`: the test that calls `send(:build_openapi_spec)`. Keep it only if its assertions aren't already covered by `test_registry.rb`'s OpenAPI tests; otherwise delete it.

## Keep
- `Server#serve` (stdio), `Server#handle_request`, `Registry.create` / `ZeroMcp.create_registry`.
- README's "bring your own framework" HTTP section and its Sinatra example. Switch the example to `Registry.create` if it isn't already, so it shows the routes as well as `/mcp`.

## Breaking change
`serve_http` is in the published 0.3.0 gem (rubygems.org lists 0.3.0). Removing it breaks anyone who calls it. Note it in the next release's changelog with the one-line replacement: mount `ZeroMcp.create_registry` in your own server.

## Tests
- Full Ruby suite still passes with the removed tests gone.
- Ruby's route conformance entry (`tests/conformance/run-route.js:33-38`) starts `bin/zeromcp serve` with `route-config-ruby.json`, which asks for an `http` transport. Replace it with a small harness script under `tests/conformance/` that mounts `ZeroMcp.create_registry` routes and `/mcp` on WEBrick, the way `tests/performance/run-mixed-docker.mjs:83-87` already wraps Ruby. WEBrick is a dependency of the test harness only, not the gem.

## Verify
```sh
docker build -t zeromcp-tests .
docker run --rm zeromcp-tests sh -c 'cd ruby && ruby -I lib -I test -e '"'"'Dir["test/**/test_*.rb"].each { |f| require File.expand_path(f) }'"'"''
docker run --rm zeromcp-tests node tests/conformance/run-all.js --language "Ruby"
docker run --rm zeromcp-tests node tests/conformance/run-route.js
grep -rn -i webrick ruby/lib   # expect nothing
```
