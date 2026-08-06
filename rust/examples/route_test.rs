use serde_json::Value;
use zeromcp::{Ctx, Input, Permissions, RouteConfig, Server, Tool};

#[tokio::main]
async fn main() {
    let mut server = Server::new();

    server.tool(
        "greet",
        Tool {
            description: "Greet a person by name".to_string(),
            input: Input::new().required_desc("name", "string", "The person to greet"),
            permissions: Permissions::default(),
            execute: Box::new(|args: Value, _ctx: Ctx| {
                Box::pin(async move {
                    let name = args["name"].as_str().unwrap_or("world");
                    Ok(Value::String(format!("Hello, {name}!")))
                })
            }),
            cached_schema: Default::default(),
            route: Some(RouteConfig {
                method: "GET".to_string(),
                path: "/greet/:name".to_string(),
            }),
        },
    );

    server.tool(
        "echo",
        Tool {
            description: "Echo a message back".to_string(),
            input: Input::new().required_desc("message", "string", "The message to echo"),
            permissions: Permissions::default(),
            execute: Box::new(|args: Value, _ctx: Ctx| {
                Box::pin(async move {
                    Ok(serde_json::json!({
                        "message": args["message"],
                        "echoed": true
                    }))
                })
            }),
            cached_schema: Default::default(),
            route: Some(RouteConfig {
                method: "POST".to_string(),
                path: "/echo".to_string(),
            }),
        },
    );

    server.serve_http("0.0.0.0:14255").await;
}
