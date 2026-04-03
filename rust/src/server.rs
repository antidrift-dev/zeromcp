use crate::config::{load_config, Config};
use crate::schema::validate;
use crate::sandbox::validate_permissions;
use crate::types::{BoxFuture, Ctx, Permissions, Tool};
use crate::schema::Input;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use tokio::io::{self, AsyncBufReadExt, AsyncWriteExt, BufReader};

/// The MCP server. Register tools, then call `serve()`.
pub struct Server {
    tools: BTreeMap<String, Tool>,
    config: Config,
}

impl Server {
    /// Create a new server with default config.
    pub fn new() -> Self {
        Self {
            tools: BTreeMap::new(),
            config: Config::default(),
        }
    }

    /// Create a server loading config from `zeromcp.config.json`.
    pub fn from_config(path: &str) -> Self {
        Self {
            tools: BTreeMap::new(),
            config: load_config(path),
        }
    }

    /// Register a tool by name.
    pub fn tool(&mut self, name: &str, tool: Tool) {
        validate_permissions(name, &tool.permissions);
        self.tools.insert(name.to_string(), tool);
    }

    /// Convenience: register a tool with just a description, input, and handler.
    pub fn add_tool<F>(&mut self, name: &str, description: &str, input: Input, handler: F)
    where
        F: Fn(Value, Ctx) -> BoxFuture + Send + Sync + 'static,
    {
        self.tool(
            name,
            Tool {
                description: description.to_string(),
                input,
                permissions: Permissions::default(),
                execute: Box::new(handler),
            },
        );
    }

    /// Start the stdio JSON-RPC transport.
    pub async fn serve(&self) {
        let tool_count = self.tools.len();
        eprintln!("[zeromcp] {tool_count} tool(s) registered");
        eprintln!("[zeromcp] stdio transport ready");

        let stdin = io::stdin();
        let stdout = io::stdout();
        let mut reader = BufReader::new(stdin);
        let mut writer = stdout;

        let mut line = String::new();
        loop {
            line.clear();
            match reader.read_line(&mut line).await {
                Ok(0) => break, // EOF
                Ok(_) => {}
                Err(e) => {
                    eprintln!("[zeromcp] stdin read error: {e}");
                    break;
                }
            }

            let request: Value = match serde_json::from_str(line.trim()) {
                Ok(v) => v,
                Err(_) => continue,
            };

            if let Some(response) = self.handle_request(&request).await {
                let mut out = serde_json::to_string(&response).unwrap();
                out.push('\n');
                if writer.write_all(out.as_bytes()).await.is_err() {
                    break;
                }
                let _ = writer.flush().await;
            }
        }
    }

    async fn handle_request(&self, request: &Value) -> Option<Value> {
        let id = request.get("id");
        let method = request.get("method")?.as_str()?;
        let params = request.get("params");

        // Notification (no id) for initialized — no response
        if id.is_none() && method == "notifications/initialized" {
            return None;
        }

        let id_val = id.cloned().unwrap_or(Value::Null);

        match method {
            "initialize" => Some(json!({
                "jsonrpc": "2.0",
                "id": id_val,
                "result": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {
                        "tools": { "listChanged": true }
                    },
                    "serverInfo": {
                        "name": "zeromcp",
                        "version": "0.1.0"
                    }
                }
            })),

            "tools/list" => {
                let tools_list = self.build_tool_list();
                Some(json!({
                    "jsonrpc": "2.0",
                    "id": id_val,
                    "result": { "tools": tools_list }
                }))
            }

            "tools/call" => {
                let result = self.call_tool(params).await;
                Some(json!({
                    "jsonrpc": "2.0",
                    "id": id_val,
                    "result": result
                }))
            }

            "ping" => Some(json!({
                "jsonrpc": "2.0",
                "id": id_val,
                "result": {}
            })),

            _ => {
                if id.is_none() {
                    return None;
                }
                Some(json!({
                    "jsonrpc": "2.0",
                    "id": id_val,
                    "error": {
                        "code": -32601,
                        "message": format!("Method not found: {method}")
                    }
                }))
            }
        }
    }

    fn build_tool_list(&self) -> Vec<Value> {
        self.tools
            .iter()
            .map(|(name, tool)| {
                let schema = tool.input.to_json_schema();
                json!({
                    "name": name,
                    "description": tool.description,
                    "inputSchema": schema
                })
            })
            .collect()
    }

    async fn call_tool(&self, params: Option<&Value>) -> Value {
        let name = params
            .and_then(|p| p.get("name"))
            .and_then(|v| v.as_str())
            .unwrap_or("");

        let args = params
            .and_then(|p| p.get("arguments"))
            .cloned()
            .unwrap_or_else(|| json!({}));

        let tool = match self.tools.get(name) {
            Some(t) => t,
            None => {
                return json!({
                    "content": [{ "type": "text", "text": format!("Unknown tool: {name}") }],
                    "isError": true
                });
            }
        };

        // Validate input
        let schema = tool.input.to_json_schema();
        let errors = validate(&args, &schema);
        if !errors.is_empty() {
            return json!({
                "content": [{ "type": "text", "text": format!("Validation errors:\n{}", errors.join("\n")) }],
                "isError": true
            });
        }

        // Build context
        let ctx = Ctx {
            permissions: tool.permissions.clone(),
            logging: self.config.logging,
            bypass: self.config.bypass_permissions,
        };

        // Execute
        match (tool.execute)(args, ctx).await {
            Ok(result) => {
                let text = if result.is_string() {
                    result.as_str().unwrap().to_string()
                } else {
                    serde_json::to_string_pretty(&result).unwrap_or_default()
                };
                json!({
                    "content": [{ "type": "text", "text": text }]
                })
            }
            Err(e) => {
                json!({
                    "content": [{ "type": "text", "text": format!("Error: {e}") }],
                    "isError": true
                })
            }
        }
    }
}
