# Remove the built-in HTTP server — Kotlin

## Status
Done (2026-10-13). Docker `gradle test`: 93 tests, 0 failures (OpenApiSpecTest folded into RegistryTest, transport-error cases in ConfigTest); route conformance via the RouteTest registry harness: Kotlin 5/5 (was skipped).

## Why
ZeroMCP doesn't own the HTTP layer. Users run whatever HTTP server they already have and wire ZeroMCP in. `ZeroMcp.registry()` (routes, OpenAPI, MCP handler as plain data, `Server.kt:69-81`) and `ZeroMcp.handleRequest` (`Server.kt:270`) already cover that. `serveHttp` is the one piece that runs an HTTP server inside the library.

## Remove
All in `kotlin/src/main/kotlin/io/antidrift/zeromcp/Server.kt` unless noted:
- `serveHttp(port: Int = config.port)` and its KDoc (`Server.kt:140-215`). This covers the `com.sun.net.httpserver.HttpServer` listener, `/mcp`, `/openapi.json`, `/docs` (Swagger HTML) and the `/` catch-all for tool routes. There is no `/health` context and no HTTP bearer auth in the Kotlin server.
- `handleToolRoute(exchange)` (`Server.kt:217-258`). Its only caller is `serveHttp` (`Server.kt:206`).
- The `// --- HTTP helpers ---` block: `setCors`, `writeCors`, `httpJson` (`Server.kt:582-600`). They're only called from `serveHttp` and `handleToolRoute`.
- `buildOpenApiSpec(...): String` (`Server.kt:604-606`). Its only caller is `serveHttp` (`Server.kt:173`).
- The `// --- Route matching ---` block: `matchRoutePath` (`Server.kt:701-717`). Its only caller is `handleToolRoute` (`Server.kt:224`).
- Imports: `com.sun.net.httpserver.HttpExchange`, `com.sun.net.httpserver.HttpServer`, `java.net.InetSocketAddress` (`Server.kt:3,4,10`).
- `ZeroMcpConfig.port` (`Config.kt:10`). Its only reader is the `serveHttp` default (`Server.kt:144`). Old config files that still carry `port` keep parsing because the config `Json` has `ignoreUnknownKeys = true` (`Config.kt:21`).
- `kotlin/example/src/main/kotlin/RouteTest.kt:31` (`server.serveHttp(14257)`). It gets replaced by the harness described under Tests.
- `kotlin/src/test/kotlin/io/antidrift/zeromcp/OpenApiSpecTest.kt`. Its assertions move (see Tests).

No dependency changes: `com.sun.net.httpserver` ships with the JDK (`jdk.httpserver`), and `kotlin/build.gradle.kts:14-18` has no HTTP-related entries.

## Keep
- `serve()` (stdio, `Server.kt:116-138`), `handleRequest` (`Server.kt:270`), `registry()` (`Server.kt:69-81`), `Registry.kt`.
- `buildOpenApiSpecJson` (`Server.kt:608-699`). `registry()` calls it (`Server.kt:78`). Leave it where it is, under `// --- OpenAPI spec builder ---`, as `internal`.
- `toArgMap` and `toJsonElement` (`Server.kt:753`, `778`). `handleToolRoute` uses them, but so do `tools/call` (`Server.kt:332`), `prompts/get` (`Server.kt:413`), `callTool` (`Server.kt:464`) and `buildOpenApiSpecJson` (`Server.kt:693`).
- The `runBlocking`, `Dispatchers`, `runInterruptible` and `withTimeout` imports. `serve()` and `callTool` still use them (`Server.kt:132`, `457`).
- README's "HTTP / Streamable HTTP" section (`kotlin/README.md:39-70`). It already tells users to bring their own framework and doesn't mention `serveHttp`. Switch the Ktor example from `server.handleRequest` to `server.registry()`, so it shows `registry.mcp` on `POST /mcp`, `registry.openapi` on `GET /openapi.json`, and a loop over `registry.routes`. Update the line 41 sentence to name `registry()` as well as `handleRequest`.

## Startup error for an `http` transport
Today `ZeroMcpConfig.transport` is a `String` (`Config.kt:9`), and nothing in `kotlin/src/main` reads it (grep finds only the declaration). A config file whose `transport` is an array of objects, like `[{ "type": "http", "port": 14252 }]` (the shape in `tests/conformance/route-config-ruby.json`), fails to decode into `String`. `loadConfig` catches that, prints a warning and returns defaults (`Config.kt:31-36`), so the server falls back to stdio.

Change:
- `loadConfig` parses the file to a `JsonObject` before decoding, outside the `try` at `Config.kt:31`, so the catch can't swallow the error. If `transport` is a string other than `"stdio"`, or an array with any element whose `type` is not `"stdio"`, it throws `IllegalStateException`.
- `ZeroMcp` gets an `init` check: `config.transport != "stdio"` throws the same exception. This covers a `ZeroMcpConfig(transport = "http")` built in code.
- The message: `transport "http" is not supported: ZeroMCP does not ship an HTTP server. Mount ZeroMcp.registry() (routes, openapi, mcp) or ZeroMcp.handleRequest() in your own HTTP server.` It uses the offending value in place of `http`.
- `transport` stays as a field and accepts `"stdio"` only.

## Breaking change
Not in a published Kotlin artifact. Maven Central's `dev.antidrift:zeromcp` metadata lists 0.1.0, 0.1.1, 0.2.0, 0.2.2 and 0.3.0 (`curl https://repo1.maven.org/maven2/dev/antidrift/zeromcp/maven-metadata.xml`). The 0.1.0, 0.2.0, 0.2.2 and 0.3.0 jars are the Java build: `unzip -l` shows `Tool$Builder.class` and `Permissions.class`, and no `ServerKt`, `ToolBuilder` or `.kotlin_module`. 0.1.1 was not checked. The Kotlin `publishing` block has no `repositories` (`kotlin/build.gradle.kts:28-58`). JitPack has no builds for `com.github.antidrift-dev/zeromcp`, and GitHub Packages lists no maven packages for the org. `serveHttp` is in the `v0.3.0` git tag source (`git show v0.3.0:kotlin/.../Server.kt`, line 144), so anyone building from the tag breaks. Note it in the next release's changelog with the one-line replacement: mount `ZeroMcp.registry()` in your own server.

## Tests
- `OpenApiSpecTest.kt` is the only unit test that starts the server (`OpenApiSpecTest.kt:35`). `RegistryTest.kt:52-58` checks only that a GET path key exists, so it does not cover this test's assertions: a non-GET `:param` shows up in `parameters` as `in: path, required: true`, and the request-body schema leaves it out (`OpenApiSpecTest.kt:42-53`). Move them into `RegistryTest.kt` as a test that registers `PUT /items/:id` and asserts against `server.registry().openapi`. Delete `OpenApiSpecTest.kt`, including its HTTP polling helper.
- `ConfigTest.kt:13` asserts `config.port == 4242`. Remove that line.
- Add to `ConfigTest.kt`: `loadConfig` on a temp dir with `{"transport":"http"}` throws, with a message that contains `registry()`. The same holds for `{"transport":[{"type":"http","port":1}]}`. `ZeroMcp(ZeroMcpConfig(transport = "http"))` throws.
- `ServerTest.kt`, `SchemaTest.kt`, `SandboxTest.kt`: no HTTP use (grep finds no `serveHttp` in them). No change.
- Route conformance: `tests/conformance/run-route.js:74-81` starts the example binary with `ZEROMCP_ROUTE_TEST=true` on port 14257 and expects the five checks at `run-route.js:145-187`: `GET /greet/World`, `POST /echo`, `GET /openapi.json`, `GET /docs` containing "swagger", and `POST /mcp tools/list`. Make `RouteTest.kt` the test-only harness:
  - Rename its `main()` to `routeTestMain()`.
  - Add the `ZEROMCP_ROUTE_TEST` branch to `Main.kt`, the way it dispatches the other `*_TEST` vars (`Main.kt:4-31`).
  - Mount `server.registry()` on a JDK `com.sun.net.httpserver.HttpServer` at port 14257. For each `registry.routes` entry, match method and `:param` path, build args from path params plus the query (GET) or JSON body (otherwise), call `tool.execute`, and reply `{"ok":true,"result":...}`. Serve `registry.openapi` at `/openapi.json`, a static Swagger HTML string at `/docs`, and `runBlocking { registry.mcp(req) }` at `/mcp`.
  - The `example` module isn't published (`kotlin/example/build.gradle.kts` has no `maven-publish`), so none of this ships.
- The rest of `tests/conformance/run-all.js`, `tests/chaos/run-chaos.js:420-426`, `tests/performance/run-mixed-all.mjs:120-124` and `run-mixed-docker.mjs:117-121` run the Kotlin example over stdio and need no change. The root `Dockerfile:106-108` and `tests/performance/Dockerfile:87-89` build `:example:installDist`, which picks up the harness with no change. `tests/performance/run-zeromcp-overnight.sh:72-75` runs a `zeromcp-bench-http-kotlin` image (`/bench/ktor/bin/bench-ktor`) whose source is not in this repo. Whether it calls `serveHttp` is unverified.

## Verify
```sh
docker build -t zeromcp-tests .
docker run --rm zeromcp-tests sh -c 'cd kotlin && gradle test'
docker run --rm zeromcp-tests node tests/conformance/run-all.js --language "Kotlin"
docker run --rm zeromcp-tests node tests/conformance/run-route.js   # Kotlin must show 5 passed, not skipped
grep -rn -E 'httpserver|InetSocketAddress|serveHttp|val port' kotlin/src   # expect nothing
```
