use serde_json::Value;
use zeromcp::{Ctx, Input, Permissions, Server, Tool};

#[tokio::main]
async fn main() {
    let config_path = std::env::var("ZEROMCP_CONFIG")
        .unwrap_or_else(|_| "zeromcp.config.json".to_string());
    let mut server = Server::from_config(&config_path);

    // Resolve CRM credentials from TEST_CRM_KEY env var
    let crm_creds: Option<String> = std::env::var("TEST_CRM_KEY").ok();
    let crm_creds_clone = crm_creds.clone();

    server.tool(
        "crm_check_creds",
        Tool {
            description: "Check if credentials were injected".to_string(),
            input: Input::new(),
            permissions: Permissions::default(),
            execute: Box::new(move |_args: Value, _ctx: Ctx| {
                let creds = crm_creds_clone.clone();
                Box::pin(async move {
                    Ok(serde_json::json!({
                        "has_credentials": creds.is_some(),
                        "value": creds,
                    }))
                })
            }),
            cached_schema: Default::default(),
        },
    );

    server.tool(
        "nocreds_check_creds",
        Tool {
            description: "Check credentials in unconfigured namespace".to_string(),
            input: Input::new(),
            permissions: Permissions::default(),
            execute: Box::new(|_args: Value, _ctx: Ctx| {
                Box::pin(async move {
                    Ok(serde_json::json!({
                        "has_credentials": false,
                        "value": null,
                    }))
                })
            }),
            cached_schema: Default::default(),
        },
    );

    server.serve().await;
}
