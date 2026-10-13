# ZeroMCP &mdash; Rust

Sandboxed MCP server library for Rust. Register tools, call `server.serve().await`, done.

## Getting started

```rust
use serde_json::Value;
use zeromcp::{Ctx, Input, Permissions, Server, Tool};

#[tokio::main]
async fn main() {
    let mut server = Server::new();

    server.tool(
        "hello",
        Tool {
            description: "Say hello to someone".to_string(),
            input: Input::new().required_desc("name", "string", "Who to greet"),
            permissions: Permissions::default(),
            execute: Box::new(|args: Value, _ctx: Ctx| {
                Box::pin(async move {
                    let name = args["name"].as_str().unwrap_or("world");
                    Ok(Value::String(format!("Hello, {name}!")))
                })
            }),
            cached_schema: Default::default(),
            route: None,
        },
    );

    server.serve().await;
}
```

```sh
cargo build --example hello --release
./target/release/examples/hello
```

Stdio works immediately. No transport configuration needed.

## vs. the official SDK

The official Rust SDK requires server setup, transport configuration, and schema definition. ZeroMCP handles the protocol, transport, and schema generation.

In benchmarks, ZeroMCP Rust handles 9,273 requests/second over stdio versus the official SDK's 8,114 — 1.1x faster with 50% less memory (2 MB vs 4 MB). Over HTTP (Actix), ZeroMCP serves 5,111 rps at 3-4 MB versus the official SDK's 2,452 rps — and the official SDK leaks memory from 18 MB to 2.4 GB over 5 minutes. ZeroMCP Rust stays flat at 3-4 MB. The official SDK requires Rust 1.88+; ZeroMCP works with Rust 1.85+.

Rust passes all 10 conformance suites and survives 21/22 chaos monkey attacks.

The official SDK has **no sandbox**. ZeroMCP adds per-tool network allowlists with `check_network()` and a permission model for filesystem and exec control.

## HTTP / Streamable HTTP

ZeroMCP doesn't ship an HTTP server. You bring your own framework; ZeroMCP gives you two things to mount in it:

- `Server::handle_request(&Value) -> Option<Value>`: the JSON-RPC handler for `/mcp`.
- `zeromcp::registry::create_registry`: route metadata, an OpenAPI document and the same `/mcp` handler, for exposing tools as REST endpoints too.

A config file with `"transport": [{ "type": "http" }]` panics at startup and points you at these.

**Axum + `handle_request`**

```rust
use axum::{extract::State, http::StatusCode, response::IntoResponse, routing::post, Json, Router};
use serde_json::Value;
use std::sync::Arc;
use zeromcp::Server;

async fn mcp_handler(State(server): State<Arc<Server>>, Json(request): Json<Value>) -> impl IntoResponse {
    match server.handle_request(&request).await {
        Some(response) => Json(response).into_response(),
        None => StatusCode::NO_CONTENT.into_response(),
    }
}

#[tokio::main]
async fn main() {
    let mut server = Server::from_config("zeromcp.config.json");
    // server.tool(...) for each tool
    server.prepare().await; // connects `remote` servers and resolves `icon`
    let app = Router::new().route("/mcp", post(mcp_handler)).with_state(Arc::new(server));
    let listener = tokio::net::TcpListener::bind("0.0.0.0:4242").await.unwrap();
    axum::serve(listener, app).await.unwrap();
}
```

**Axum + `create_registry`** (routes, OpenAPI and `/mcp`)

Give a tool `route: Some(RouteConfig { method: "GET".into(), path: "/greet/:name".into() })` and the registry lists it in `routes` and `openapi`.

```rust
use axum::{extract::Path, routing::{get, post}, Json, Router};
use serde_json::{json, Value};
use std::sync::Arc;
use zeromcp::registry::{create_registry, RegistryOptions};

let registry = Arc::new(create_registry(tools, RegistryOptions::default()).await);

let mut app = Router::new();
let openapi = registry.openapi.clone();
app = app.route("/openapi.json", get(move || async move { Json(openapi) }));
let mcp = registry.mcp.clone();
app = app.route("/mcp", post(move |Json(req): Json<Value>| async move {
    Json((mcp)(req).await.unwrap_or(json!({})))
}));

// One handler per routed tool, e.g. GET /greet/:name
let greet = registry.routes.iter().find(|r| r.name == "greet").unwrap();
let (tool, ctx) = (greet.tool.clone(), registry.ctx_for(&greet.tool));
app = app.route("/greet/{name}", get(move |Path(name): Path<String>| async move {
    match (tool.execute)(json!({ "name": name }), ctx).await {
        Ok(result) => Json(json!({ "ok": true, "result": result })),
        Err(e) => Json(json!({ "ok": false, "error": e })),
    }
}));
```

Always build the route handler's `Ctx` with `registry.ctx_for(&tool)` so it gets the same sandbox settings as `/mcp`.

## Remote servers

Federate tools from other MCP servers over HTTP. Each remote tool is exposed as `<server>.<tool>`; a local tool with the same name wins (and logs `Local tool "<name>" overrides remote`).

```json
{
  "remote": [
    { "name": "probeo", "url": "https://mcp.probeo.io/mcp", "auth": "env:PROBEO_TOKEN", "tools": ["list_pages"] }
  ]
}
```

- `auth`: a bearer token, or `env:VAR` to read it from the environment.
- `tools`: optional allowlist of upstream tool names; omit to expose all.
- A server that fails to connect is logged and skipped.

`serve()` connects remotes itself. With `handle_request`, call `server.prepare().await` first. With the registry, pass them in the options:

```rust
let registry = create_registry(tools, RegistryOptions {
    remote: vec![RemoteServer { name: "probeo".into(), url: url.into(), auth: None, tools: None }],
}).await;
```

Remote tools are callable through `mcp` but never appear in `routes` or `openapi`.

## Runtime context

Pass per-call host state to tools. The getter runs on every local `tools/call`; its value is `ctx.runtime`:

```rust
server.set_runtime(|| Some(AppState { tenant: current_tenant() }));

// in a tool:
if let Some(state) = ctx.runtime_as::<AppState>() { /* ... */ }
```

Returning `None` leaves `ctx.runtime` unset. Registry route handlers get `runtime: None` from `ctx_for`; capture host state in the tool's closure instead.

## Config

`Server::from_config(path)` reads `zeromcp.config.json`:

| Key | Default | |
|---|---|---|
| `logging` | `false` | Log sandbox decisions to stderr |
| `bypass_permissions` | `false` | Allow everything, with a warning |
| `execute_timeout` | `30000` | Default tool timeout (ms) |
| `page_size` | `0` | Page size for list responses; 0 = no pagination. `set_page_size` overrides it |
| `icon` | none | Data URI, http(s) URL, or file path; resolved to a data URI by `prepare`. An icon set in code wins |
| `title` | `"ZeroMCP"` | OpenAPI title |
| `remote` | `[]` | Remote MCP servers (above) |

## Requirements

- Rust 2021 edition
- Tokio async runtime

## Dependencies

```toml
[dependencies]
zeromcp = { path = "." }
serde_json = "1"
tokio = { version = "1", features = ["full"] }
```

## Sandbox

### Network allowlists

```rust
Permissions {
    network: Some(vec![
        "api.example.com".into(),
        "*.internal.dev".into(),
    ]),
    fs: None,
    exec: false,
    execute_timeout: None,
}
```

Use `check_network()` to validate hostnames before making requests. Returns a descriptive error if the domain isn't in the allowlist.

### Filesystem and exec control

- `fs: Some("read".into())` / `fs: Some("write".into())` / `fs: None`
- `exec: true` / `exec: false`

## Input types

`Input::new()` with `.required_desc(name, type, description)`. Types: `"string"`, `"number"`, `"boolean"`, `"object"`, `"array"`.

## Testing

```sh
cargo test
```
