use serde_json::Value;
use std::sync::{Arc, Mutex};
use zeromcp::{Ctx, Input, Permissions, Server, Tool};

fn read_token_from_file(path: &str) -> Option<String> {
    let text = std::fs::read_to_string(path).ok()?;
    let v: Value = serde_json::from_str(&text).ok()?;
    v.get("token")?.as_str().map(|s| s.to_string())
}

#[tokio::main]
async fn main() {
    let config_path = std::env::var("ZEROMCP_CONFIG")
        .unwrap_or_else(|_| "zeromcp.config.json".to_string());

    // Parse config JSON to get credentials.tokenstore.file and cache_credentials flag.
    let raw = std::fs::read_to_string(&config_path).unwrap_or_else(|_| "{}".to_string());
    let config_json: Value = serde_json::from_str(&raw).unwrap_or(Value::Object(Default::default()));

    let cred_file = config_json
        .pointer("/credentials/tokenstore/file")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let cache_credentials = config_json
        .get("cache_credentials")
        .and_then(|v| v.as_bool())
        .unwrap_or(true);

    // When caching is enabled, resolve once at startup.
    let cached: Arc<Mutex<Option<Option<String>>>> = Arc::new(Mutex::new(None));

    let cred_file_clone = cred_file.clone();
    let cached_clone = cached.clone();

    let mut server = Server::from_config(&config_path);

    server.tool(
        "tokenstore_check",
        Tool {
            description: "Return the current token from credentials".to_string(),
            input: Input::new(),
            permissions: Permissions::default(),
            execute: Box::new(move |_args: Value, _ctx: Ctx| {
                let path = cred_file_clone.clone();
                let cache = cached_clone.clone();
                Box::pin(async move {
                    let token = if cache_credentials {
                        let mut lock = cache.lock().unwrap();
                        if lock.is_none() {
                            *lock = Some(read_token_from_file(&path));
                        }
                        lock.clone().unwrap()
                    } else {
                        read_token_from_file(&path)
                    };
                    Ok(serde_json::json!({ "token": token }))
                })
            }),
            cached_schema: Default::default(),
        },
    );

    server.serve().await;
}
