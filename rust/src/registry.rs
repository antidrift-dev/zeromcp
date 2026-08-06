//! Framework-neutral tool registry for MCP, REST adapters, and OpenAPI adapters.
//!
//! `Server::serve_http` mounts routed tools onto its own built-in HTTP loop.
//! `create_registry` is a second, additive entry point: it hands back route
//! metadata, a pre-built OpenAPI document, and a JSON-RPC handler, all
//! derived from the same dispatch/OpenAPI code `Server` uses internally, for
//! embedding into `axum`, `actix-web`, `warp`, or a Lambda handler instead.

use crate::server::Server;
use crate::types::{Ctx, Tool};
use crate::config::Config;
use serde_json::Value;
use std::future::Future;
use std::pin::Pin;
use std::sync::Arc;

/// The boxed future returned by the `mcp` handler.
pub type McpFuture = Pin<Box<dyn Future<Output = Option<Value>> + Send>>;

/// A JSON-RPC handler: `request -> Option<response>` (`None` for notifications).
/// `Arc`-wrapped (not `Box`) so it can be cloned cheaply into multiple route
/// closures/handlers without cloning the underlying `Server`.
pub type McpHandler = Arc<dyn Fn(Value) -> McpFuture + Send + Sync>;

/// One tool exposed as an HTTP route. Mirrors `RouteConfig` (`method`, `path`)
/// plus the tool name and a shared handle to the tool itself so the caller
/// can invoke it directly.
pub struct RouteDefinition {
    pub name: String,
    pub method: String,
    pub path: String,
    pub tool: Arc<Tool>,
}

/// A framework-neutral view over a set of tools: route metadata, a
/// pre-built OpenAPI document, and a JSON-RPC handler — all derived from
/// the same dispatch/OpenAPI code `Server` uses internally.
pub struct Registry {
    pub routes: Vec<RouteDefinition>,
    pub openapi: Value,
    pub mcp: McpHandler,
    config: Config,
}

impl Registry {
    /// Build the `Ctx` that `Server::call_tool` would build for `tool` —
    /// same `permissions`, `logging`, and `bypass` — so a route handler
    /// calling `tool.execute` directly gets identical sandbox behavior to
    /// going through `mcp` or the built-in HTTP server. Always use this
    /// (or construct an equivalent `Ctx`) instead of `Ctx::default()`.
    pub fn ctx_for(&self, tool: &Tool) -> Ctx {
        Ctx {
            permissions: tool.permissions.clone(),
            logging: self.config.logging,
            bypass: self.config.bypass_permissions,
        }
    }
}

/// Build a `Registry` from a set of named tools (same `Tool` type used by
/// `Server::tool`). Every tool is dispatchable through `mcp`; only tools
/// with a `route` appear in `routes`.
pub fn create_registry<I, S>(tools: I) -> Registry
where
    I: IntoIterator<Item = (S, Tool)>,
    S: Into<String>,
{
    let mut server = Server::new();
    for (name, tool) in tools {
        server.tool(&name.into(), tool);
    }

    let openapi = server.build_openapi();
    let config = server.config.clone();

    let routes = server
        .tools
        .iter()
        .filter_map(|(name, tool)| {
            tool.route.as_ref().map(|route| RouteDefinition {
                name: name.clone(),
                method: route.method.clone(),
                path: route.path.clone(),
                tool: Arc::clone(tool),
            })
        })
        .collect();

    let server = Arc::new(server);
    let mcp: McpHandler = Arc::new(move |request: Value| {
        let server = Arc::clone(&server);
        Box::pin(async move { server.handle_request(&request).await })
    });

    Registry {
        routes,
        openapi,
        mcp,
        config,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::schema::Input;
    use crate::types::{Permissions, RouteConfig};
    use serde_json::json;

    fn routed_tool(method: &str, path: &str) -> Tool {
        Tool {
            description: "A tool".to_string(),
            input: Input::new().required("name", "string"),
            permissions: Permissions::default(),
            execute: Box::new(|args: Value, _ctx: Ctx| {
                Box::pin(async move {
                    let name = args["name"].as_str().unwrap_or("").to_string();
                    Ok(json!(format!("hi {name}")))
                })
            }),
            cached_schema: Default::default(),
            route: Some(RouteConfig {
                method: method.to_string(),
                path: path.to_string(),
            }),
        }
    }

    fn unrouted_tool() -> Tool {
        Tool {
            description: "No route".to_string(),
            input: Input::new(),
            permissions: Permissions::default(),
            execute: Box::new(|_args: Value, _ctx: Ctx| Box::pin(async { Ok(json!(null)) })),
            cached_schema: Default::default(),
            route: None,
        }
    }

    #[test]
    fn routes_only_includes_routed_tools() {
        let registry = create_registry(vec![
            ("greet".to_string(), routed_tool("GET", "/greet/:name")),
            ("hidden".to_string(), unrouted_tool()),
        ]);
        assert_eq!(registry.routes.len(), 1);
        assert_eq!(registry.routes[0].name, "greet");
        assert_eq!(registry.routes[0].method, "GET");
        assert_eq!(registry.routes[0].path, "/greet/:name");
    }

    #[test]
    fn routes_are_sorted_by_name() {
        let registry = create_registry(vec![
            ("charlie".to_string(), routed_tool("GET", "/charlie")),
            ("alpha".to_string(), routed_tool("GET", "/alpha")),
            ("bravo".to_string(), routed_tool("GET", "/bravo")),
        ]);
        let names: Vec<&str> = registry.routes.iter().map(|r| r.name.as_str()).collect();
        assert_eq!(names, vec!["alpha", "bravo", "charlie"]);
    }

    #[test]
    fn openapi_matches_server_build_openapi() {
        let registry = create_registry(vec![(
            "greet".to_string(),
            routed_tool("GET", "/greet/:name"),
        )]);
        let paths = registry.openapi["paths"].as_object().expect("paths object");
        assert!(paths.contains_key("/greet/{name}"));
    }

    #[test]
    fn ctx_for_uses_tool_permissions_and_registry_config() {
        let registry = create_registry(vec![(
            "greet".to_string(),
            routed_tool("GET", "/greet/:name"),
        )]);
        let tool = &registry.routes[0].tool;
        let ctx = registry.ctx_for(tool);
        assert_eq!(ctx.logging, registry.config.logging);
        assert_eq!(ctx.bypass, registry.config.bypass_permissions);
    }

    #[tokio::test]
    async fn route_tool_invoked_directly_produces_expected_result() {
        let registry = create_registry(vec![(
            "greet".to_string(),
            routed_tool("GET", "/greet/:name"),
        )]);
        let route = &registry.routes[0];
        let ctx = registry.ctx_for(&route.tool);
        let result = (route.tool.execute)(json!({"name": "Ada"}), ctx).await;
        assert_eq!(result.unwrap(), json!("hi Ada"));
    }

    #[tokio::test]
    async fn mcp_dispatches_tools_list() {
        let registry = create_registry(vec![(
            "greet".to_string(),
            routed_tool("GET", "/greet/:name"),
        )]);
        let resp = (registry.mcp)(json!({
            "jsonrpc": "2.0", "id": 1, "method": "tools/list"
        }))
        .await
        .unwrap();
        let tools = resp["result"]["tools"].as_array().unwrap();
        assert_eq!(tools.len(), 1);
        assert_eq!(tools[0]["name"], "greet");
    }

    #[tokio::test]
    async fn mcp_dispatches_tools_call() {
        let registry = create_registry(vec![(
            "greet".to_string(),
            routed_tool("POST", "/greet"),
        )]);
        let resp = (registry.mcp)(json!({
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": { "name": "greet", "arguments": { "name": "Ada" } }
        }))
        .await
        .unwrap();
        assert_eq!(resp["result"]["content"][0]["text"], "hi Ada");
    }

    #[test]
    fn empty_when_no_routed_tools() {
        let registry = create_registry(vec![("hidden".to_string(), unrouted_tool())]);
        assert_eq!(registry.routes.len(), 0);
    }
}
