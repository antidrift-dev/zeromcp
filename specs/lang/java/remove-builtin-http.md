# Remove the built-in HTTP server — Java

## Status
Done (2026-10-13). Docker: `mvn test` 108/108 (incl. http-transport startup error); route suite Java 5/5 via the rewritten `RouteTest` registry harness (was 3/5); other Java conformance suites unchanged; grep for httpserver/serveHttp/port() in `java/src/main` is empty.

## Why
ZeroMCP doesn't own the HTTP layer. Users run whatever HTTP server they already have and wire ZeroMCP in. `ZeroMcp.registry()` (routes, OpenAPI, MCP handler as plain data) and `ZeroMcp.handleRequest(JsonObject)` already cover that. `serveHttp` is the one piece that runs ZeroMCP's own listener (JDK `com.sun.net.httpserver.HttpServer`).

## Remove
All in `java/src/main/java/io/antidrift/zeromcp/ZeroMcp.java` unless noted.
- `serveHttp(int port)` and its javadoc (`ZeroMcp.java:125-252`): the `HttpServer` listener, `/mcp`, `/openapi.json`, `/docs` (Swagger HTML), per-route contexts, cached-thread-pool executor, block-until-interrupted loop.
- `serveHttp()` (`ZeroMcp.java:254-259`).
- Private helpers used only by `serveHttp`: `sendHttpResponse` (`:261-268`), `matchPathParams` (`:270-285`), `parseQueryString` (`:287-303`). Grep shows no other callers (`:206`, `:212`, and the `sendHttpResponse` calls at `:140-236` are all inside `serveHttp`).
- Imports used only by the above: `com.sun.net.httpserver.HttpExchange` (`:4`), `com.sun.net.httpserver.HttpServer` (`:5`), `java.io.IOException` (`:8`), `java.net.InetSocketAddress` (`:10`), `java.net.URLDecoder` (`:11`).
- `Config.port` field and `port()` accessor (`Config.java:16`, `:36`). Its only reader is `serveHttp` (`ZeroMcp.java:134`).
- `{@link #serveHttp}` in the `registry()` javadoc (`ZeroMcp.java:93-95`) and `{@link ZeroMcp#serveHttp}` in `Registry.java:9`. Both would point at a removed method. Reword to "your own HTTP server".
- `java/README.md:39-50`: the "built-in HTTP server" paragraph and its `server.serveHttp(4242)` example.

Not present in Java, nothing to remove: CORS, `/health`, HTTP bearer auth (`grep -rni 'bearer\|authorization\|access-control\|cors\|/health' java/src java/example` finds nothing), and a CLI (no `main` in the library package; the only `main` under `java/src/main` is `ResourceTest.java:11`, a test harness). No manifest change: `com.sun.net.httpserver` is JDK, and `java/pom.xml` has only gson and junit (test).

## Keep
- `serve()` (stdio), `handleRequest(JsonObject)`, `registry()`, `routeDefinitions()` (`ZeroMcp.java:101-109`).
- `buildOpenApiSpec()` (`ZeroMcp.java:308`) stays where it is. `registry()` calls it (`ZeroMcp.java:98`); after the removal that is its only caller.
- `jsonObjectToMap` (`ZeroMcp.java:846`): also used by `callTool` (`:575`) and prompts (`:731`).
- `Config.transport` (`Config.java:15`, `:35`): kept so the startup check below can read it.
- README "bring your own framework" section and its Javalin example (`java/README.md:52-75`). Rename the section from "HTTP / Streamable HTTP" to make clear it is bring-your-own, and add a short `server.registry()` example (routes, `openapi()`, `mcp().handle(...)`) next to the existing `handleRequest` one.

## Startup error
`serve()` (`ZeroMcp.java:414`) does not read `config.transport()` today (grep: no caller of `transport()` in `java/src/main`). Add a check at the top of `serve()`: if `config.transport()` is anything other than `"stdio"`, throw `IllegalStateException` with a message that says ZeroMCP no longer ships an HTTP server and to mount `ZeroMcp.registry()` (or `handleRequest(JsonObject)`) in your own HTTP server. No fallback to stdio.

## Breaking change
`serveHttp` is in the published 0.3.0 artifact. `https://repo1.maven.org/maven2/dev/antidrift/zeromcp/maven-metadata.xml` lists 0.1.0, 0.1.1, 0.2.0, 0.2.2, 0.3.0 (latest 0.3.0). The 0.3.0 sources jar has both `public void serveHttp` overloads; 0.1.0 through 0.2.2 have none. `Config.port()` is public in every published version, from 0.1.0 on. Removing both breaks callers. Note it in the next release's changelog with the one-line replacement: mount `server.registry()` in your own HTTP server.

## Tests
- Unit tests: none call `serveHttp` (`grep -rn serveHttp java/src/test` finds nothing). OpenAPI generation is already covered through the registry (`RegistryTest.java:57`, `openapiMatchesRoutedTools`).
- `ConfigTest.java:13` asserts `config.port()`. Delete that line.
- Add a test: a config file in a JUnit `@TempDir` with `{"transport":"http"}`, loaded with `Config.load(dir)`; `new ZeroMcp(config).serve()` throws `IllegalStateException` whose message names `registry()`.
- Route conformance: `tests/conformance/run-route.js:65-73` runs `RouteTest`, which calls `server.serveHttp(14256)` (`java/example/src/main/java/RouteTest.java:24`). Rewrite `RouteTest.java` in place as a test-only harness: same two tools, then `server.registry()` mounted on a JDK `HttpServer` at port 14256 that serves `/mcp` (via `registry.mcp().handle`), `/openapi.json` (`registry.openapi()`), `/docs` (a minimal Swagger HTML page, which `run-route.js:172-178` checks for), and each `registry.routes()` entry (path params, query string or JSON body into args, then `route.tool().executor().execute(args, new Ctx(...))`, response `{ok, result}`). The path/query parsing that leaves the library moves into this harness. The file keeps its name and path, so `Dockerfile:104` and `run-route.js:65-73` need no change.
- Pass bar for the route suite: no regression. In the `zeromcp-tests` image built 2026-10-13T17:51Z, `node tests/conformance/run-route.js` gives Java 3/5 (fails `GET /greet/World` with 404 and `POST /echo` with a stringified `result`).
- Chaos and performance need nothing. Java runs over stdio there: `run-chaos.js:428-430` (ChaosTest, `serve()`), `run-mixed-all.mjs:114-123` (ResourceTest), and `run-mixed-docker.mjs:111-115` (`skip: true`). No Java entry in `run-http.js` or in any `http-config-*.json`.

## Verify
```sh
docker build -t zeromcp-tests .
docker run --rm zeromcp-tests sh -c 'cd java && mvn test'
docker run --rm zeromcp-tests node tests/conformance/run-all.js --language "Java"
docker run --rm zeromcp-tests node tests/conformance/run-route.js
grep -rnE 'httpserver|InetSocketAddress|serveHttp|\bport\(\)' java/src/main   # expect nothing
```
