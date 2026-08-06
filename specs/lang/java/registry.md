# Framework-neutral tool registry — Java

## Status

**Spec — not yet implemented.** This document is the Java port design for the framework-neutral registry shipped in Node.js (`nodejs/src/registry.ts`, see `specs/lang/nodejs/registry.md`). No code has been written yet; class/method names below are the target design, not existing API.

## Motivation

Java's built-in HTTP server (`ZeroMcp.serveHttp`, in `java/src/main/java/io/antidrift/zeromcp/ZeroMcp.java`) already does three things internally for route-annotated tools: it mounts each `Tool.route()` at its `com.sun.net.httpserver.HttpServer` path, it builds an OpenAPI 3.0 document from the same route-annotated tools (`buildOpenApiSpec()`, currently a private method), and it dispatches standard JSON-RPC over `/mcp` via the already-public `handleRequest(JsonObject)`. All of that is locked inside `serveHttp()` — a consumer who wants ZeroMCP tools inside Spring MVC, Javalin, a plain `com.sun.net.httpserver` handler they own, or an AWS Lambda `RequestHandler` has no way to get at the route list or the OpenAPI document without spinning up ZeroMCP's own HTTP server.

This spec adds a second, additive entry point — `ZeroMcp.registry()` — that hands back the same three ingredients (routes, OpenAPI doc, JSON-RPC dispatcher) as plain data/handles, so the caller wires them into whatever framework they use. `serveHttp()` is unchanged and keeps doing its own thing internally.

## Public API

New files, package `io.antidrift.zeromcp` (same package as `ZeroMcp`, `Tool`, `Ctx`, etc.):

**`java/src/main/java/io/antidrift/zeromcp/Registry.java`**

```java
package io.antidrift.zeromcp;

import com.google.gson.JsonObject;
import java.util.List;

/**
 * Framework-neutral handle onto a ZeroMcp instance's route-annotated tools
 * and JSON-RPC dispatch, for embedding into a caller-owned HTTP framework
 * instead of using {@link ZeroMcp#serveHttp}.
 */
public record Registry(List<RouteDefinition> routes, JsonObject openapi, McpHandler mcp) {}
```

**`java/src/main/java/io/antidrift/zeromcp/RouteDefinition.java`**

```java
package io.antidrift.zeromcp;

/** One route-annotated tool, as plain data. No HTTP routing/param-extraction is done here. */
public record RouteDefinition(String name, String method, String path, Tool tool) {}
```

**`java/src/main/java/io/antidrift/zeromcp/McpHandler.java`**

```java
package io.antidrift.zeromcp;

import com.google.gson.JsonObject;

/** A JSON-RPC request handler. Returns null for notifications that require no response. */
@FunctionalInterface
public interface McpHandler {
    JsonObject handle(JsonObject request);
}
```

**New method on `ZeroMcp`** (added to `java/src/main/java/io/antidrift/zeromcp/ZeroMcp.java`, alongside the existing `serve()` / `serveHttp()` entry points):

```java
/**
 * Build a framework-neutral registry snapshot of the currently-registered,
 * route-annotated tools plus a JSON-RPC dispatcher, for embedding into a
 * caller-owned HTTP framework instead of ZeroMcp's built-in server.
 * Call this after all {@link #tool} registrations are done, same as
 * {@link #serve} / {@link #serveHttp}.
 */
public Registry registry() {
    return new Registry(routeDefinitions(), buildOpenApiSpec(), this::handleRequest);
}
```

Usage:

```java
var server = new ZeroMcp();
server.tool("greet", Tool.builder()
    .description("Greet a person by name")
    .input(Input.required("name", "string"))
    .route("GET", "/greet/:name")
    .execute((a, ctx) -> "Hello, " + a.get("name") + "!")
    .build());

var registry = server.registry();
// registry.routes()  -> List<RouteDefinition>, wire into e.g. Javalin/Spring routing
// registry.openapi() -> JsonObject, serve as-is at your own /openapi.json
// registry.mcp()     -> McpHandler, call .handle(request) from your own /mcp endpoint
```

## Behavior

- **No change to `Tool`, `ToolExecutor`, or `Ctx`.** `Tool` already carries an optional `Tool.Route(String method, String path)` (added for route support, `Tool.java:26-27`, set via `Tool.Builder.route(method, path)`). `ToolExecutor.execute(Map<String, Object> args, Ctx ctx)` is unchanged — the registry does not introduce a generic "env" type parameter (see Non-goals/porting notes below for why).
- `registry()` is an **instance method on `ZeroMcp`**, not a static factory taking a tool map. Java's existing convention (README: "Register tools in code (builder API)") already accumulates tools by mutation — `new ZeroMcp()` then repeated `server.tool(name, tool)` — so `registry()` reads the already-registered `tools` field directly instead of taking a second map argument the way Node's `createRegistry(tools, options)` does. Call it after all `.tool()` registrations, same rule as `.serve()`/`.serveHttp()`.
- **`routes`** is built by a new private helper `List<RouteDefinition> routeDefinitions()` on `ZeroMcp`, which walks the existing `tools` field (`Map<String, NamedTool>`) in insertion order (it's a `LinkedHashMap`, `ZeroMcp.java:43`) and keeps only entries where `namedTool.tool().route() != null`, mapping each to `new RouteDefinition(name, route.method(), route.path(), namedTool.tool())`. This is the same filter ZeroMcp already applies twice today — once in `serveHttp()`'s route-mounting loop (`ZeroMcp.java:169-218`) and once in `buildOpenApiSpec()` (`ZeroMcp.java:296-354`) — pulled out into one shared method so all three call sites (route mounting, OpenAPI generation, and the new registry) agree on what counts as a "route-annotated tool." No HTTP routing, path-param matching, or query-string parsing happens in `Registry` or `routeDefinitions()` — that stays entirely the caller's job. (`ZeroMcp`'s own `matchPathParams`/`parseQueryString` helpers, `ZeroMcp.java:253-282`, remain private and are used only by `serveHttp()`'s built-in server, not exposed to `Registry` callers — a caller embedding a `RouteDefinition` in Spring/Javalin/Lambda uses that framework's own path/query extraction, then calls `routeDefinition.tool().executor().execute(args, ctx)` directly, constructing `Ctx` the same way `serveHttp()` already does: `new Ctx(name, tool.permissions())`, or the 1-arg `new Ctx(name)` convenience constructor for tools with default permissions.)
- **`openapi`** reuses `buildOpenApiSpec()` (`ZeroMcp.java:287-358`) verbatim — its visibility changes from `private` to package-private so `ZeroMcp.registry()` can call it (it's called from within `ZeroMcp` itself, so no visibility change is strictly required, but keeping it callable makes future package-internal reuse straightforward). It is computed **once**, at the moment `registry()` is called, and cached in the returned `Registry` record — not regenerated per access, matching Node's "generated once, ready to serve statically" behavior. This differs slightly from `serveHttp()`'s `/openapi.json` handler, which currently rebuilds the spec on every GET (`ZeroMcp.java:134-144`); that's existing, unrelated behavior and is out of scope to change here.
- **`mcp`** is `this::handleRequest` — the exact same public `JsonObject handleRequest(JsonObject request)` (`ZeroMcp.java:394-431`) that both `serve()` (stdio loop) and `serveHttp()`'s `/mcp` context already call. No new dispatch logic. `tools/call` timeout handling (`callTool()`, `ZeroMcp.java:531-561`, which wraps execution in a `CompletableFuture` and enforces `Permissions.executeTimeout()` / `Config.executeTimeout()`) is inherited automatically by `registry.mcp()` for free, since it's the identical code path.
- `Registry` is an immutable record: `routes()` returns a `List<RouteDefinition>` (build with `List.copyOf(...)` in `routeDefinitions()` so callers can't mutate ZeroMcp's internal view), `openapi()` returns the `JsonObject` built once by `buildOpenApiSpec()` (Gson `JsonObject` is itself mutable, same caveat that already exists for `serveHttp()`'s spec — not a new concern introduced here), and `mcp()` is a stateless functional reference.
- No auth hook, matching Node. Auth is the caller's framework's concern.

### Non-goals

- Does not replace or call into `serveHttp()`'s built-in `com.sun.net.httpserver.HttpServer`.
- Does not do any HTTP request/response handling, routing, path-param extraction, or body parsing — `RouteDefinition` is data, not a wired handler. (Contrast with `serveHttp()`'s internal `matchPathParams`/`parseQueryString`, which stay private to the built-in server.)
- Does not depend on any HTTP framework (no Javalin, no Spring, no `jakarta.servlet` types) — only `com.google.gson` (already a dependency, see `java/pom.xml`) and JDK types.
- Does not add a generic "env" type parameter to `Tool`/`ToolExecutor` the way Node's `Tool<TEnv>`/`RegistryOptions<TEnv>.getEnv` does. See rationale below.

## Packaging

- Three new source files, all in the existing `io.antidrift.zeromcp` package (`java/src/main/java/io/antidrift/zeromcp/`): `Registry.java`, `RouteDefinition.java`, `McpHandler.java`.
- One new public method on the existing `ZeroMcp.java`: `public Registry registry()`, plus a new private helper `List<RouteDefinition> routeDefinitions()` extracted from the duplicated route-filtering logic already in `serveHttp()` and `buildOpenApiSpec()`.
- No new Maven dependency. `java/pom.xml` already depends only on `com.google.code.gson:gson` (runtime) and `org.junit.jupiter:junit-jupiter` (test) — the registry needs nothing beyond what `ZeroMcp.java` already imports.
- No new package/subpath export needed — Java doesn't have Node's `package.json` subpath-export mechanism. `Registry`, `RouteDefinition`, and `McpHandler` are just additional public types in the same `dev.antidrift:zeromcp` artifact (`java/pom.xml:7-9`), imported the normal way: `import io.antidrift.zeromcp.Registry;` (or `import io.antidrift.zeromcp.*;`, the style already used in `java/example/src/main/java/RouteTest.java:1`).
- Suggested conformance/example file: `java/example/src/main/java/RegistryTest.java`, modeled on the existing `java/example/src/main/java/RouteTest.java` but calling `server.registry()` and asserting on `registry.routes().size()`, `registry.openapi()`, and `registry.mcp().handle(...)` instead of `server.serveHttp(...)`.

## Porting notes

Judgment calls made for this Java port, worth checking against when porting to Kotlin/Swift/C# next:

1. **No `TEnv` generic.** Node's `Tool<TEnv>` threads a caller-supplied "env" object (e.g. a Cloudflare Worker's bindings) through to `execute(args, env)`, and `RegistryOptions.getEnv` supplies it on the `mcp` path where there's no per-request framework context. Java's `ToolExecutor.execute(Map<String, Object> args, Ctx ctx)` has no equivalent slot — `Ctx` is a fixed two-field record (`toolName`, `permissions`, `Ctx.java:6`) built internally by `ZeroMcp` (in `callTool()` for JSON-RPC, and inline in `serveHttp()`'s route-mounting loop for HTTP routes), not a caller-injectable generic. Adding a `TEnv`-style generic to `Tool`/`ToolExecutor` would be a much bigger, non-additive change touching every existing tool signature across the whole Java implementation, for a capability (arbitrary per-deployment env/bindings) that doesn't have a clear use case in a JVM server context the way it does in a Workers/Lambda-with-bindings context. Recommendation: skip it for this port. A `Registry` caller using `routes()` already constructs `Ctx` themselves exactly the way `serveHttp()` does today (`new Ctx(name, tool.permissions())`) — that's the existing extension point, and it's enough.
2. **`registry()` is an instance method, not a static factory.** Node's `createRegistry(tools, options)` takes a tool map as an argument because Node tools are typically assembled into a plain object before being handed to either `server.ts` or `registry.ts`. Java's `ZeroMcp` is inherently stateful/builder-style (tools accumulate via `server.tool(name, tool)` calls) with no equivalent "map of tools" ever constructed by the caller, so `server.registry()` reading `ZeroMcp`'s own `tools` field is the natural fit, not `Registry.create(toolMap)`. Kotlin's DSL-based registration model may or may not have the same shape — check before assuming the same instance-method pattern applies there.
3. **`openapi` is cached once, not rebuilt per access** — deliberately tighter than `serveHttp()`'s `/openapi.json` handler (which rebuilds on every request today). This seemed like the more useful default for embedding (a caller likely serves it statically), and matches the Node spec's stated behavior ("generated once ... ready to serve statically"). If a future need arises for a *live* OpenAPI view that reflects tools registered after `registry()` was called, that would need a different (lazy/recomputing) design — not addressed here.
4. **Route filtering logic gets extracted, not duplicated a third time.** `serveHttp()` and `buildOpenApiSpec()` each independently loop `tools.entrySet()` and skip entries with `route() == null`. Adding a third near-identical loop for `Registry.routes()` would be the third copy of that filter; instead this spec pulls it into one `routeDefinitions()` helper used by all three. This is a small refactor of existing code, not just new code — flag it in review as touching `serveHttp()`'s and `buildOpenApiSpec()`'s existing loops if the implementer chooses to have them call the new helper too (optional; the registry itself only strictly needs `routeDefinitions()` to exist and be correct, not for the other two call sites to be rewired to use it).

## Fixed: existing `buildOpenApiSpec()` had the same non-GET path-param bug as Node

Auditing all 10 languages for the Node bug above found the exact same bug already shipped in Java's own `buildOpenApiSpec()` (`ZeroMcp.java:287`, pre-dating this registry spec entirely — it's used by `serveHttp()`'s `/openapi.json` today, and is the exact method point 3 of the "Porting notes" above says this registry reuses verbatim). For a non-GET route with a `:param` segment (e.g. `PUT /items/:id`), the `else` branch (`ZeroMcp.java:332-340`, prior to this fix) dumped `namedTool.inputSchema()` — the *entire* cached input schema, including path-param fields — straight into the `requestBody` schema, and never emitted a `parameters` array for path segments at all. Worse than the equivalent Node/Swift bugs: it didn't even build a filtered `properties` object first, it reused the whole cached schema object verbatim. `:id` on a route like `PUT /items/:id` was documented only as a body property, never as a path parameter.

**Fixed directly** (not just specified) in `ZeroMcp.java`: the `else` branch now builds its own `bodySchema` by iterating `namedTool.tool().inputs()` (the same iteration the `isGet` branch already does at line 320) and skipping any input whose `name()` is in `pathParamNames`, assembling `properties`/`required` in the same shape `Schema.toJsonSchema()` (`Schema.java:21-43`) produces — `{"type": ..., "description": ...}` per property, `required` listing every non-optional field — rather than reusing `namedTool.inputSchema()` wholesale. When `pathParamNames` is non-empty, it also adds a `parameters` array to `operation`, one entry per path param: `{"name": ..., "in": "path", "required": true, "schema": {"type": "string"}}`, matching the shape the `isGet` branch already emits for its own path parameters. The `isGet` branch (lines 317-331) is untouched, and `info.addProperty("version", "0.5.0")` (line 293) is untouched — both explicitly out of scope for this fix.

This means the Java port's reuse of `buildOpenApiSpec()` (point 3 above, and `registry()`'s `openapi` field) now gets the corrected behavior for free — no divergent logic for the registry to carry, same as the Swift port.
