# Framework-neutral tool registry — Kotlin

## Status

**Spec — not yet implemented.** This document is the Kotlin port plan for the framework-neutral registry shipped in Node.js (`nodejs/src/registry.ts`, see `specs/lang/nodejs/registry.md` for the as-built reference). Nothing in this file exists in `kotlin/` yet.

## Motivation

`ZeroMcp.serveHttp()` (in `kotlin/src/main/kotlin/io/antidrift/zeromcp/Server.kt`) already mounts tool `route { method, path }` definitions onto its own `com.sun.net.httpserver.HttpServer` instance and serves `/openapi.json` via the private `buildOpenApiSpec` function. That's fine for a standalone `zeromcp serve` process, but it locks route matching, arg extraction, and OpenAPI generation inside `ZeroMcp`'s own `HttpServer` loop. A JVM consumer who wants ZeroMCP tools mounted inside Ktor, Spring (WebFlux/MVC), Micronaut, a plain Javalin app, or an AWS Lambda `RequestHandler` currently has no way to reuse that logic — they'd have to re-derive route lists and re-implement OpenAPI generation by hand.

The registry closes that gap: a second, additive entry point on `ZeroMcp` that hands back the same route list and OpenAPI document as data, plus a ready-to-call JSON-RPC handler, so a caller's framework of choice does the actual HTTP wiring (path matching, param extraction, request/response mapping) itself.

This is **additive** — `ZeroMcp.serveHttp()` is unchanged and keeps doing its own route/OpenAPI handling internally. The registry is a second way to consume the same `tools`/`schemas` state already held by a `ZeroMcp` instance.

## Public API

New file: `kotlin/src/main/kotlin/io/antidrift/zeromcp/Registry.kt`, package `io.antidrift.zeromcp` (same package as everything else — Kotlin has no subpath-export mechanism analogous to npm's `"./registry"`, so there is no separate import path; `Registry`, `RouteDefinition`, and `McpHandler` are simply additional public symbols in the `io.antidrift.zeromcp` package, alongside `ZeroMcp`, `ToolDefinition`, etc.).

```kotlin
package io.antidrift.zeromcp

import kotlinx.serialization.json.JsonObject

/** A JSON-RPC request handler: takes a parsed request object, returns a response or null for notifications. */
typealias McpHandler = suspend (request: JsonObject) -> JsonObject?

/**
 * A tool exposed as an HTTP route, as plain data — no routing or param
 * extraction is performed here. The caller's framework is responsible for
 * matching [method]/[path] and turning path/query/body data into the
 * `args` map passed to `tool.execute`.
 */
data class RouteDefinition(
    val name: String,
    val method: String,   // GET, POST, PUT, PATCH, DELETE — same convention as RouteConfig.method
    val path: String,     // e.g. "/:domain/leads" (colon-param syntax, same as RouteConfig.path)
    val tool: ToolDefinition
)

/**
 * Framework-neutral view over a [ZeroMcp] instance's registered tools.
 */
data class Registry(
    val routes: List<RouteDefinition>,
    val openapi: JsonObject,
    val mcp: McpHandler
)
```

And one new method on the existing `ZeroMcp` class in `Server.kt`:

```kotlin
class ZeroMcp(private val config: ZeroMcpConfig = loadConfig()) {
    // ... existing tools/schemas/resources/... fields and tool()/register()/serve()/serveHttp() ...

    /**
     * Build a framework-neutral [Registry] view over the tools registered so
     * far. Call after all `tool { ... }` / `register(...)` calls.
     */
    fun registry(): Registry {
        val routeDefs = tools.values
            .filter { it.route != null }
            .map { tool ->
                val r = tool.route!!
                RouteDefinition(name = tool.name, method = r.method, path = r.path, tool = tool)
            }
        return Registry(
            routes = routeDefs,
            openapi = buildOpenApiSpecJson(tools, schemas, config.title),
            mcp = { request -> handleRequest(request) }
        )
    }
}
```

### Usage

```kotlin
val server = ZeroMcp()
server.tool("greet") {
    description = "Greet a person by name"
    input { "name" to "string" }
    route("GET", "/greet/:name")
    execute { args, _ -> "Hello, ${args.getString("name")}!" }
}

val registry = server.registry()
// registry.routes:  List<RouteDefinition> — wire into Ktor/Spring/Javalin/Lambda yourself
// registry.openapi: JsonObject — serve statically, e.g. call.respond(registry.openapi) in Ktor
// registry.mcp:     suspend (JsonObject) -> JsonObject? — call directly from a POST /mcp handler
```

### Behavior

- `ZeroMcp.registry()` is a method on the existing `ZeroMcp` class, not a standalone top-level function taking a raw tool map. Node's `createRegistry(tools, options)` is a free function because `registry.ts` has no equivalent of a stateful "server" object to hang off of — it builds its own internal `state` from the passed-in map. Kotlin already has that stateful object: `ZeroMcp` already owns `tools: MutableMap<String, ToolDefinition>`, `schemas: MutableMap<String, JsonObject>`, and `config`, and already builds schemas at registration time via `tool()`/`register()`. Re-deriving that state from a raw map (as a free function would have to) would duplicate `ToolBuilder`, `validatePermissions`, and `toJsonSchema` wiring for no benefit — `registry()` just reads the state `ZeroMcp` already has.
- No `RegistryOptions`/`getEnv` equivalent, and no generic `TEnv` on `ToolDefinition`/`RouteDefinition`. Node's `Tool<TEnv>.execute(args, env)` needs an explicit `env` parameter because a Cloudflare Worker (Node's primary target) receives per-request bindings with no long-lived process state to close over. Kotlin's `ToolDefinition.execute` is already `suspend (args: Map<String, Any?>, ctx: Ctx) -> Any?`, and `Ctx` is a fixed shape (`toolName`, `permissions`) built internally by `ZeroMcp` (see `callTool` and `handleToolRoute` in `Server.kt`, both of which construct `Ctx(toolName = ..., permissions = ...)`) — it is not a slot for caller-supplied environment data today, and the registry does not change that. On the JVM, tools are registered via a DSL block (`execute { args, ctx -> ... }`) that is a closure over whatever the call site captured — a DB connection pool, an HTTP client, config — at construction time. That's the idiomatic way to give a tool "environment" in Kotlin (lexical capture), not a per-call parameter, so there is nothing for the registry to inject. If a future need arises for genuinely per-request environment (e.g. a Ktor `ApplicationCall` or Lambda `Context`), it should be threaded through `Ctx` for `ZeroMcp` as a whole, not bolted onto the registry alone — **open question, not solved by this spec.**
- `routes` is derived by filtering `tools.values` down to entries with a non-null `route`, in the map's iteration order (`tools` is a `LinkedHashMap`-backed `mutableMapOf`, so this is insertion order — same guarantee `tools/list` and `handleToolRoute` already rely on). No route matching, param extraction, or HTTP handling happens in `registry()`. The caller is responsible for turning each `RouteDefinition` into a framework handler: matching `method`/`path` (note `path` uses the same `:param` colon syntax as `RouteConfig`, e.g. `/:domain/leads` — not `{param}` — callers using a framework with different path-param syntax must translate it themselves, same as `matchRoutePath` does internally today), extracting args, calling `tool.execute(args, ctx)`, and mapping the result to a response.
- `openapi` reuses the OpenAPI-building logic already used for `/openapi.json`. Today `buildOpenApiSpec(tools, schemas, title): String` in `Server.kt` builds a `JsonObject` internally (the `spec` local val, built with `buildJsonObject { ... }`) and immediately serializes it to a `String` for the HTTP response. **This requires a small refactor to `Server.kt`, not a rewrite**: extract the existing `buildJsonObject { ... }` block into a new function `buildOpenApiSpecJson(tools: Map<String, ToolDefinition>, schemas: Map<String, JsonObject>, title: String): JsonObject`, and change `buildOpenApiSpec` to `Json.encodeToString(JsonObject.serializer(), buildOpenApiSpecJson(tools, schemas, title))`. Both functions must change visibility from `private` to `internal` — Kotlin's top-level `private` is *file-scoped*, not package-scoped, so a `private fun` in `Server.kt` is invisible to `Registry.kt` even though both are in `io.antidrift.zeromcp`. `internal` (module-visible) is the right scope: it keeps these helpers out of the public API surface (matching today's intent of `private`) while letting `Registry.kt` call them. The path-param translation (`:name` → `{name}`), GET-vs-body parameter placement, and `requestBody` schema derivation all stay exactly as implemented today — none of that logic changes, only its visibility and where its `JsonObject` result is captured before serialization.
- `mcp` is `handleRequest` (already a public `suspend fun handleRequest(request: JsonObject): JsonObject?` on `ZeroMcp`, used today by both `serve()` for stdio and `serveHttp()` for the `/mcp` HTTP context) wrapped as a `McpHandler` value. No dispatch logic is duplicated; `registry().mcp` is a direct pass-through. Because `handleRequest` is `suspend`, `registry.mcp` is also `suspend` — callers embedding it in a coroutine-based framework (Ktor route handlers are already `suspend`) call it directly; callers on a blocking framework (Spring MVC, Javalin) need their own `runBlocking { registry.mcp(request) }` at the call site, the same pattern `ZeroMcp` itself uses internally in `serve()`/`serveHttp()`/`handleToolRoute`. No coroutine scope is created or owned by the registry — it neither starts nor requires a caller-supplied `CoroutineScope`, since `handleRequest` doesn't launch any child coroutines of its own (its `withTimeout`/`runInterruptible` use in `callTool` are structured, self-contained suspend calls).
- No auth hook. Auth is the caller's framework's concern (Ktor plugins, Spring Security filters, API Gateway authorizers, etc.), same conclusion as Node.

### Non-goals

- Does not replace or call into `ZeroMcp.serveHttp()`'s built-in `HttpServer`.
- Does not do any HTTP request/response handling, routing, or body parsing — `routes` is data, not wired handlers.
- Does not depend on any HTTP/web framework (no Ktor, Spring, Javalin types in `Registry.kt` or anywhere in the `zeromcp` module).
- Does not introduce a generic environment/`TEnv` parameter on `ToolDefinition` or `Ctx` — see the open question above.
- Does not change `RouteConfig.method`'s type (`String`) to an enum. Node has a `RouteMethod` union type; introducing a Kotlin enum now would be a larger, unrelated change to `Types.kt`/`RouteConfig` and is out of scope for this port.

## Packaging

- New source file: `kotlin/src/main/kotlin/io/antidrift/zeromcp/Registry.kt` (types: `McpHandler`, `RouteDefinition`, `Registry`).
- Small edit to `kotlin/src/main/kotlin/io/antidrift/zeromcp/Server.kt`: add `ZeroMcp.registry()`; extract `buildOpenApiSpecJson(...): JsonObject` from `buildOpenApiSpec(...): String` and change both from `private` to `internal`.
- No new Gradle dependencies — `kotlinx-serialization-json` and `kotlinx-coroutines-core` (already in `kotlin/build.gradle.kts`) are all that's needed.
- No new artifact/module and no subpath-export equivalent to publish: Kotlin publishes one jar (`dev.antidrift:zeromcp`, per `kotlin/build.gradle.kts`'s `maven-publish` block) containing the whole `io.antidrift.zeromcp` package. Consumers already depending on `dev.antidrift:zeromcp` get `Registry`/`RouteDefinition`/`ZeroMcp.registry()` for free after a version bump — no new dependency coordinate to add.
- Suggested conformance example: a `kotlin/example/src/main/kotlin/RegistryTest.kt` sibling to the existing `kotlin/example/src/main/kotlin/RouteTest.kt`, mirroring whatever `tests/conformance/route-tools/` does for Node's registry today (check `tests/conformance/run-route.js` / `route-config-*.json` for the pattern other languages' route conformance tests follow, and add a Kotlin registry equivalent alongside it if/when the other languages get one).

## Porting notes (for whoever implements this)

1. `ToolDefinition.route: RouteConfig?` (in `Types.kt`) already exists from the earlier "Add route field" work — reuse it as-is; `RouteDefinition.tool.route` is the same field.
2. `ZeroMcp.handleRequest(request: JsonObject): JsonObject?` (in `Server.kt`) is the existing dispatch/state machinery — it is already `suspend` and already public, so `registry().mcp` can wrap it with zero changes to `handleRequest` itself.
3. `buildOpenApiSpec` (in `Server.kt`) is the existing OpenAPI builder used for `/openapi.json` — it needs the visibility/extraction change described above (`private` → `internal`, split into a `JsonObject`-returning core plus the existing `String`-returning wrapper) so `Registry.kt` can call it, but none of its path-translation or schema logic changes.
4. `tools` and `schemas` (private `mutableMapOf` fields on `ZeroMcp`) are read directly by `registry()` since it's a method on the same class — no new state container is introduced.

## Fixed: existing `buildOpenApiSpec` had the same non-GET path-param bug as Node

Auditing all 10 languages for the Node bug above found the exact same bug already shipped in Kotlin's own `buildOpenApiSpec(tools, schemas, title): String` (`Server.kt:586`, pre-dating this registry spec entirely — it's the function `serveHttp`'s `/openapi.json` route already calls at `Server.kt:155`). For a non-GET route with a `:param` segment (e.g. `PUT /items/:id`), the `for ((fieldName, field) in tool.input) { if (isGet) { ... } }` loop (`Server.kt:598-610`, prior to this fix) only ever populated `parameters` when `isGet` was true, so non-GET routes got no `parameters` array at all — and separately, the `if (!isGet && tool.input.isNotEmpty())` block (`Server.kt:622-632`, prior to this fix) attached `requestBody` using `schemas[tool.name]` wholesale, with no filtering, so path-param fields like `id` ended up documented only as a body property and never as a path parameter.

**Fixed directly** (not just specified) in `Server.kt`:
- The `for ((fieldName, field) in tool.input)` loop (now `Server.kt:598-613`) runs its parameter-building body when `isGet || isPathParam` instead of only `isGet`, so non-GET routes now get a `parameters` entry (`{ "in": "path", "required": true, ... }`) for each field that is a path param, matching the GET branch's existing shape. Query-param entries remain GET-only, unchanged.
- The `requestBody` block (now `Server.kt:625-652`) builds a filtered `bodySchema` when `pathParams` is non-empty: it copies `schema["properties"]` and `schema["required"]` from the precomputed `schemas[tool.name]` `JsonObject`, drops any key in `pathParams`, and reassembles a `{ "type": "object", "properties": ..., "required": [...] }` object via `buildJsonObject`/`putJsonObject`. When a route has no path params, the original `schema` is used unchanged (no unnecessary rebuild). GET routes are untouched — they never enter this branch.

The shared `kotlin/example/src/main/kotlin/RouteTest.kt` conformance example (used across all 10 languages' route-conformance suite) only registers `GET /greet/:name` and `POST /echo` — no non-GET route with a `:param` segment — so it doesn't exercise this bug either way, and wasn't changed here to keep parity with the other languages' `RouteTest` files. Instead, verified with a new dedicated regression test, `kotlin/src/test/kotlin/io/antidrift/zeromcp/OpenApiSpecTest.kt`: since `buildOpenApiSpec` is file-private (file-scoped, not just class-private, per Kotlin's top-level `private` semantics — see point 3 above), the test exercises it the only way available from outside `Server.kt`, over the real `/openapi.json` HTTP route — it registers a `PUT /items/:id` tool, starts `serveHttp` on a background thread, fetches `/openapi.json`, and asserts `id` appears in `parameters` as `{ "in": "path", "required": true }` and is absent from the `requestBody` schema's `properties`, while the non-path field `name` still is. `gradle build` (whole module, including `example`) and `gradle test` both pass clean: 5 test classes, 59 tests, 0 failures. This means the Kotlin port's reuse of `buildOpenApiSpec`/`buildOpenApiSpecJson` (point 3 above) now gets the corrected behavior for free — no divergent logic for the registry to carry.
