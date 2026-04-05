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

The official SDK has **no sandbox**. ZeroMCP adds per-tool network allowlists with `check_network()` and a permission model for filesystem and exec control.

## HTTP / Streamable HTTP

ZeroMCP doesn't own the HTTP layer. You bring your own framework; ZeroMCP gives you an async `handle_request` method that takes a `&Value` and returns `Option<Value>`.

```rust
// server.handle_request(&request) -> Option<Value>
```

**Axum**

```rust
use axum::{routing::post, Json, Router};
use serde_json::Value;

async fn mcp_handler(Json(request): Json<Value>) -> impl IntoResponse {
    match server.handle_request(&request).await {
        Some(response) => Json(response).into_response(),
        None => StatusCode::NO_CONTENT.into_response(),
    }
}

let app = Router::new().route("/mcp", post(mcp_handler));
let listener = tokio::net::TcpListener::bind("0.0.0.0:4242").await.unwrap();
axum::serve(listener, app).await.unwrap();
```

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
    network: NetworkPermission::AllowList(vec![
        "api.example.com".into(),
        "*.internal.dev".into(),
    ]),
    fs: FsPermission::None,
    exec: false,
}
```

Use `check_network()` to validate hostnames before making requests. Returns a descriptive error if the domain isn't in the allowlist.

### Filesystem and exec control

- `FsPermission::Read` / `FsPermission::Write` / `FsPermission::None`
- `exec: true` / `exec: false`

## Input types

`Input::new()` with `.required_desc(name, type, description)`. Types: `"string"`, `"number"`, `"boolean"`, `"object"`, `"array"`.

## Testing

```sh
cargo test
```
