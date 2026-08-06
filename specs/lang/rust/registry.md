# Framework-neutral tool registry — Rust

## Status

**Spec — not yet implemented.** This document is the Rust port plan for the framework-neutral tool registry that shipped in Node.js (`nodejs/src/registry.ts`, see `specs/lang/nodejs/registry.md`). Nothing described here exists in `rust/src/` yet.

## Motivation

`rust/src/server.rs`'s `Server::serve_http` already mounts tool `route` definitions onto its own hand-rolled POSIX-socket HTTP loop and serves `/openapi.json` (via `Server::build_openapi`). That's fine for `zeromcp serve`, but it locks route + OpenAPI generation inside `Server`'s own accept loop (`handle_http_conn`) — a consumer who wants ZeroMCP tools inside `axum`, `actix-web`, `warp`, a Lambda handler, or a Cloudflare Worker via `worker-rs` has no way to reuse that logic without depending on `zeromcp::Server` running its own listener.

The Node registry solved this by returning a plain data structure (`routes`, `openapi`, `mcp`) instead of registering routes on a framework instance, and by reusing the same dispatch (`createState`/`handleRequest`) and OpenAPI-building code the built-in server already had. The Rust port follows the same shape: a second, additive entry point, `zeromcp::registry::create_registry`, that reuses `Server`'s existing dispatch (`Server::handle_request`) and OpenAPI generation (`Server::build_openapi`) rather than reimplementing either.

This is **additive** — `Server::serve_http`'s built-in HTTP transport is unchanged. The registry is a second way to consume the same tools.

## Public API

New module `rust/src/registry.rs`:

```rust
use crate::types::{Ctx, RouteConfig, Tool};
use crate::config::Config;
use serde_json::Value;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

/// The boxed future returned by the `mcp` handler.
type McpFuture = Pin<Box<dyn Future<Output = Option<Value>> + Send>>;

/// A JSON-RPC handler: `request -> Option<response>` (`None` for notifications).
/// `Arc`-wrapped (not `Box`) so it can be cloned cheaply into multiple route
/// closures/handlers (e.g. one per axum route) without cloning the underlying
/// `Server`.
pub type McpHandler = Arc<dyn Fn(Value) -> McpFuture + Send + Sync>;

/// One tool exposed as an HTTP route. Mirrors `RouteConfig` (`method`, `path`)
/// plus the tool name and a shared handle to the tool itself so the caller
/// can invoke it directly.
pub struct RouteDefinition {
    pub name: String,
    pub method: String,
    pub path: String,
    pub tool: Arc<Tool>,
}

/// A framework-neutral view over a set of tools: route metadata, a
/// pre-built OpenAPI document, and a JSON-RPC handler — all derived from
/// the same dispatch/OpenAPI code `Server` uses internally.
pub struct Registry {
    pub routes: Vec<RouteDefinition>,
    pub openapi: Value,
    pub mcp: McpHandler,
    config: Config,
}

impl Registry {
    /// Build the `Ctx` that `Server::call_tool` would build for `tool` —
    /// same `permissions`, `logging`, and `bypass` — so a route handler
    /// calling `tool.execute` directly gets identical sandbox behavior to
    /// going through `mcp` or the built-in HTTP server. Always use this
    /// (or construct an equivalent `Ctx`) instead of `Ctx::default()`.
    pub fn ctx_for(&self, tool: &Tool) -> Ctx { /* ... */ }
}

/// Build a `Registry` from a set of named tools (same `Tool` type used by
/// `Server::tool`). Every tool is dispatchable through `mcp`; only tools
/// with a `route` appear in `routes`.
pub fn create_registry<I, S>(tools: I) -> Registry
where
    I: IntoIterator<Item = (S, Tool)>,
    S: Into<String>,
{ /* ... */ }
```

### Behavior

- `tools` is any iterable of `(name, Tool)` pairs — the same `Tool` struct (`description`, `input`, `permissions`, `execute`, `cached_schema`, `route`) already used by `Server::tool`. `create_registry` takes ownership of each `Tool` (it holds a non-`Clone`-able `Box<dyn Fn>` in `execute`, so it must be moved, not borrowed) and registers it into an internal `Server` via the existing `Server::tool` method — the same call `Server::tool()`/`add_tool()` already use, including permission validation (`validate_permissions`) and `cached_schema` population.
- `create_registry` builds one internal `Server` (via `Server::new()`, i.e. `Config::default()`, no resources/prompts registered) and:
  - Computes `openapi` **once**, at construction time, by calling the existing `Server::build_openapi(&self) -> Value` — no reimplementation of the `:param` → `{param}` conversion, GET-parameters-vs-request-body logic, etc. It's the exact same method `/openapi.json` calls.
  - Wraps the `Server` in `Arc<Server>` and builds `mcp` as a closure that clones the `Arc` and calls the existing `Server::handle_request(&self, request: &Value) -> Option<Value>` — the same dispatch used by both the stdio transport (`Server::serve`) and the HTTP `/mcp` route (`handle_http_conn`). No new JSON-RPC parsing/dispatch logic.
  - Derives `routes` by iterating the internal tool map and keeping only entries with `tool.route.is_some()`, flattening each into a `RouteDefinition { name, method, path, tool }`.
- `routes` iteration order is alphabetical by tool name (`BTreeMap` order), not registration order — this is a deliberate, pre-existing Rust-vs-Node divergence: every other list-producing method on `Server` (`tools/list`, `resources/list`, etc.) already iterates its `BTreeMap` fields the same way, so `routes` stays consistent with that convention rather than trying to preserve Node's `Object.entries` insertion order.
- No `getEnv`/`TEnv` generic, unlike Node. Node's `Tool.execute` is generic over a caller-supplied `TEnv` because JS has no built-in per-call context; Rust's `Tool.execute: ExecuteFn` already takes a fixed `Ctx` (`permissions`, `logging`, `bypass`) as its second argument, and `Server::handle_request` → `call_tool` already builds that `Ctx` correctly for every `mcp`-dispatched call. There is nothing left for a `RegistryOptions`/`getEnv`-equivalent to supply on the `mcp` path, so `create_registry` takes no options argument.
- For the `routes` path, however, the caller bypasses `Server::call_tool` entirely (they call `route.tool.execute(args, ctx)` themselves from their own framework handler), so **they**, not `Server`, are responsible for supplying `Ctx`. Using `Ctx::default()` there would silently defeat sandboxing (`Permissions::default()` = unrestricted network, no fs, no exec) regardless of what the tool actually declared. `Registry::ctx_for(&self, tool: &Tool) -> Ctx` exists specifically to close this gap: it builds `Ctx { permissions: tool.permissions.clone(), logging: <registry's config.logging>, bypass: <registry's config.bypass_permissions> }`, identical to what `Server::call_tool` builds internally. Route-handler code should always go through it (or replicate it) rather than hand-roll a `Ctx`.
- `mcp` operates on `serde_json::Value` in both directions, matching `Server::handle_request`'s existing signature — there's no `JsonRpcRequest`/`JsonRpcResponse` struct in the Rust codebase (unlike Node's `dispatch.ts` types) and introducing one is out of scope for this port; reuse `Value`.
- No auth hook, same as Node — auth is the caller's framework's concern (an axum middleware/layer, an actix-web guard, etc.), not the registry's.

### Non-goals

- Does not replace or call into `Server::serve_http`'s built-in HTTP transport (`handle_http_conn`, `TcpListener` accept loop).
- Does not do any HTTP request/response handling, path/query extraction, or body parsing — `RouteDefinition` is data (`name`, `method`, `path`, `tool`); turning it into a live route on `axum`/`actix-web`/`warp`/a Lambda handler is the caller's job, exactly as in Node.
- Does not depend on any HTTP framework crate. No `axum`, `actix-web`, `hyper`, etc. added to `Cargo.toml`.
- Does not introduce a generic environment/context type parameter (see "No `getEnv`/`TEnv` generic" above) — this is an intentional simplification versus Node, not a missing feature.

## Packaging

- New source file: `rust/src/registry.rs`.
- Add `pub mod registry;` to `rust/src/lib.rs`'s module list (alongside `config`, `sandbox`, `schema`, `server`, `types`).
- **Do not** re-export `create_registry`/`Registry`/`RouteDefinition`/`McpHandler` at the crate root the way `Server`, `Input`, `Tool`, etc. are re-exported. Consumers reach it via `use zeromcp::registry::{create_registry, Registry, RouteDefinition};` — an explicit, separate import path, mirroring Node's separate `@antidrift/zeromcp/registry` subpath export and reinforcing that this is an optional second entry point, not part of the default `Server`-based surface.
- No new entries in `[dependencies]` in `rust/Cargo.toml`. `registry.rs` only needs `serde_json` (already a dependency), `std::sync::Arc`, `std::future::Future`, and `std::pin::Pin` (all `std`).
- Internal-only change required in `rust/src/server.rs` / `rust/src/types.rs` to make this possible (see Porting notes) — no change to any existing public API or method signature.

## Porting notes

These are the concrete adjustments needed in the existing Rust code to support the registry, found while reading `server.rs`/`types.rs`:

1. **`Server`'s internal tool storage needs to change from `Tool` to `Arc<Tool>`.** Today `Server` stores `tools: BTreeMap<String, Tool>` (private field, `server.rs:15`). `RouteDefinition.tool` needs a handle to the same tool the internal `Server` dispatches through `mcp` — and `Tool` isn't `Clone` (its `execute: ExecuteFn` is a `Box<dyn Fn(...) + Send + Sync>`, which can't be cloned). The fix is to change the field to `pub(crate) tools: BTreeMap<String, Arc<Tool>>` and have `Server::tool()` insert `Arc::new(tool)` instead of `tool`. Because `Arc<Tool>` derefs transparently, every existing use site (`tool.description`, `tool.cached_schema`, `(tool.execute)(args, ctx)` in `call_tool`, the iteration in `handle_tools_list`/`build_openapi`) keeps compiling unchanged — this is a pure storage-representation change, not an API change. `Tool`'s fields (`String`, `Input`, `Permissions`, `ExecuteFn = Box<dyn Fn(...) + Send + Sync>`, `JsonSchema`, `Option<RouteConfig>`) are already `Send + Sync`, so `Arc<Tool>` is safely shareable across the `tokio::spawn`ed connection tasks the same way `Arc<Server>` already is in `serve_http`.
2. **`registry.rs` needs `pub(crate)` visibility into `Server::tools`** to build `routes` — either make the field itself `pub(crate)` (simplest, since `registry.rs` lives in the same crate) or add a `pub(crate) fn tools(&self) -> &BTreeMap<String, Arc<Tool>>` accessor. Either is a small, non-breaking addition; the field/method stays invisible outside the crate.
3. **No changes needed to `Server::handle_request` or `Server::build_openapi` signatures** — both are already `pub fn` / `pub async fn` taking `&self`, which is exactly what `create_registry` needs to wrap in `Arc<Server>` and call from the `mcp` closure and at construction time, respectively.
4. **No `async-trait` or similar dependency needed for `McpHandler`.** `types.rs` already establishes the "manual boxed future" convention (`BoxFuture`, `ReadFuture`, `RenderFuture` are all hand-written `Pin<Box<dyn Future<Output = T> + Send>>` aliases, with closures as `Box<dyn Fn(...) -> BoxFuture + Send + Sync>`). `McpHandler`/`McpFuture` in `registry.rs` should follow the identical pattern, just returning `Option<Value>` instead of `ToolResult`. The one deviation: `McpHandler` itself is `Arc<dyn Fn...>` rather than `Box<dyn Fn...>` (unlike `ExecuteFn`), specifically so `registry.mcp.clone()` is a cheap, `Send + Sync` way to move a handle to the same dispatcher into more than one route registration (e.g. an axum app might mount it at both `/mcp` and, for compatibility, `POST /rpc`) without needing `Arc<Registry>` at the call site.
5. **`Ctx` construction for the `routes` path is the one behavioral gap Node doesn't have** (see "Behavior" above) — flagged here because it's easy to miss when porting: a route handler that does `tool.execute(args, Ctx::default())` compiles fine and looks correct, but silently disables the tool's declared network/fs/exec restrictions. `Registry::ctx_for` exists to make the correct behavior the easy behavior.
6. Existing route/OpenAPI conformance tests (`tests/conformance/run-route.js`, `rust/examples/route_test.rs`) exercise `Server::serve_http`, not the registry, and don't need changes for this feature — they're testing a different entry point to the same underlying `route`/`build_openapi` machinery this spec reuses.

## Fixed: existing `build_openapi` had the same non-GET path-param bug as Node

Auditing all 10 languages for the Node bug above (see `specs/lang/nodejs/registry.md`'s "Fixed since the original as-built version" and `specs/lang/swift/registry.md`'s equivalent section) found the exact same bug already shipped in Rust's own `Server::build_openapi` (`rust/src/server.rs`, prior to this fix the non-GET branch spanned roughly lines 671-700 — it's used by `serve_http`'s `/openapi.json` route today, and is also the exact method this spec's `create_registry` plans to reuse verbatim for its `openapi` field, per point 3 in "Porting notes" above). For a non-GET route with a `:param` segment (e.g. `PUT /items/:id`), the `else` (non-GET) branch built the request body's `properties` from *every* key in `schema.properties`, including path-param ones, and never emitted a `"parameters"` array documenting them as path parameters at all — `id` was undocumented as a path parameter and silently duplicated into the JSON request body schema instead. The `path_params: Vec<String>` local was already computed a few lines above the GET/else split and used correctly by the GET branch (`server.rs:646-660`); the `else` branch simply never consulted it.

**Fixed directly** (not just specified) in `rust/src/server.rs`'s `build_openapi` non-GET branch (now roughly lines 671-722): the `properties` loop now `continue`s past any `pname` that's in `path_params`, `schema.required` is filtered the same way when building the body's `required` array, and — when `path_params` is non-empty — a `"parameters"` array is added alongside `"requestBody"` on the operation object, one entry per path param, matching the GET branch's shape: `{"name": <name>, "in": "path", "required": true, "schema": {"type": "string"}}`. The GET branch (`server.rs:646-670`) and the `"openapi"`/`"version"` fields at the bottom of the function are unchanged.

Verified with `cd rust && cargo build` (clean) and `cargo test` (75 unit tests + 7 integration tests pass, including a new unit test, `build_openapi_put_route_documents_path_param_separately` in `server.rs`'s `#[cfg(test)] mod tests`, that registers a `PUT /items/:id` tool and asserts the fixed shape: a one-entry `parameters` array with `"in": "path"`, and a body schema whose `properties`/`required` exclude `id` but retain the tool's other field).

This means the registry's `openapi` field (point 3, "Behavior" above — computed once via `Server::build_openapi`) gets the corrected non-GET path-param behavior automatically once `create_registry` is implemented; there is no divergent OpenAPI-building logic for the registry to carry or re-fix.
