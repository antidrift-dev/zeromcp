# Framework-neutral tool registry — Go

## Status

**Spec — not yet implemented.** This document is the Go port design for the framework-neutral tool registry shipped in Node.js (`nodejs/src/registry.ts`, see `specs/lang/nodejs/registry.md`). Nothing in this file exists in `go/` yet; it's a design for a Go engineer to implement.

## Motivation

Go's built-in HTTP server (`go/pkg/zeromcp/server.go`, `(*Server).serveHTTP`) already mounts tool `Route` fields onto its own `http.ServeMux` (`handleToolRoute`) and serves `/openapi.json` (`buildOpenAPISpec`). That's the right shape for `zeromcp.Serve()`, but it locks route dispatch and OpenAPI generation inside the built-in server loop — a consumer who wants ZeroMCP tools inside `net/http`, `chi`, `gin`, an AWS Lambda handler, or a Cloudflare Worker (via a Go→Wasm build) has no way to reuse that logic without also taking the built-in mux, CORS handling, and port binding.

Node solved this with a framework-neutral `createRegistry(tools, options)` that returns plain data (`routes`, `openapi`, `mcp`) instead of mutating a framework instance. This spec ports the same *shape* to Go, adapted to Go's existing API: Go's `Server` is already the place where tools are registered (`(*Server).Tool`), permissions are validated (`ValidatePermissions`), and per-tool sandboxed execution context is built (`NewContext`) — a freestanding constructor taking a raw `map[string]Tool` (mirroring Node's signature literally) would have to duplicate all of that setup. Instead, the Go port adds a **new accessor method on `*Server`**: `(*Server).Registry()`, which derives a framework-neutral view from the tools already registered on that `Server` via the existing `Tool()` method, reusing 100% of the existing dispatch and OpenAPI code with no duplication.

This is **additive** — `(*Server).Serve()` and its built-in HTTP transport are unchanged. `Registry()` is a second, composable way to consume a `*Server`'s tools: build the server, register tools with `Tool()` as usual, then call `Registry()` instead of (or in addition to) `Serve()`.

## Public API

New file: `go/pkg/zeromcp/registry.go`, package `zeromcp` (same package as `server.go` — no new import path).

```go
// RouteDefinition pairs a tool that has a Route with everything an external
// HTTP framework needs to mount it: identity, route metadata, the input
// shape, and a ready-to-call invoke function.
type RouteDefinition struct {
	Name        string
	Route       RouteConfig // the tool's Route, dereferenced (never nil here)
	Description string
	Input       Input
	Invoke      func(args map[string]any) (any, error)
}

// Registry is a framework-neutral view over a Server's registered tools:
// route metadata for mounting on an external HTTP framework, a precomputed
// OpenAPI document, and a JSON-RPC handler for MCP. It starts no transport
// and binds no port.
type Registry struct {
	Routes  []RouteDefinition
	OpenAPI map[string]any
	MCP     func(raw []byte) []byte
}

// Registry builds a framework-neutral Registry snapshot from the tools
// currently registered on s via Tool(). Call it after all Tool() (and,
// if used, Resource()/Prompt()) registrations are done — the same point
// in program order you'd otherwise call Serve(). Registry does not start
// stdio or HTTP transports; it's an alternative to Serve() for embedding
// ZeroMCP's tools into your own HTTP framework instead of using the
// built-in server.
func (s *Server) Registry() *Registry
```

### Behavior

- `Registry()` reuses the exact same machinery `Serve()` already uses, with no duplicated logic:
  - `Routes` is built from the already-registered `s.tools` map (populated by `(*Server).Tool`, which already runs `ValidatePermissions` and builds the per-tool sandboxed `*Ctx` via `NewContext` — none of that setup is re-run or duplicated by `Registry()`; it just reads what `Tool()` already built).
  - `OpenAPI` is exactly `s.buildOpenAPISpec()` — the same unexported method that backs the built-in server's `GET /openapi.json` route (`server.go:975`). No second OpenAPI builder is written.
  - `MCP` is a bound method value of `s.HandleRequestBytes` (`server.go:457`) — the same byte-in/byte-out JSON-RPC entrypoint already used by both the stdio transport (`serveStdio`) and the HTTP transport's `POST /mcp` handler. `Registry()` does not reimplement `handleRequest`/`callTool`; it hands back a reference to the live dispatcher.
    - Because `MCP` is bound to the live `*Server`, it reflects the *current* state of `s` at call time (including tools registered after `Registry()` was called), not a frozen snapshot. `Routes` and `OpenAPI`, by contrast, are computed once, at the moment `Registry()` is called. In normal usage (all `Tool()` calls happen before `Registry()`, same as before `Serve()`) this distinction doesn't matter; it's called out here because it's a real difference from Node's `createRegistry`, where `routes`, `openapi`, and `mcp` are all derived from one static snapshot of the `tools` map taken at construction time. Don't call `Tool()` again after `Registry()` and expect `Routes`/`OpenAPI` to pick it up — call `Registry()` again instead.
  - Since Go's dispatcher (`handleRequest`) is the same one used for the whole protocol, `MCP` also serves `resources/*`, `prompts/*`, `logging/setLevel`, and `completion/complete` if the `Server` has any resources/prompts registered — it isn't scoped to tools-only the way Node's `registry.mcp` is (Node's `createState` is built from just the `tools` map it's given, with no resources/prompts support at all). This is a deliberate, accepted superset: a `Registry()` view of a `Server` that also has resources/prompts wired up will expose the full protocol through `MCP`, not a tools-only subset.
- `Routes` is derived by locking `s.mu.RLock()`, iterating `s.tools`, and keeping only entries where `tool.Route != nil` — same filter condition already used by `handleToolRoute` (`server.go:925`) and `buildOpenAPISpec` (`server.go:992`). **Unlike** Node (where `Object.entries` preserves insertion order on the source object), Go map iteration order is randomized, so `Routes` must be built by first collecting and `sort.Strings`-ing the tool names, then appending in that order — the same pattern `buildToolList` and `buildOpenAPISpec` already use for deterministic output. Do not rely on map iteration order.
- `RouteDefinition.Invoke` closes over the tool's own `registeredTool.tool.Execute` and its pre-resolved `registeredTool.ctx` (the sandboxed `*Ctx` built once by `Tool()` via `NewContext`, carrying resolved credentials and network permissions):
  ```go
  Invoke: func(args map[string]any) (any, error) {
      return rt.tool.Execute(args, rt.ctx)
  }
  ```
  This mirrors exactly what `handleToolRoute` does today (`server.go:961`: `rt.tool.Execute(args, rt.ctx)`) — **no schema validation and no `ExecuteTimeout` enforcement**, unlike the `tools/call` path (`callTool`, `server.go:830`), which does validate against `cachedSchema` and enforce a timeout. This is a pre-existing asymmetry in `server.go` between routed-HTTP dispatch and JSON-RPC `tools/call` dispatch, not something introduced by this spec — `Invoke` intentionally preserves it so that a tool mounted via `Registry().Routes` behaves identically to the same tool mounted via the built-in server's own route dispatch. If that asymmetry is ever fixed, fix it in `handleToolRoute` and `Invoke` together so they don't diverge.
  - `*Ctx`'s fields (aside from the exported `Credentials any`) are unexported, so a `*Ctx` resolved for one tool cannot be usefully reconstructed by a caller outside the package. That's why `RouteDefinition` exposes a pre-bound `Invoke func(map[string]any) (any, error)` rather than the raw `Tool` + a `*Ctx` the way Node's `RouteDefinition.tool.execute(args, env)` does — Go has no public constructor for a fully-resolved, credential-bearing `*Ctx` outside `Server.Tool()`, so binding it inside `Invoke` is the only way to hand the caller something callable.
  - No equivalent of Node's `RegistryOptions.getEnv` is needed: Node calls `options.getEnv()` fresh on every `execute` because Node's `env` is a lightweight, per-registry value with no setup cost. Go's `*Ctx` is heavier (resolved credentials, sandboxed HTTP client, permission set) and is already resolved exactly once, at `Tool()` registration time — reusing it per call is both correct and required (that's what the built-in route dispatch already does). There is no `RegistryOptions` type in this port; `Registry()` takes no arguments.
- The caller's own framework (Express-equivalent in Go: `net/http`, `chi`, `gin`, a Lambda handler, etc.) is responsible for turning each `RouteDefinition` into a wired handler: matching `Route.Method`/`Route.Path` (`:param` syntax, same as `RouteConfig.Path` today), extracting path/query params or the request body into a `map[string]any`, calling `Invoke(args)`, and mapping the `(any, error)` result to a response. `Registry()` does none of that itself — same non-goal as Node.
- No auth hook, same as Node — auth is the caller's framework's concern. Go's built-in server's own `Bearer` token check (`ResolveAuth`, used in `serveHTTP`) is not part of `Registry()` and is not invoked when using it.

### Non-goals

- Does not replace or call into `(*Server).Serve()` / `serveHTTP` / `serveStdio`. Calling `Registry()` starts no listener and binds no port.
- Does not do any HTTP request/response handling, routing, path-param extraction, or body parsing — `Routes` is data plus a bound `Invoke` function, not wired handlers.
- Does not add a dependency on any HTTP framework or router package. `registry.go` imports only what `server.go` already imports (`sort`, `sync` via the existing `Server`) — no new module dependencies, matching the "no new external dependencies" constraint from the Node port.
- Does not validate `Invoke` input or enforce a timeout (see the asymmetry note above) — this is intentional parity with today's `handleToolRoute`, not a gap to fill as part of this port.

## Packaging

Unlike Node — which needed a new `package.json` subpath export (`"./registry"`) because `registry.ts` and `server.ts` are separate files a consumer might import independently, and which removed the `hono` dev/peer dependency as part of going framework-neutral — Go has no equivalent packaging step:

- `registry.go` lives in the same package (`zeromcp`) and the same module (`github.com/antidrift-dev/zeromcp`) as `server.go`. Consumers already import `github.com/antidrift-dev/zeromcp/pkg/zeromcp` for `NewServer`/`Tool`/`Serve`; `Registry` and `RouteDefinition` become available on that same import with no new import path and no `go.mod` changes.
- No dependency to remove — `go/pkg/zeromcp` has never taken on an HTTP-framework dependency (its built-in server uses only `net/http` from the standard library), so there's nothing analogous to the `hono` removal in commit `e3b134b`.
- Usage sketch for a consumer embedding into their own `net/http` mux, for concreteness (not part of the implementation, illustrative only):
  ```go
  s := zeromcp.NewServer()
  s.Tool("greet", zeromcp.Tool{
      Description: "Greet a person by name",
      Input:       zeromcp.Input{"name": "string"},
      Route:       &zeromcp.RouteConfig{Method: "GET", Path: "/greet/:name"},
      Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
          return fmt.Sprintf("Hello, %s!", args["name"]), nil
      },
  })
  reg := s.Registry() // instead of s.Serve()
  // caller's own router wires reg.Routes, serves reg.OpenAPI at /openapi.json,
  // and mounts reg.MCP at POST /mcp — all inside the caller's own mux/middleware stack.
  ```

## Porting notes / deviations from the Node design

These are the judgment calls made in adapting Node's `createRegistry(tools, options)` shape to Go, for whoever implements this:

1. **Method on `*Server`, not a freestanding constructor.** Node's `Tool` map is a plain, cheap-to-construct object with no setup cost, so `createRegistry(tools, options)` can build its own internal `state` from a raw map without touching `server.ts`. Go's `Tool` registration (`(*Server).Tool`) does real setup — `ValidatePermissions`, `NewContext` (sandboxed HTTP client, resolved credentials), and `ToJsonSchema` caching — and duplicating that inside a freestanding `NewRegistry(tools map[string]Tool, ...)` would mean re-deriving credentials resolution (`Server.ResolveToolCredentials`, `s.cfg.Credentials`) outside the `Server` type, which isn't exposed as a standalone piece. Deriving `Registry` from an already-configured `*Server` via a method sidesteps this entirely and gets full reuse for free. This does mean a Go consumer who wants *only* the registry (never `Serve()`) still constructs a full `*Server` via `NewServer()`/`NewServerWithConfig()` — that's expected and cheap; just don't call `Serve()`.
2. **`RouteDefinition.Route RouteConfig`, not flattened `Method`/`Path` fields.** Reuses the existing exported `RouteConfig` type (`server.go:24`) verbatim instead of re-declaring two fields that would drift from it.
3. **`Invoke func(map[string]any) (any, error)` instead of exposing `Tool` + a `*Ctx`.** See the `*Ctx`-is-unexported rationale above — this is a real API-shape divergence from Node's `RouteDefinition.tool.execute(args, env)`, not a stylistic choice.
4. **No `RegistryOptions`/`getEnv` equivalent.** Go's per-tool execution context is resolved once at `Tool()` time and is already the mechanism Node's `getEnv` approximates per-call; there's nothing left for an options type to configure. If a future need arises (e.g., a per-request-scoped `*Ctx` for a multi-tenant embedding), it should be a new, explicitly-named option added then — don't speculatively add an unused `RegistryOptions` now.
5. **Deterministic `Routes` ordering requires an explicit sort.** Flagged above; easy to miss since Node's object-key order "just works" and Go's doesn't. Follow the existing `sort.Strings(names)` pattern already used in `buildToolList` and `buildOpenAPISpec`.
6. **`MCP` is live, `Routes`/`OpenAPI` are a snapshot.** Flagged above. If this asymmetry turns out to matter in practice (e.g., someone calls `Registry()` before finishing registration), consider documenting a hard precondition ("call `Registry()` last") in the method's doc comment rather than trying to make `Routes`/`OpenAPI` live too, which would require rebuilding them per-access or invalidating a cache — not worth the complexity for a usage pattern (register-then-build) that's already the established convention for `Serve()`.

## Fixed: existing `buildOpenAPISpec` had the same non-GET path-param bug as Node

Auditing all 10 languages for the Node bug above found the exact same bug already shipped in Go's own `buildOpenAPISpec()` (`server.go:975`, pre-dating this registry spec entirely — it's used by the built-in HTTP server's `GET /openapi.json` route today). For a non-GET route with a `:param` segment (e.g. `PUT /items/:id`), the `else` branch (`server.go:1036-1070`, prior to this fix) built the JSON `requestBody` schema from *every* field in `rt.tool.Input`, including path-param ones, and never emitted a `parameters` array for them at all — `id` was undocumented as a path parameter and silently duplicated into the request body schema instead. `pathParamNames` (the same `map[string]bool` the GET branch already used to distinguish path vs. query params) was in scope in the `else` branch but simply unused.

**Fixed directly** (not just specified) in `server.go`: the `else` branch now skips any `fieldName` present in `pathParamNames` when building `props`/`required` for the body schema, and — when `pathParamNames` is non-empty — adds a `parameters` array to `operation`, one entry per path param (sorted via `sort.Strings` for deterministic output, matching the existing convention for `required`), each shaped `{"name": <name>, "in": "path", "required": true, "schema": {"type": "string"}}`, mirroring the GET branch's existing path-parameter shape. Verified with `go build ./pkg/...` and `go test ./...` (both pass), plus a new unit test, `TestBuildOpenAPISpecNonGETPathParam` (`server_test.go`), asserting a `PUT /items/:id` tool now produces a `parameters` array containing `id` and a body schema whose `properties`/`required` exclude it. This means the registry's `OpenAPI` field (which, per "Behavior" above, is exactly `s.buildOpenAPISpec()`) gets the corrected behavior for free — no divergent logic for the registry to carry.
