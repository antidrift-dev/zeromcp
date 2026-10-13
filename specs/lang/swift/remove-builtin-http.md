# Remove the built-in HTTP server — Swift

## Status
Not started. Spec only.

## Why
ZeroMCP doesn't own the HTTP layer. Users run whatever HTTP server they already have and wire ZeroMCP in. `createRegistry(_:options:)` (routes, OpenAPI, MCP handler as plain data, `Sources/ZeroMcp/Registry.swift:45-65`) and `ZeroMcp.handleRequest(_:)` (`Sources/ZeroMcp/Server.swift:109`) already cover that. `ZeroMcp.serveHttp(port:)` is a hand-rolled POSIX-socket server inside the library.

All paths below are under `swift/`.

## Remove
- `ZeroMcp.serveHttp(port:)`: socket/bind/listen/accept loop, port default 3000 (`Sources/ZeroMcp/HttpServer.swift:13-52`).
- Everything else in `HttpServer.swift` that only `serveHttp` reaches: `handlePosixConnection`, `readPosixRequest`, `HttpRequest`, `parseRequestLine`, `dispatchHttpRequest` (`/mcp`, `/health`, `/openapi.json`, `/docs`, tool route dispatch), `matchRoutePath`, `buildSwaggerHtml`, `jsonResponse`, `writePosixResponse` (CORS `*` header at `:353`), and the file-private `fputs` (`:364-370`). `Server.swift:558-564` has its own copy, so nothing else loses it.
- `HttpServer.swift` itself, once `buildOpenApiSpec` has moved out (see Keep).
- README `## HTTP / Streamable HTTP` intro, the `serveHttp(port: 3000)` example and the endpoint list (`README.md:35-57`), and the "You don't have to use `serveHttp`" sentence (`README.md:61`).

Not present in Swift, so nothing to remove: no CLI, no HTTP auth, no `host`/`port`/`transport` config fields (`Sources/ZeroMcp/Config.swift:3-20`), no HTTP-only dependencies (`Package.swift` declares no `dependencies:`).

## Keep
- `buildOpenApiSpec()` (`HttpServer.swift:224-302`) and its helper `extractPathParams(from:)` (`:304-315`). `createRegistry` calls it (`Registry.swift:62`). Move both, unchanged, into a new `Sources/ZeroMcp/OpenApi.swift` as an `extension ZeroMcp`; `buildOpenApiSpec` stays `internal`.
- `ZeroMcp.serve()` (stdio, `Server.swift:77-98`), `ZeroMcp.handleRequest(_:)`, `createRegistry` and its types.
- README `### Bring your own framework` and its Vapor example (`README.md:59-86`). Promote it to the `## HTTP` section and add a `createRegistry` example that mounts `registry.routes`, `registry.openapi` and `registry.mcp`, so it shows routes as well as `/mcp`.

## Config: fail on an `http` transport
Today a config asking for HTTP is silently ignored. Checked: `ZeroMcpConfig.load(from:)` on `{"title":"T","transport":[{"type":"http","port":3000}]}` returns `title=T` with no error (compiled `Config.swift` standalone with `swiftc`).

- Add an optional `transport` field to `ZeroMcpConfig`: an array of entries, each decoding only `type: String` (other keys ignored). This is the array form used by `tests/conformance/route-config-ruby.json` and `http-config-node.json`.
- Add an internal check that returns an error message when any entry has `type == "http"`, so it can be unit-tested without exiting.
- `serve()` runs the check first. On a hit, it writes this to stderr and calls `exit(1)`: `[zeromcp] The http transport was removed. Mount createRegistry(_:) (routes, openapi, mcp) in your own HTTP server.` No fallback to stdio. `stdio` entries, or no `transport` key, pass.

## Breaking change
`serveHttp` is public in the published 0.3.0 release. `git ls-remote --tags https://github.com/antidrift-dev/zeromcp-swift.git` lists `v0.3.0`. A clone of that tag has `public func serveHttp(port: UInt16 = 3000)` at `Sources/ZeroMcp/HttpServer.swift:13`. It is not in v0.2.2 or earlier (`git grep 'func serveHttp' v0.2.2 -- swift/` finds nothing). Removing it breaks callers. Note it in the next release's changelog with the one-line replacement: mount `createRegistry(_:)` in your own server.

## Tests
- Unit tests: none exercise the built-in server (`grep -n -i "openapi\|serveHttp\|swagger" Tests/ZeroMcpTests/*.swift` hits only `RegistryTests.swift:41-45`, which goes through `createRegistry` and stays). Nothing to delete or move.
- Add unit tests for the transport check: `http` entry → error message naming `createRegistry`; `stdio` entry → nil; no `transport` key → nil.
- Route conformance: `Sources/RouteTest/main.swift:25` calls `server.serveHttp(port: 14258)`, and `tests/conformance/run-route.js:82-89` runs that binary (`/usr/local/bin/zeromcp-swift-route`, copied by `Dockerfile:88`). Rewrite `RouteTest/main.swift` as a test-only harness:
  - Build the same two tools (`greet` GET `/greet/:name`, `echo` POST `/echo`) as a `[String: ToolDefinition]` map and call `createRegistry`.
  - Serve them on port 14258 with a small POSIX-socket listener in the `RouteTest` target (Glibc/Darwin only, no new package dependency). The socket, request-parsing, path-matching and response-writing code removed from `HttpServer.swift` can move here.
  - Endpoints: `POST /mcp` → `registry.mcp`. `GET /openapi.json` → `registry.openapi`. Each `registry.routes` entry → `route.tool.execute`, returning `{ok, result}` (`run-route.js:148,156`). The harness also serves `GET /health`, polled for readiness (`run-route.js:104`), and a static Swagger HTML page at `GET /docs`, asserted at `run-route.js:172-178`. Both are harness-only now.
  - Binary name, port, `Package.swift` product and the `Dockerfile:88` copy line stay as they are.
- No other test infra launches Swift's HTTP server. `tests/conformance/run-http.js` has no Swift entry. `tests/chaos/run-chaos.js:435-440` runs `ChaosTest` over stdio. `tests/performance/run-mixed-docker.mjs:122-127` and `run-mixed-all.mjs:126-131` run the Swift resource test over stdio. `tests/performance/Dockerfile:76-78` builds only `zeromcp-resource-test`. No change to any of these.
- Unverified: `tests/performance/run-zeromcp-overnight.sh:82-85` and `rerun-zeromcp-cold-tiers.sh:70-72` start `/bench/server-vapor` from image `zeromcp-bench-http-vapor`. Its source is not in this repo, so whether it calls `serveHttp` is unchecked.

## Verify
```sh
docker build -t zeromcp-tests .
docker run --rm zeromcp-tests sh -c 'cd swift && swift build && swift test'
docker run --rm zeromcp-tests node tests/conformance/run-all.js --language "Swift"
docker run --rm zeromcp-tests node tests/conformance/run-route.js
grep -rn -E 'serveHttp|socket\(|bind\(|listen\(|accept\(' swift/Sources/ZeroMcp swift/README.md   # expect nothing
test ! -e swift/Sources/ZeroMcp/HttpServer.swift
```
