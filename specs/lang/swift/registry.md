# Framework-neutral tool registry — Swift

## Status

**Shipped**, on branch `registry/swift`. Implemented exactly as designed below: `Registry.swift` (new `RegistryRoute`/`McpHandler`/`RegistryOptions`/`Registry` types and the free function `createRegistry`), plus the one visibility change to `HttpServer.swift`'s `buildOpenApiSpec()` (`private` → `internal`). Covered by 8 new tests in `RegistryTests.swift` (route filtering, sorted order, OpenAPI parity, direct tool invocation, `mcp` dispatch for `tools/list` and `tools/call`, empty-routes case, and that the default `RegistryOptions()` doesn't touch disk). `swift build` (all targets, including `RouteTest`/`example`) and `swift test` (71 tests, 0 failures, 0 regressions) both pass.

## Motivation

Swift's built-in HTTP transport (`ZeroMcp.serveHttp(port:)` in `swift/Sources/ZeroMcp/HttpServer.swift`) mounts each tool's `route` onto its own POSIX-socket listener and serves `/mcp`, `/health`, `/openapi.json`, and `/docs`. That's the right shape for `zeromcp-example`-style standalone processes, but it locks route dispatch and OpenAPI generation inside `serveHttp`'s accept loop. A consumer who wants ZeroMCP tools inside Vapor, Hummingbird, a plain `URLSession`-based server, or an AWS Lambda Swift runtime handler currently has no way to reuse that logic — they'd have to hand-write their own JSON-RPC dispatch and OpenAPI generation against `ToolDefinition` values.

This spec adds a second, composable entry point — a free function `createRegistry(_:options:)` — that returns plain data (`routes`, `openapi`, `mcp`) built from pieces the Swift implementation already has. It does not touch `serveHttp` or its POSIX-socket accept loop; `serveHttp` keeps working exactly as it does today. This is purely additive.

## Public API

```swift
// swift/Sources/ZeroMcp/Registry.swift
// module ZeroMcp

/// One tool exposed as an HTTP-style route.
/// Named `RegistryRoute` (not `RouteDefinition`) because `RouteDefinition`
/// is already taken — it's the existing `{ method, path }` struct attached
/// to a tool (Tool.swift:46). This type is the registry's richer route
/// *entry*: the route metadata plus the tool it belongs to.
public struct RegistryRoute {
    public let name: String
    public let method: String   // uppercased, e.g. "GET" — matches RouteDefinition.method
    public let path: String     // ":param" segments, unmatched — matches RouteDefinition.path
    public let tool: ToolDefinition
}

/// Signature of the registry's JSON-RPC handler. Matches
/// `ZeroMcp.handleRequest(_:)` exactly (untyped dictionaries — this
/// codebase has no JsonRpcRequest/JsonRpcResponse types to reuse or port).
public typealias McpHandler = (_ request: [String: Any]) async -> [String: Any]?

public struct RegistryOptions {
    /// Config used to build the internal dispatch instance (title for
    /// OpenAPI info, executeTimeout default, etc). Defaults to an empty
    /// ZeroMcpConfig() — NOT ZeroMcpConfig.load(), which reads
    /// ./zeromcp.config.json from the current working directory as a
    /// side effect. An embeddable library must not do ambient
    /// filesystem I/O by default; pass ZeroMcpConfig.load() explicitly
    /// if that behavior is wanted.
    public var config: ZeroMcpConfig

    public init(config: ZeroMcpConfig = ZeroMcpConfig()) {
        self.config = config
    }
}

public struct Registry {
    public let routes: [RegistryRoute]
    public let openapi: [String: Any]
    public let mcp: McpHandler
}

/// Build a framework-neutral registry from a plain tool map.
///
/// `tools` uses the same `ToolDefinition` struct the `.tool()` builder on
/// `ZeroMcp` produces internally (Tool.swift:56) — construct it directly
/// via `ToolDefinition(description:input:permissions:route:execute:)`
/// without going through a `ZeroMcp` instance's builder DSL.
public func createRegistry(
    _ tools: [String: ToolDefinition],
    options: RegistryOptions = RegistryOptions()
) -> Registry
```

### Behavior

- `tools` is a plain `[String: ToolDefinition]` map — the same struct type already used everywhere in the module (`description`, `input`, `cachedSchema`, `permissions`, optional `route`, `execute`). There is no separate lightweight "Tool" shape to define; `ToolDefinition`'s public initializer already is the plain-data constructor a consumer needs.
- **No `getEnv`/env-injection option, unlike Node.** Node's `Tool<TEnv>.execute(args, env: TEnv)` bakes a caller-suppliable generic environment into the type signature, so `RegistryOptions<TEnv>.getEnv` exists to supply that value on the `mcp` path where there's no per-request framework context. Swift's `ToolDefinition.execute` is typed `([String: Any], ToolContext) async throws -> Any` (Tool.swift:69) — the second parameter is always the framework's own `ToolContext` (`toolName`, `permissions`, and a `credentials: Any?` field that, per a grep of every existing tool in the repo — `Example`, `CredentialTest`, `RouteTest`, etc. — is never actually populated by any caller; tools that need ambient secrets today capture them via closures over environment variables at registration time, e.g. `CredentialTest/main.swift:7`). There is no caller-suppliable "env" concept to port. `RegistryOptions` therefore only carries `config`.
- `createRegistry` builds an internal, non-exposed `ZeroMcp(config: options.config)` instance and assigns `instance.tools = tools` directly. This is legal because `ZeroMcp.tools` has no access modifier (Server.swift:9), i.e. it's `internal`, and `Registry.swift` lives in the same module — no need to route through the public `.tool()` builder. This reuses the real dispatch, not a reimplementation:
  - `mcp` is `{ request in await instance.handleRequest(request) }`, wrapping the existing `public func handleRequest(_ request: [String: Any]) async -> [String: Any]?` (Server.swift:109) as-is. `initialize`, `ping`, `tools/list`, `tools/call`, and the passthrough methods all work unmodified. `resources/*` and `prompts/*` also work and correctly report empty lists, since the internal instance's `resources`/`prompts` maps are simply never populated — no special-casing needed.
  - `openapi` is computed once, eagerly, at `createRegistry` call time by calling `instance.buildOpenApiSpec()` — the exact function `serveHttp`'s `/openapi.json` route already calls (HttpServer.swift:157, `buildOpenApiSpec()` defined at HttpServer.swift:224). **This requires one visibility change to existing code**: `buildOpenApiSpec()` is currently `private func` inside the `ZeroMcp` extension in `HttpServer.swift`; it must become `internal` (drop the `private` keyword) so `Registry.swift`, in the same module, can call it on the internal instance. No logic changes — access level only. `extractPathParams`, `matchRoutePath`, and `buildSwaggerHtml` stay `private`; the registry doesn't need them directly (they're already called from inside `buildOpenApiSpec`/`dispatchHttpRequest` where needed).
  - `routes` is derived by filtering `tools` down to entries with a non-nil `route`, mapped to `RegistryRoute(name:method:path:tool:)`, **sorted by name**. Unlike Node's `Object.entries`, Swift's `[String: ToolDefinition]` has no defined iteration order — sorting is required for a deterministic, reproducible `routes` array, and matches the sorting convention `buildOpenApiSpec` and `handleToolsList` already use (`tools.sorted(by: { $0.key < $1.key })`).
- No HTTP routing, path-param extraction, query parsing, or body parsing is done by the registry. The caller turns each `RegistryRoute` into a framework-specific handler themselves: match `route.method`/`route.path` (translating `:param` segments however their router expects — Vapor uses `:param` already; Hummingbird uses `:param` too; a raw path matcher can reuse the `:param`-splitting logic pattern from `HttpServer.swift`'s private `matchRoutePath`, which is not exposed and would need its own small reimplementation or a similar visibility change if a caller wants to reuse it verbatim — left to the caller), extract args, then call `route.tool.execute(args, ctx)` with whatever `ToolContext` they construct (including, if they want, a real `credentials` value — the field exists and is plumbed through unchanged, just currently unused by the framework itself).
- No auth hook. Matches Node's framework-neutral version exactly — auth is the caller's framework's concern (Vapor middleware, a Lambda authorizer, etc.), not the registry's.

### Non-goals

- Does not replace or call into `serveHttp`'s POSIX-socket HTTP server. `serveHttp` is unchanged.
- Does not do any HTTP request/response handling, routing, or body parsing — it hands back data (`routes`), not wired handlers.
- Does not depend on any HTTP framework (no Vapor, no Hummingbird imports).
- Does not change `ToolContext`, `ToolDefinition`, `Permissions`, or `RouteDefinition` (the existing `{ method, path }` struct) — reused as-is.
- Does not add actor isolation, locks, or `Sendable` conformance to `ZeroMcp` or to the registry's types. See "Concurrency notes" below — this is an explicit scope boundary, not an oversight.

### Concurrency notes

- `swift/Package.swift` declares `swift-tools-version: 5.9` and nothing in `swift/Sources` uses `Sendable`, `@preconcurrency`, or `actor` (verified by grep). The module is compiled under the default, non-strict Swift 5 concurrency mode, so none of the following is compiler-enforced today — it's a design/risk note, not a build error.
- `ToolDefinition.execute` is `@escaping ([String: Any], ToolContext) async throws -> Any` — not `@Sendable`. `[String: Any]` and `Any` can't conform to `Sendable` in general (heterogeneous JSON payloads), so `RegistryRoute`, `Registry`, and `McpHandler` should **not** be declared `Sendable`: doing so wouldn't compile under strict concurrency without much larger changes to `ToolDefinition`/`ToolContext` that are out of scope for this port.
- `ZeroMcp` is a plain `class`, not an `actor`, and its mutable state (`tools`, `resources`, `subscriptions`, `roots`, `clientCapabilities`, `logLevel`) is already accessed without synchronization from concurrently-spawned `Task`s in `serveHttp` (`Task { await self.handlePosixConnection(fd: clientfd) }` per accepted connection, HttpServer.swift:50) — a pre-existing, unfixed data-race risk in the shipped server, not something this port introduces. `createRegistry`'s internal `ZeroMcp` instance inherits the same risk: its `mcp` closure captures a plain class reference, and if the caller's framework (Vapor, Hummingbird, a Lambda runtime with concurrent invocations) drives `mcp` from multiple concurrent tasks, the same unsynchronized-mutation risk applies — arguably with *higher* real-world likelihood than the built-in server, since embedding into a general-purpose HTTP framework is more likely to see genuine concurrent request handling than ZeroMCP's own accept loop.
- No `@preconcurrency` import is needed for `Registry.swift` — it consumes the same non-Sendable, non-strict-checked types (`ToolDefinition`, `ToolContext`, `[String: Any]`) that every other file in the module already does, under the same language mode.
- Recommendation (not required for this port): if/when `ZeroMcp` is hardened for concurrent use — e.g. by converting it to an `actor` — the registry's internal instance would benefit for free, since `handleRequest` and `buildOpenApiSpec` are already `async`-callable and would compose naturally with actor isolation. Flagged as a follow-up, not a blocker: fixing `ZeroMcp`'s existing concurrency posture is a larger, separate change than adding the registry.

## Packaging

- New source file: `swift/Sources/ZeroMcp/Registry.swift`, added to the existing `ZeroMcp` library target (`Package.swift`'s `.target(name: "ZeroMcp", path: "Sources/ZeroMcp")` already globs the whole directory — no `Package.swift` edit needed to add the file itself).
- Unlike Node.js (which needed a new `"./registry"` subpath export in `package.json`), Swift Package Manager has no submodule/subpath export mechanism: anything `public` under `Sources/ZeroMcp` is automatically part of the `ZeroMcp` module's surface via a single `import ZeroMcp`. No `Package.swift` changes are needed beyond the new file existing.
- Two small, additive modifications to existing files are required (visibility only, no logic changes):
  1. `HttpServer.swift`: `private func buildOpenApiSpec() -> [String: Any]` → `func buildOpenApiSpec() -> [String: Any]` (drop `private`, making it `internal`).
  2. None elsewhere — `ZeroMcp.tools` is already internal-accessible, and `handleRequest(_:)` is already `public`.
- No new dependencies. `Package.swift`'s `targets` array gains no new entries; no third-party HTTP framework is imported by `Registry.swift`.
- Consumers write `import ZeroMcp` and call `createRegistry(tools)` as a free function — matching the free-function convention Go/Rust use for this feature (`NewRegistry`/`create_registry`), rather than a static method namespaced under the `ZeroMcp` type, since Swift free functions in an imported module are already called unqualified and there's no ambiguity to resolve.

## Porting notes

Cross-checked against the three reusable pieces the Node spec calls out (`specs/lang/nodejs/registry.md`, "Porting notes for other languages"), mapped to their actual Swift names:

1. **`Tool` type with optional `route`** → already exists as `ToolDefinition` / `RouteDefinition` in `swift/Sources/ZeroMcp/Tool.swift`, added by the repo-wide commit `6cab7ef` ("Add route field — REST endpoints alongside /mcp, all 10 languages"). Reused unmodified.
2. **Dispatch/state machinery** → `ZeroMcp.handleRequest(_:)` (Server.swift:109). Unlike Node's `createState`/`handleRequest`, which are free functions decoupled from any server instance (letting `registry.ts` build a fresh, tools-only `state`), Swift's dispatch is an instance method on the monolithic `ZeroMcp` class that also owns resources/prompts/roots/etc. The port works around this by constructing a private internal `ZeroMcp` instance scoped to just the given tools (see "Behavior" above) rather than extracting a decoupled dispatch function — this reuses the literal existing method with zero duplication, at the cost of carrying along inert resources/prompts machinery (which report correctly as empty). Extracting a truly decoupled dispatch core (mirroring Node's `dispatch.ts`) would be a larger, separate refactor and is not required for this port.
3. **OpenAPI-building routine** → `buildOpenApiSpec()` in `HttpServer.swift:224`, added by commit `a551255` ("Add /openapi.json and /docs"). Reused via a visibility change (`private` → `internal`) rather than duplicated. Node's own implementation was fixed to match this same discipline: the first shipped `nodejs/src/registry.ts` contained its *own* copy of the OpenAPI builder, independently diverged from `server.ts`'s copy (it silently dropped path-parameter documentation for non-GET routes). That was fixed by extracting one shared `src/openapi.ts` used by both `registry.ts` and `server.ts` — see `specs/lang/nodejs/registry.md`'s "Fixed since the original as-built version" section.

## Fixed: existing `buildOpenApiSpec()` had the same non-GET path-param bug as Node

Auditing all 10 languages for the Node bug above found the exact same bug already shipped in Swift's own `buildOpenApiSpec()` (`HttpServer.swift:224`, pre-dating this registry spec entirely — it's used by `serveHttp`'s `/openapi.json` today). For a non-GET route with a `:param` segment (e.g. `PUT /items/:id`), the `isBodyMethod` branch (`HttpServer.swift:244-256`, prior to this fix) built `requestBody` from *every* `schema.properties` key, including path-param ones, and never added a `parameters` array for them at all — `:id` was undocumented as a path parameter and silently duplicated into the JSON body schema instead.

**Fixed directly** (not just specified) in `HttpServer.swift`: the `isBodyMethod` branch now filters `pathParams` out of both `props` and `bodyRequired`, and — when `pathParams` is non-empty — adds a `parameters` array documenting each as `{ name, in: "path", required: true, schema: { type: "string" } }`, matching the GET branch's existing path-parameter shape. Verified with `swift build` (all targets, including `RouteTest`, compile clean). This means the Swift port's reuse of `buildOpenApiSpec()` (point 3 above) now gets the corrected behavior for free — no divergent logic for the registry to carry.

Open questions / judgment calls made in this spec, flagged for whoever implements it:
- **Naming collision**: Swift already has a public `RouteDefinition` struct (`{ method, path }`, attached to `ToolDefinition.route`). Node's registry type of the same name (`RouteDefinition<TEnv>`, i.e. `{ name, method, path, tool }`) can't reuse that name without colliding. This spec names the new type `RegistryRoute`. If a different name is preferred (`ToolRoute`, `MountedRoute`), it's a pure rename with no other design impact.
- **No `getEnv` analog**: confirmed by grepping every existing tool example in `swift/Sources/*Test/main.swift` and `Example/` that `ToolContext.credentials` is always `nil` in practice today — nothing in the codebase sets it. This spec concludes Swift doesn't need an env-injection option on `RegistryOptions` at all (see "Behavior"). If a future consumer needs per-request credential injection through the `mcp` path specifically (not just through directly-called `routes`), that would require threading an optional credentials provider into `ZeroMcp`'s private `callTool` — a small additive change, deliberately left out of this spec's scope since nothing today exercises that field.
- **`routes` ordering**: this spec sorts `routes` by tool name for determinism, since Swift dictionaries (unlike Node's `Object.entries`, which preserves insertion order) have no defined iteration order. This is a behavioral difference from Node worth being aware of if any conformance test compares route ordering across languages.
- **`RegistryOptions.config` default**: defaults to an empty `ZeroMcpConfig()`, not `ZeroMcpConfig.load()`. `ZeroMcp()`'s own default constructor (Server.swift:25-27) *does* call `ZeroMcpConfig.load()`, which reads `./zeromcp.config.json` off disk. This spec deliberately does not inherit that default for the registry, since ambient CWD file reads are a poor default for an embeddable library entry point — callers who want config-file behavior can pass `RegistryOptions(config: .load())` explicitly.
