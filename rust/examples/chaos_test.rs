use serde_json::Value;
use std::sync::Mutex;
use zeromcp::{Ctx, Input, Permissions, Server, Tool};

static LEAKS: Mutex<Vec<Vec<u8>>> = Mutex::new(Vec::new());

#[tokio::main]
async fn main() {
    let mut server = Server::new();

    // Normal tool for health checks
    server.tool("hello", Tool {
        description: "Say hello".to_string(),
        input: Input::new().required_desc("name", "string", "Name"),
        permissions: Permissions::default(),
        execute: Box::new(|args: Value, _ctx: Ctx| {
            Box::pin(async move {
                let name = args["name"].as_str().unwrap_or("world");
                Ok(Value::String(format!("Hello, {name}!")))
            })
        }),
        cached_schema: Default::default(),
    });

    // Tool that returns an error
    server.tool("throw_error", Tool {
        description: "Tool that throws".to_string(),
        input: Input::new(),
        permissions: Permissions::default(),
        execute: Box::new(|_args: Value, _ctx: Ctx| {
            Box::pin(async move {
                Err("Intentional chaos: unhandled exception".to_string())
            })
        }),
        cached_schema: Default::default(),
    });

    // Tool that hangs forever
    server.tool("hang", Tool {
        description: "Tool that hangs forever".to_string(),
        input: Input::new(),
        permissions: Permissions::default(),
        execute: Box::new(|_args: Value, _ctx: Ctx| {
            Box::pin(async move {
                tokio::time::sleep(tokio::time::Duration::from_secs(86400)).await;
                Ok(Value::Null)
            })
        }),
        cached_schema: Default::default(),
    });

    // Tool that takes 3 seconds
    server.tool("slow", Tool {
        description: "Tool that takes 3 seconds".to_string(),
        input: Input::new(),
        permissions: Permissions::default(),
        execute: Box::new(|_args: Value, _ctx: Ctx| {
            Box::pin(async move {
                tokio::time::sleep(tokio::time::Duration::from_secs(3)).await;
                Ok(serde_json::json!({"status": "ok", "delay_ms": 3000}))
            })
        }),
        cached_schema: Default::default(),
    });

    // Tool that leaks memory
    server.tool("leak_memory", Tool {
        description: "Tool that leaks memory".to_string(),
        input: Input::new(),
        permissions: Permissions::default(),
        execute: Box::new(|_args: Value, _ctx: Ctx| {
            Box::pin(async move {
                let mut leaks = LEAKS.lock().unwrap();
                leaks.push(vec![0u8; 1024 * 1024]);
                Ok(serde_json::json!({"leaked_buffers": leaks.len(), "total_mb": leaks.len()}))
            })
        }),
        cached_schema: Default::default(),
    });

    // Tool that writes to stdout
    server.tool("stdout_corrupt", Tool {
        description: "Tool that writes to stdout".to_string(),
        input: Input::new(),
        permissions: Permissions::default(),
        execute: Box::new(|_args: Value, _ctx: Ctx| {
            Box::pin(async move {
                println!("CORRUPTED OUTPUT");
                Ok(serde_json::json!({"status": "ok"}))
            })
        }),
        cached_schema: Default::default(),
    });

    server.serve().await;
}
