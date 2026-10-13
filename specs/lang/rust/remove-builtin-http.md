# Remove the built-in HTTP server — Rust

## Status
Not started. Spec only.

## Why
ZeroMCP doesn't own the HTTP layer. Users run whatever HTTP server they already have and wire ZeroMCP in. `zeromcp::registry::create_registry` (routes, OpenAPI, MCP handler as plain data) and `Server::handle_request` already cover that. `Server::serve_http` is the one piece that runs its own listener inside the crate.

## Remove
All in `rust/src/server.rs` unless noted.
- `Server::serve_http` and its doc comment (`server.rs:166-181`): the `TcpListener` bind and accept loop.
- The `// HTTP connection handler` block (`server.rs:737-812`): `handle_http_conn`, which serves `/health`, `/openapi.json`, `/docs` (Swagger HTML), `POST /mcp`, the 404 fallback, and the `Access-Control-Allow-Origin: *` header. There is no bearer auth, port default or host setting to remove; the address is the caller's `addr` argument.
- `use tokio::net::TcpListener;` (`server.rs:11`). Its only user is `serve_http`.
- The `Server::serve_http` sentence in the `registry.rs` module doc (`registry.rs:3`). Rewrite lines 3-7 to say the registry is how you mount tools in your own HTTP server. In the `ctx_for` doc (`registry.rs:49`), drop "or the built-in HTTP server".

## Keep
- `Server::serve` (stdio), `Server::handle_request`, and `create_registry` / `Registry` / `Registry::ctx_for`.
- `Server::build_openapi` (`server.rs:612`) stays where it is. `create_registry` calls it (`registry.rs:73`), so it is registry code now, not server code. Its unit test `build_openapi_put_route_documents_path_param_separately` (`server.rs:1685`) stays.
- `Config::title` (`config.rs:27-29`): `build_openapi` still reads it.
- `rust/Cargo.toml`: no change. The only HTTP-specific thing in it is tokio's `net` feature, which comes in through `features = ["full"]` (`Cargo.toml:17`). The route harness below needs `net`, and examples get the crate's dependencies, so leave the feature list alone.
- README "HTTP / Streamable HTTP" section (`rust/README.md:53-77`). It already shows bring-your-own (Axum + `handle_request`) and never mentions `serve_http`. Add a short `create_registry` example next to it so it shows the routes and `openapi` as well as `/mcp`.

## Startup error for an `http` transport
Rust has no CLI and `Config` has no `transport` field (`config.rs:6-30`). `Config` has no `deny_unknown_fields`, so today `load_config` (`config.rs:63-78`) silently ignores `"transport": [{ "type": "http", ... }]` and the caller carries on with stdio. That is the silent fallback the decision rules out.

Change `load_config`: parse the file into a `serde_json::Value` first. If `transport` is an object with `"type": "http"`, or an array containing one, panic. A panic matches how the crate fails at startup today (`serve_http`'s bind panic, `server.rs:170`) and doesn't change `load_config`'s or `Server::from_config`'s return types. Message:

```
[zeromcp] "transport" type "http" is not supported: ZeroMCP no longer ships an HTTP server. Mount zeromcp::registry::create_registry (routes, openapi, mcp) or Server::handle_request in your own HTTP server.
```

`stdio` entries, and configs with no `transport`, load as they do now. Then deserialize the `Value` into `Config` as today. A file that isn't valid JSON keeps the current warn-and-default behavior.

## Breaking change
`serve_http` is in the published 0.3.0 crate. The crates.io API lists 0.3.0 (2026-08-06), and the downloaded `zeromcp-0.3.0.crate` has `pub async fn serve_http` at `src/server.rs:168`. 0.2.2 doesn't have it. Removing it breaks anyone who calls it. A config with an `http` transport, silently ignored today, will now panic in `load_config`. Put both in the next release's changelog with the replacement: mount `zeromcp::registry::create_registry` in your own server.

## Tests
- No unit test exercises `serve_http` or `handle_http_conn`. `grep` turns up nothing in `src/` tests or `rust/tests/integration.rs`, so there is nothing to delete or move.
- New unit tests in `config.rs`: `#[should_panic(expected = "create_registry")]` for `transport` as an array with an `http` entry and as a single `http` object. Also check that a `[{ "type": "stdio" }]` transport loads without panicking.
- `rust/examples/route_test.rs` is the only caller of `serve_http` (`route_test.rs:50`). Route conformance runs it (`tests/conformance/run-route.js:56-62`, port 14255), and the root `Dockerfile:76` builds it. Rewrite it as a test-only harness. Keep the file name so `run-route.js` and `Dockerfile` don't change:
  - Build the same `greet` (`GET /greet/:name`) and `echo` (`POST /echo`) tools with `create_registry`.
  - Serve on `0.0.0.0:14255` with a small `tokio::net::TcpListener` loop in the example. No new dependencies.
  - `GET /health` returns `{"status":"ok"}`, because `run-route.js:102` polls it for readiness.
  - `GET /openapi.json` returns `registry.openapi`.
  - `GET /docs` returns a static Swagger UI page, so `run-route.js` Test 4 passes unchanged.
  - `POST /mcp` calls `(registry.mcp)(body)`.
  - For each `registry.routes` entry, match the method and `:param` segments, build args from the path params plus the JSON body (non-GET), call `(route.tool.execute)(args, registry.ctx_for(&route.tool))`, and return `{"ok":true,"result":...}`. That is the shape `run-route.js` Tests 1-2 check.
- Chaos and performance need no change. Rust's entries there run stdio examples: `chaos_test` (`run-chaos.js:406-411`, `chaos_test.rs:101` calls `serve()`) and `resource_test` (`run-mixed-all.mjs:108-111` `stdio: true`, `run-mixed-docker.mjs:105-108` `stdio` + `skip`, `tests/performance/Dockerfile:74`). `run-http.js` has no Rust entry.

## Verify
```sh
docker build -t zeromcp-tests .
docker run --rm zeromcp-tests sh -c 'cd rust && cargo build && cargo test && cargo clippy --all-targets'
docker run --rm zeromcp-tests node tests/conformance/run-all.js --language "Rust"
docker run --rm zeromcp-tests node tests/conformance/run-route.js   # Rust line: 5/5
grep -rn "TcpListener\|serve_http\|handle_http_conn\|swagger" rust/src   # expect nothing
```
