# Framework-neutral tool registry — Node.js

## Status

**Shipped** (`nodejs/src/registry.ts`, exported as `@antidrift/zeromcp/registry`). This document records the spec as-built so the same shape can be ported to the other 9 languages.

## Motivation

The built-in HTTP server (`nodejs/src/server.ts`) already mounts tool `route` definitions onto its own `node:http` server and serves `/openapi.json`. That's fine for `zeromcp serve`, but it locks route+OpenAPI generation inside ZeroMCP's own server loop — a consumer who wants tools inside Express, Fastify, Hono, a Cloudflare Worker, or a Lambda handler has no way to reuse that logic.

`registry.ts` was added to solve that (commit `f440f41`), first as a Hono-specific `registerTools(tools, app, options)` that mutated a Hono `app` directly. Commit `764af3b` reworked it to be framework-neutral: instead of registering routes on a framework instance, it returns a plain data structure (`routes`, `openapi`, `mcp`) that the caller wires into whatever framework they use. Commit `e3b134b` then dropped the `hono` dependency (dev dependency + peer dependency) entirely, since the module no longer imports Hono types.

This is **additive** — `server.ts`'s built-in HTTP transport is unchanged and still does its own route/OpenAPI handling internally. The registry is a second, composable entry point for embedding.

## Public API

```ts
export type RouteMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE'
export type McpHandler = (request: JsonRpcRequest) => Promise<JsonRpcResponse | null>

export interface Tool<TEnv = Record<string, unknown>> {
  description: string
  input: InputSchema
  route?: { method: RouteMethod; path: string }
  execute: (args: Record<string, unknown>, env: TEnv) => Promise<unknown>
}

export interface RouteDefinition<TEnv = Record<string, unknown>> {
  name: string
  method: RouteMethod
  path: string
  tool: Tool<TEnv>
}

export interface RegistryOptions<TEnv> {
  getEnv?: () => TEnv
  /** Server name/version reported in `initialize` and the OpenAPI `info` block. Defaults to 'ZeroMCP' / '1.0.0'. */
  title?: string
  version?: string
  /** Default per-tool execute timeout in ms, unless a tool overrides it. Defaults to 30_000. */
  executeTimeout?: number
  /** Remote MCP servers to federate. Their tools are merged in as `servername.toolname`; a local tool with the same name overrides the remote one. */
  remote?: RemoteServer[]
}

export interface ToolRegistry<TEnv = Record<string, unknown>> {
  routes: RouteDefinition<TEnv>[]
  openapi: Record<string, unknown>
  mcp: McpHandler
}

export async function createRegistry<TEnv = Record<string, unknown>>(
  tools: Record<string, Tool<TEnv>>,
  options: RegistryOptions<TEnv> = {},
): Promise<ToolRegistry<TEnv>>
```

### Behavior

- `tools` is a plain map of tool name → tool definition, same `Tool` shape used everywhere else (`description`, `input`, optional `route`, `execute`).
- `createRegistry` is **async** (`await createRegistry(...)`) — connecting to `options.remote` servers, if any, requires a round trip before the registry can be built. This is a real signature change from the original as-built version, made before any release shipped with the old sync signature (see "Fixed" below).
- `options.getEnv` supplies the "env" value passed as the second argument to every `execute` call when invoked through `registry.mcp` (there's no per-request framework context on that path). Defaults to `{}`.
- `options.title`/`options.version` set the server name/version surfaced in the `initialize` response's `serverInfo` and the OpenAPI document's `info` block. Default to `'ZeroMCP'` / `'1.0.0'`. `options.executeTimeout` sets the default per-tool execute timeout (still overridable per-tool); defaults to `30_000`ms.
- `options.remote` mirrors `createHandler`'s `config.remote` (`nodejs/src/handler.ts`): a list of `{ name, url, auth? }` remote MCP servers, connected via the existing `RemoteManager` (`nodejs/src/remote.ts`) — same connection/tools-list/proxy-execute logic `createHandler` and `server.ts`'s `serve()` already use, no duplicated federation logic. Remote tools are merged in first, namespaced `servername.toolname`; local `tools` entries are applied on top, so a local tool with the same name silently wins — a `console.error` warning is logged when that happens (matching `createHandler`'s existing "Local tool overrides remote" message). Remote tools never carry a `route` (MCP's `tools/list` has no route concept), so they never appear in `routes` or `openapi` — only in `mcp`'s `tools/list`/`tools/call`.
- `createRegistry` builds an internal `state` via the existing `createState`/`handleRequest` dispatch machinery (the same one `server.ts` uses for stdio/HTTP `/mcp`), so `registry.mcp` is a drop-in JSON-RPC handler: `mcp(request) => Promise<response | null>`.
- `routes` is derived by filtering `tools` down to entries with a `route`, in `Object.entries` order — no route matching or HTTP handling is done here. The caller (Express middleware, Hono app, a Worker's `fetch`, etc.) is responsible for turning each `RouteDefinition` into a framework-specific handler: extracting path/query params, calling `tool.execute(args, env)`, and mapping the result/error to a response. If two tools declare the same `method`+`path`, both still appear in `routes` (which one the caller's own router picks is out of the registry's control), but `createRegistry` logs a `console.error` warning at construction time so the collision isn't silent.
- `openapi` is built by a **shared** module, `src/openapi.ts`'s `buildOpenApiSpec(tools, { title, version })`, used by both `registry.ts` and `server.ts`'s `/openapi.json` — there is exactly one OpenAPI-generation implementation in the package, not two. It operates on each tool's already-computed `cachedSchema` (no redundant re-derivation from `input`). Behavior: `:param` path segments become `{param}` in the OpenAPI path key; **every** route gets a `parameters` entry for its path segments (`in: 'path'`, `schema: { type: 'string' }`), regardless of HTTP method; GET routes additionally get `parameters` for the remaining (non-path) schema fields as `in: 'query'`; non-GET routes additionally get a `requestBody` built from the schema fields that are **not** path parameters — a path param is documented once, as a path parameter, never duplicated into the body schema. This means the registry's OpenAPI doc is generated once and is ready to serve statically — the caller doesn't need to regenerate it per request.
- No auth hook. The earlier Hono-coupled version had an `auth(c, toolName)` callback baked in; the framework-neutral version dropped it — auth is the caller's concern (their framework's middleware), not the registry's.

### Non-goals

- Does not replace or call into `server.ts`'s built-in HTTP server.
- Does not do any HTTP request/response handling, routing, or body parsing — it hands back data (`routes`), not wired handlers.
- Does not depend on any HTTP framework (no Hono, no Express types).

## Packaging

- New source files: `nodejs/src/registry.ts`, `nodejs/src/openapi.ts` (the latter is an internal shared module, not separately exported).
- New subpath export in `package.json`: `"./registry": { "types": "./dist/registry.d.ts", "import": "./dist/registry.js" }`.
- No new runtime dependencies. `hono` was removed from `devDependencies`, `peerDependencies`, and `peerDependenciesMeta` since it's no longer imported anywhere in the package.
- Consumers import it as `import { createRegistry } from '@antidrift/zeromcp/registry'`.
- `nodejs/test/registry.test.js` covers `routes` ordering/shape/collision-warning, `openapi` path-vs-body param placement for both GET and non-GET routes, `mcp` dispatch (`initialize`, `tools/list`, `tools/call`, `getEnv`, `executeTimeout`), and remote federation (merging a real HTTP remote server's tools, local-overrides-remote, remote tools excluded from `routes`/`openapi`) — the last group spins up a real `node:http` server per test, mirroring `nodejs/test/handler-remote.test.js`'s existing pattern for `createHandler`.

## Fixed since the original as-built version

An early review (before this document's current revision) found the first shipped `registry.ts` had its own, independent copy of the OpenAPI builder, duplicated from (and already diverged from) `server.ts`'s copy. The `registry.ts` copy only emitted path-parameter documentation for **GET** routes — a non-GET route like `PUT /items/:id` had its `:id` silently absorbed into the JSON request body schema instead of being documented as a path parameter. Fixed by extracting one shared `buildOpenApiSpec` into `src/openapi.ts`, used by both call sites, with correct path-vs-body param handling for all methods. This changed the OpenAPI *output* for non-GET routes with path params (a bug fix, not a public API/type change — nothing in `ToolRegistry`, `RegistryOptions`, or `createRegistry`'s signature changed shape). Also added: `title`/`version`/`executeTimeout` on `RegistryOptions` (previously hardcoded), a route-collision warning, and reuse of each tool's already-computed `cachedSchema` instead of recomputing it for the OpenAPI doc.

A later review found a second gap: `createHandler` (`nodejs/src/handler.ts`) supports federating remote MCP servers via `config.remote` (connected through `RemoteManager`, merged with local tools, local overrides remote — see commits "Inject runtime context into local tools" and "Compose remotes in handler"), but `createRegistry` had no equivalent — it only ever accepted the caller's own `tools` map, with no way to pull in remote tools. Fixed by adding `options.remote`, wired through the same `RemoteManager` `createHandler` uses (zero duplicated federation logic). **This made `createRegistry` async** (`Promise<ToolRegistry<TEnv>>` instead of `ToolRegistry<TEnv>`) — a real signature change, but a safe one, since nothing had shipped against the synchronous version yet (this feature has not been released to npm). Existing callers need one change: `await createRegistry(...)` instead of `createRegistry(...)`.

## Porting notes for other languages

Every other language already has:
1. A `Tool` type with an optional `route: { method, path }` field (from the earlier "Add route field" work, commit `6cab7ef`) — reuse it, don't redefine it.
2. Dispatch/state machinery equivalent to `createState`/`handleRequest` (used internally by that language's `serve`/`Server` entry point) — reuse it for the registry's `mcp` handler instead of duplicating JSON-RPC logic.
3. An OpenAPI-building routine already used for that language's built-in `/openapi.json` route — extract/reuse it rather than writing a second implementation.

The port is: expose a new, separate, framework-neutral constructor (`NewRegistry` / `create_registry` / `Registry(...)` / etc., named per that language's convention) that returns `{ routes, openapi, mcp }` built from those three existing pieces, without adding any HTTP-framework dependency. See the per-language spec files in `specs/lang/*/registry.md` for the language-specific signature and packaging plan.
