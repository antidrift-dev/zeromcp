use serde_json::Value;
use zeromcp::{Ctx, Input, Permissions, Server, Tool};

#[tokio::main]
async fn main() {
    let mut server = Server::new();

    server.tool(
        "hello",
        Tool {
            description: "Fast tool".to_string(),
            input: Input::new().required("name", "string"),
            permissions: Permissions::default(),
            execute: Box::new(|args: Value, _ctx: Ctx| {
                Box::pin(async move {
                    let name = args["name"].as_str().unwrap_or("world");
                    Ok(Value::String(format!("Hello, {name}!")))
                })
            }),
            cached_schema: Default::default(),
        },
    );

    server.tool(
        "slow",
        Tool {
            description: "Tool that takes 3 seconds".to_string(),
            input: Input::new(),
            permissions: Permissions {
                execute_timeout: Some(2000),
                ..Default::default()
            },
            execute: Box::new(|_args: Value, _ctx: Ctx| {
                Box::pin(async move {
                    tokio::time::sleep(std::time::Duration::from_secs(3)).await;
                    Ok(serde_json::json!({"status": "ok"}))
                })
            }),
            cached_schema: Default::default(),
        },
    );

    server.serve().await;
}
