# Remove the built-in HTTP server — Go

## Status
Not started. Spec only.

## Why
ZeroMCP doesn't own the HTTP layer. Users run whatever HTTP server they already have and wire ZeroMCP in. `(*Server).Registry()` (`go/pkg/zeromcp/registry.go:33`: `Routes`, `OpenAPI`, `MCP` as plain data) and `(*Server).HandleRequestBytes` / `HandleRequest` (`server.go:457`, `server.go:487`) already cover that. The built-in `net/http` server inside `Serve()` is the one piece where ZeroMCP binds a port itself.

## Remove
All in `go/pkg/zeromcp/` unless noted.

- `serveHTTP` (`server.go:306-430`): the listener (`http.ListenAndServe`, `:427`), `/health` (`:311`), `/openapi.json` (`:327`), `/docs` Swagger HTML (`:341`), `/mcp` with the bearer check (`:368-403`), the `/` catch-all that does tool route dispatch and the 404 body (`:405-424`).
- HTTP helpers used only by `serveHTTP` / `handleToolRoute`: `setCORS` (`server.go:432-436`), `writeCORS` (`:438-441`), `readBody` (`:443-446`), `httpJSON` (`:448-452`).
- `handleToolRoute` and its `// --- Route dispatch ---` header (`server.go:916-972`). Its only caller is `serveHTTP` (`:413`).
- `matchRoutePath` (`server.go:1125-1143`). Its only caller is `handleToolRoute` (`:932`).
- The `"io"` and `"net/http"` imports in `server.go` (`:9-10`). grep shows no other use of `io.` or `http.` in `server.go` outside the code above.
- In `Serve()` (`server.go:247-273`): the `hasHTTP` loop (`:249-254`) and the `case "http"` branch with the 4242 port default (`:260-265`).
- The `httpAlso bool` parameter of `serveStdio` (`server.go:281`) and the `if !httpAlso` guard (`:301-303`). Stdio EOF always exits 0. Update both callers (`:259`, `:278`).
- `TransportConfig.Port` and `TransportConfig.Auth` (`config.go:27-28`). `Type` stays.
- `ResolveAuth` (`config.go:121-135`). Its only non-test caller is `serveHTTP` (`server.go:307`).
- Tests for `ResolveAuth`: `TestResolveAuthEnv` (`config_test.go:43`) and `TestResolveAuthLiteral` (`config_test.go:53`). They test only the removed function. Delete them.
- `go/examples/advanced/zeromcp.config.json:4`: the `{ "type": "http", "port": 4242 }` entry. With the startup error below, the example would exit on this config. Also drop "HTTP transport" from the header comment (`go/examples/advanced/main.go:1`).
- `go/README.md`:
  - "HTTP routes & OpenAPI docs" (`:79-96`). It says a routed tool becomes an endpoint "on the `http` transport" and that "the server also serves `/openapi.json` ... and `/docs`". Rewrite it to show `reg := s.Registry()`, mounting `reg.Routes` on a `net/http` `ServeMux`, serving `reg.OpenAPI` at `/openapi.json` and `reg.MCP` at `POST /mcp`. Drop the `/docs` claim and the `{"ok": ...}` envelope sentence, which described `handleToolRoute`.
  - "Configuration" (`:153-156`): drop the `{ "type": "http", "port": 4242 }` line.

## Keep
- `Serve()` (stdio only), `ServeStdio()`, `HandleRequestBytes`, `HandleRequest`, `Registry()`, `RouteConfig`, `Tool.Route`.
- `buildOpenAPISpec` (`server.go:975-1107`) and `fieldDefToOpenAPISchema` (`server.go:1110-1123`). `Registry()` uses `buildOpenAPISpec` (`registry.go:62`). They're already standalone methods outside `serveHTTP`, so they stay in `server.go` unchanged. The `"regexp"` import stays (`buildOpenAPISpec` `:1000`, `matchTemplate` `:1198-1208`).
- `ResolveTransports` (`config.go:62-83`) and `TestResolveTransportsDefault` (`config_test.go:36`).
- `go/README.md` "HTTP / Streamable HTTP" (`:47-77`), the bring-your-own-`net/http` example around `HandleRequest`. Add one line pointing to `Registry()` for routes and OpenAPI.
- `go/cmd/zeromcp/main.go`: it has no HTTP flags or subcommands (`:37-51`, help text `:94-108`). It calls `srv.Serve()` (`:71`), so an `http` transport in the config file hits the startup error below. No change.
- `go.mod` has no `require` entries, so there are no dependencies to remove. `sandbox.go` imports `net/http` for `Ctx.Fetch`; that stays.

## Startup error
Add `checkTransports(cfg Config) error` in `config.go`, next to `ResolveTransports`. If any entry from `ResolveTransports(cfg)` has `Type == "http"`, it returns:

```
[zeromcp] The built-in "http" transport was removed. Mount (*Server).Registry() in your own HTTP server: Routes for tool routes, OpenAPI for /openapi.json, MCP for POST /mcp. Remove the "http" entry from "transport".
```

`Serve()` calls it first, before any transport starts. On error it writes the message to stderr and calls `os.Exit(1)`. There is no fallback to stdio. The config-file path (`cmd/zeromcp`) and the in-code path (`Config{Transport: []TransportConfig{{Type: "http"}}}`) both go through `Serve()`, so this one check covers both.

## Breaking change
proxy.golang.org lists `github.com/antidrift-dev/zeromcp-go` v0.1.0 through v0.3.0 (`/@v/list`). The v0.3.0 module zip has `serveHTTP` at `pkg/zeromcp/server.go:306` and the `case "http"` branch at `:260`. It also has `pkg/zeromcp/registry.go`, so the replacement already ships in 0.3.0.

What breaks:
- An `http` transport, from a config file or from `Config.Transport`, now exits at startup instead of serving.
- `TransportConfig{Port: ..., Auth: ...}` and `ResolveAuth` no longer compile.

Note it in the next release's changelog with the one-line replacement: mount `s.Registry()` in your own `net/http` server.

## Tests
- Add a unit test for `checkTransports` in `config_test.go`:
  - an `http` single object, and `http` inside an array, each return the error;
  - `stdio` and the default (nil `Transport`) return nil.
- No unit test calls `serveHTTP`, `handleToolRoute` or `matchRoutePath` (grep across `go/`). Nothing else to delete. Arg building and invocation are covered by `TestRegistryInvokeCallsToolWithResolvedContext` (`registry_test.go:64`). The HTTP side (path params, query/body merge, response envelope) moves to the harness below and is exercised by the route conformance tests.
- `TestBuildOpenAPISpecNonGETPathParam` (`server_test.go:562`) stays, because `buildOpenAPISpec` stays.
- Route conformance:
  - Today Go's entry (`tests/conformance/run-route.js:48-55`, port 14254) runs `zeromcp-go-route`. The root `Dockerfile:73` builds that binary from `go/examples/route-test`, which calls `Serve()` with an `http` transport (`go/examples/route-test/main.go:14`, `:39`).
  - Rewrite `go/examples/route-test/main.go` as a test-only harness. Keep the same two tools, call `s.Registry()`, and serve on `:14254` with a stdlib `http.ServeMux`:
    - `/health`;
    - `GET /openapi.json` returning `reg.OpenAPI`;
    - `GET /docs` returning a Swagger UI HTML page;
    - `POST /mcp` returning `reg.MCP(body)`;
    - one handler per `reg.Routes` entry. Register each as a Go 1.22 method+path pattern, rewriting `:name` to `{name}`. Build args from `r.PathValue`, plus query params on GET or the JSON body otherwise. Respond `{"ok":true,"result":...}` / `{"ok":false,"error":...}`.
  - `/docs` is served only because `run-route.js` test 4 checks for it. It is harness code, not library behavior.
  - Binary name, port and Dockerfile line are unchanged, so `run-route.js` and `Dockerfile` don't change.
- HTTP auth conformance:
  - Go's entry in `tests/conformance/run-http.js:26-33` runs `zeromcp-go-advanced` with `tests/conformance/http-config-go.json` (an `http` transport with `auth`). It tests bearer 401s and CORS preflight, which are no longer ZeroMCP behavior.
  - Remove the Go entry and delete `http-config-go.json` (its only reference is `run-http.js:29`).
  - MCP-over-HTTP for Go stays covered by `run-route.js` test 5 (`POST /mcp tools/list`) through the harness.
  - Keep `Dockerfile:70` (`zeromcp-go-advanced`) as a build check of the example.
- Checked and not affected:
  - `tests/chaos/run-chaos.js:393-394` runs `chaos-test`, which calls `ServeStdio()` (`go/examples/chaos-test/main.go:73`).
  - The Go entries in `tests/performance/run-mixed-docker.mjs:77-78` and `run-mixed-all.mjs:89-93` run `resource-test`, which calls `ServeStdio()` (`go/examples/resource-test/main.go:79`) and doesn't start the built-in server.
  - `tests/performance/Dockerfile:71` builds only `resource-test`.

## Verify
```sh
docker build -t zeromcp-tests .
docker run --rm zeromcp-tests sh -c 'cd go && go build ./pkg/... ./cmd/... && go vet ./pkg/... && go test ./pkg/...'
docker run --rm zeromcp-tests node tests/conformance/run-all.js --language "Go"
docker run --rm zeromcp-tests node tests/conformance/run-route.js   # Go line must read "5/5 passed", not "skipped" (optional entries that fail to start are reported as skipped, run-route.js:135-137)
docker run --rm zeromcp-tests sh -c 'cd /tmp && echo "{\"transport\":{\"type\":\"http\"}}" > zeromcp.config.json && zeromcp-go-cli; echo exit=$?'   # expect the "was removed" message and exit=1
grep -rn -E 'ListenAndServe|NewServeMux|serveHTTP|handleToolRoute|matchRoutePath|ResolveAuth|Access-Control' go/pkg go/cmd   # expect nothing
```
