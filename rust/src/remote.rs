//! Remote MCP federation: connect to remote MCP servers over HTTP and expose
//! their tools locally as `<server>.<tool>`.

use crate::config::{resolve_auth, RemoteServer};
use crate::schema::Input;
use crate::types::{Ctx, Permissions, Tool};
use serde_json::{json, Value};

/// Connect every server, returning `("<server>.<tool>", Tool)` pairs.
/// A server that fails is logged and skipped; this never fails as a whole.
pub(crate) async fn connect(servers: &[RemoteServer]) -> Vec<(String, Tool)> {
    let mut all = Vec::new();
    for server in servers {
        match connect_one(server).await {
            Ok(tools) => {
                for (tool_name, tool) in tools {
                    let namespaced = format!("{}.{}", server.name, tool_name);
                    eprintln!("[mcp] Remote tool: {namespaced}");
                    all.push((namespaced, tool));
                }
            }
            Err(e) => eprintln!("[mcp] Failed to connect to {}: {e}", server.name),
        }
    }
    all
}

async fn connect_one(server: &RemoteServer) -> Result<Vec<(String, Tool)>, String> {
    if !server.url.starts_with("http://") && !server.url.starts_with("https://") {
        return Err(format!(
            "Remote server \"{}\" must have an HTTP/HTTPS URL, got: {}",
            server.name, server.url
        ));
    }

    let client = reqwest::Client::new();
    let auth = resolve_auth(server.auth.as_deref());

    http_rpc(
        &client,
        &server.url,
        &json!({ "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {} }),
        auth.as_deref(),
    )
    .await?;

    let list = http_rpc(
        &client,
        &server.url,
        &json!({ "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {} }),
        auth.as_deref(),
    )
    .await?;

    let remote_tools = list
        .get("result")
        .and_then(|r| r.get("tools"))
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    let mut tools = Vec::new();
    for rt in remote_tools {
        let name = rt.get("name").and_then(Value::as_str).unwrap_or("").to_string();
        if let Some(allow) = &server.tools {
            if !allow.iter().any(|a| a == &name) {
                continue;
            }
        }
        let input = schema_to_input(rt.get("inputSchema").unwrap_or(&Value::Null))?;
        let cached_schema = input.to_json_schema();
        let description = rt
            .get("description")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();

        let client = client.clone();
        let url = server.url.clone();
        let auth = auth.clone();
        let upstream_name = name.clone();
        let tool = Tool {
            description,
            input,
            permissions: Permissions::default(),
            execute: Box::new(move |args: Value, _ctx: Ctx| {
                let client = client.clone();
                let url = url.clone();
                let auth = auth.clone();
                let upstream_name = upstream_name.clone();
                Box::pin(async move {
                    let id = std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| d.as_millis() as u64)
                        .unwrap_or(0);
                    let res = http_rpc(
                        &client,
                        &url,
                        &json!({
                            "jsonrpc": "2.0",
                            "id": id,
                            "method": "tools/call",
                            "params": { "name": upstream_name, "arguments": args }
                        }),
                        auth.as_deref(),
                    )
                    .await?;
                    let result = match res.get("result") {
                        Some(r) => r,
                        None => return Ok(Value::Null),
                    };
                    match result
                        .get("content")
                        .and_then(|c| c.get(0))
                        .and_then(|c| c.get("text"))
                        .and_then(Value::as_str)
                    {
                        Some(text) if !text.is_empty() => Ok(Value::String(text.to_string())),
                        _ => Ok(result.clone()),
                    }
                })
            }),
            cached_schema,
            route: None,
        };
        tools.push((name, tool));
    }

    eprintln!(
        "[mcp] Connected to {} (HTTP): {} tool(s)",
        server.name,
        tools.len()
    );
    Ok(tools)
}

async fn http_rpc(
    client: &reqwest::Client,
    url: &str,
    body: &Value,
    auth: Option<&str>,
) -> Result<Value, String> {
    let mut req = client
        .post(url)
        .header(reqwest::header::CONTENT_TYPE, "application/json")
        .body(body.to_string());
    if let Some(token) = auth {
        req = req.header(reqwest::header::AUTHORIZATION, format!("Bearer {token}"));
    }
    let res = req.send().await.map_err(|e| e.to_string())?;
    if !res.status().is_success() {
        return Err(format!("HTTP {}", res.status().as_u16()));
    }
    res.json::<Value>().await.map_err(|e| e.to_string())
}

/// Convert a remote tool's JSON `inputSchema` back into an `Input`.
fn schema_to_input(schema: &Value) -> Result<Input, String> {
    let mut input = Input::new();
    let properties = match schema.get("properties").and_then(Value::as_object) {
        Some(p) => p,
        None => return Ok(input),
    };
    let required: Vec<&str> = schema
        .get("required")
        .and_then(Value::as_array)
        .map(|r| r.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();

    for (key, prop) in properties {
        let type_name = match prop.get("type") {
            None | Some(Value::Null) => "string".to_string(),
            Some(Value::String(t)) if t.is_empty() => "string".to_string(),
            Some(Value::String(t)) => t.clone(),
            Some(other) => other.to_string(),
        };
        if !matches!(
            type_name.as_str(),
            "string" | "number" | "boolean" | "object" | "array"
        ) {
            return Err(format!("Unknown type \"{type_name}\" for field \"{key}\""));
        }
        let description = prop
            .get("description")
            .and_then(Value::as_str)
            .filter(|d| !d.is_empty());
        let is_required = required.contains(&key.as_str());
        input = match (is_required, description) {
            (true, None) => input.required(key, &type_name),
            (true, Some(d)) => input.required_desc(key, &type_name, d),
            (false, None) => input.optional(key, &type_name),
            (false, Some(d)) => input.optional_desc(key, &type_name, d),
        };
    }
    Ok(input)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schema_to_input_defaults_type_to_string() {
        let input = schema_to_input(&json!({
            "type": "object",
            "properties": { "q": {} },
            "required": ["q"]
        }))
        .unwrap();
        let schema = input.to_json_schema();
        assert_eq!(schema.properties["q"].prop_type, "string");
        assert_eq!(schema.required, vec!["q".to_string()]);
    }

    #[test]
    fn schema_to_input_keeps_description() {
        let input = schema_to_input(&json!({
            "properties": { "n": { "type": "number", "description": "How many" } },
            "required": ["n"]
        }))
        .unwrap();
        let schema = input.to_json_schema();
        assert_eq!(schema.properties["n"].prop_type, "number");
        assert_eq!(schema.properties["n"].description.as_deref(), Some("How many"));
    }

    #[test]
    fn schema_to_input_optional_when_not_required() {
        let input = schema_to_input(&json!({
            "properties": {
                "a": { "type": "string" },
                "b": { "type": "boolean", "description": "flag" }
            },
            "required": ["a"]
        }))
        .unwrap();
        let schema = input.to_json_schema();
        assert_eq!(schema.required, vec!["a".to_string()]);
        assert_eq!(schema.properties["b"].prop_type, "boolean");
        assert_eq!(schema.properties["b"].description.as_deref(), Some("flag"));
    }

    #[test]
    fn schema_to_input_missing_properties_is_empty() {
        let input = schema_to_input(&json!({ "type": "object" })).unwrap();
        assert!(input.to_json_schema().properties.is_empty());
        let input = schema_to_input(&Value::Null).unwrap();
        assert!(input.to_json_schema().properties.is_empty());
    }

    #[test]
    fn schema_to_input_unknown_type_is_err() {
        let err = schema_to_input(&json!({
            "properties": { "x": { "type": "integer" } }
        }))
        .unwrap_err();
        assert_eq!(err, "Unknown type \"integer\" for field \"x\"");
    }
}
