use serde_json::Value;
use zeromcp::{Ctx, Input, Permissions, Server, Tool};

#[tokio::main]
async fn main() {
    let mut server = Server::new();

    let allowed_perms = Permissions {
        network: Some(vec!["localhost".to_string()]),
        fs: None,
        exec: false, ..Default::default()
    };

    let blocked_perms = allowed_perms.clone();

    server.tool(
        "fetch_allowed",
        Tool {
            description: "Fetch an allowed domain".to_string(),
            input: Input::new(),
            permissions: allowed_perms.clone(),
            execute: Box::new(move |_args: Value, ctx: Ctx| {
                Box::pin(async move {
                    match zeromcp::sandbox::check_network(
                        "fetch_allowed", "http://localhost:18923/test",
                        &ctx.permissions, ctx.bypass, ctx.logging,
                    ) {
                        Ok(()) => Ok(serde_json::json!({"status": "ok", "domain": "localhost"})),
                        Err(e) => Ok(serde_json::json!({"status": "error", "message": e})),
                    }
                })
            }),
            cached_schema: Default::default(),
        },
    );

    server.tool(
        "fetch_blocked",
        Tool {
            description: "Fetch a blocked domain".to_string(),
            input: Input::new(),
            permissions: blocked_perms,
            execute: Box::new(|_args: Value, ctx: Ctx| {
                Box::pin(async move {
                    match zeromcp::sandbox::check_network(
                        "fetch_blocked", "http://evil.test:18923/steal",
                        &ctx.permissions, ctx.bypass, ctx.logging,
                    ) {
                        Ok(()) => Ok(serde_json::json!({"blocked": false})),
                        Err(_) => Ok(serde_json::json!({"blocked": true, "domain": "evil.test"})),
                    }
                })
            }),
            cached_schema: Default::default(),
        },
    );

    server.tool(
        "fetch_no_network",
        Tool {
            description: "Tool with network disabled".to_string(),
            input: Input::new(),
            permissions: Permissions { network: Some(vec![]), fs: None, exec: false, ..Default::default() },
            execute: Box::new(|_args: Value, ctx: Ctx| {
                Box::pin(async move {
                    match zeromcp::sandbox::check_network(
                        "fetch_no_network", "http://localhost:18923/test",
                        &ctx.permissions, ctx.bypass, ctx.logging,
                    ) {
                        Ok(()) => Ok(serde_json::json!({"blocked": false})),
                        Err(_) => Ok(serde_json::json!({"blocked": true})),
                    }
                })
            }),
            cached_schema: Default::default(),
        },
    );

    server.tool(
        "fetch_unrestricted",
        Tool {
            description: "Tool with no network restrictions".to_string(),
            input: Input::new(),
            permissions: Permissions::default(),
            execute: Box::new(|_args: Value, ctx: Ctx| {
                Box::pin(async move {
                    match zeromcp::sandbox::check_network(
                        "fetch_unrestricted", "http://localhost:18923/test",
                        &ctx.permissions, ctx.bypass, ctx.logging,
                    ) {
                        Ok(()) => Ok(serde_json::json!({"status": "ok", "domain": "localhost"})),
                        Err(e) => Ok(serde_json::json!({"status": "error", "message": e})),
                    }
                })
            }),
            cached_schema: Default::default(),
        },
    );

    server.tool(
        "fetch_wildcard",
        Tool {
            description: "Tool with wildcard network permission".to_string(),
            input: Input::new(),
            permissions: Permissions { network: Some(vec!["*.localhost".to_string()]), fs: None, exec: false, ..Default::default() },
            execute: Box::new(|_args: Value, ctx: Ctx| {
                Box::pin(async move {
                    match zeromcp::sandbox::check_network(
                        "fetch_wildcard", "http://localhost:18923/test",
                        &ctx.permissions, ctx.bypass, ctx.logging,
                    ) {
                        Ok(()) => Ok(serde_json::json!({"status": "ok", "domain": "localhost"})),
                        Err(e) => Ok(serde_json::json!({"status": "error", "message": e})),
                    }
                })
            }),
            cached_schema: Default::default(),
        },
    );

    server.serve().await;
}
