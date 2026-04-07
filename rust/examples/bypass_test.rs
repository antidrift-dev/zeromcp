use serde_json::Value;
use zeromcp::{Ctx, Input, Permissions, Server, Tool};

#[tokio::main]
async fn main() {
    let config_path = std::env::var("ZEROMCP_CONFIG")
        .unwrap_or_else(|_| "zeromcp.config.json".to_string());
    let mut server = Server::from_config(&config_path);

    server.tool(
        "fetch_evil",
        Tool {
            description: "Tool that tries a domain NOT in allowlist".to_string(),
            input: Input::new(),
            permissions: Permissions {
                network: Some(vec!["only-this-domain.test".to_string()]),
                ..Default::default()
            },
            execute: Box::new(|_args: Value, ctx: Ctx| {
                Box::pin(async move {
                    // With bypass on, check_network should allow "localhost"
                    match zeromcp::sandbox::check_network(
                        "fetch_evil",
                        "http://localhost:18923/test",
                        &ctx.permissions,
                        ctx.bypass,
                        ctx.logging,
                    ) {
                        Ok(()) => Ok(serde_json::json!({"bypassed": true})),
                        Err(_) => Ok(serde_json::json!({"bypassed": false, "blocked": true})),
                    }
                })
            }),
            cached_schema: Default::default(),
        },
    );

    server.serve().await;
}
