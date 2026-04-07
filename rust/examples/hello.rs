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
        },
    );

    server.tool(
        "add",
        Tool {
            description: "Add two numbers together".to_string(),
            input: Input::new()
                .required_desc("a", "number", "First number")
                .required_desc("b", "number", "Second number"),
            permissions: Permissions::default(),
            execute: Box::new(|args: Value, _ctx: Ctx| {
                Box::pin(async move {
                    let a = args["a"].as_f64().unwrap_or(0.0);
                    let b = args["b"].as_f64().unwrap_or(0.0);
                    Ok(serde_json::json!({"sum": a + b}))
                })
            }),
            cached_schema: Default::default(),
        },
    );

    server.serve().await;
}
