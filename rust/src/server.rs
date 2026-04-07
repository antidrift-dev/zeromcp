use crate::config::{load_config, Config};
use crate::schema::validate;
use crate::sandbox::validate_permissions;
use crate::types::{BoxFuture, Ctx, Permissions, Prompt, Resource, ResourceTemplate, Tool};
use crate::schema::Input;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::time::Duration;
use tokio::io::{self, AsyncBufReadExt, AsyncWriteExt, BufReader};

/// The MCP server. Register tools, resources, prompts, then call `serve()`.
pub struct Server {
    tools: BTreeMap<String, Tool>,
    resources: BTreeMap<String, Resource>,
    templates: BTreeMap<String, ResourceTemplate>,
    prompts: BTreeMap<String, Prompt>,
    #[allow(dead_code)]
    subscriptions: BTreeSet<String>,
    config: Config,
    #[allow(dead_code)]
    log_level: String,
    page_size: usize,
    /// Optional icon URI attached to listed items.
    pub icon: Option<String>,
}

impl Server {
    /// Create a new server with default config.
    pub fn new() -> Self {
        Self {
            tools: BTreeMap::new(),
            resources: BTreeMap::new(),
            templates: BTreeMap::new(),
            prompts: BTreeMap::new(),
            subscriptions: BTreeSet::new(),
            config: Config::default(),
            log_level: "info".to_string(),
            page_size: 0,
            icon: None,
        }
    }

    /// Create a server loading config from `zeromcp.config.json`.
    pub fn from_config(path: &str) -> Self {
        Self {
            tools: BTreeMap::new(),
            resources: BTreeMap::new(),
            templates: BTreeMap::new(),
            prompts: BTreeMap::new(),
            subscriptions: BTreeSet::new(),
            config: load_config(path),
            log_level: "info".to_string(),
            page_size: 0,
            icon: None,
        }
    }

    /// Set the page size for paginated list responses. 0 = no pagination.
    pub fn set_page_size(&mut self, size: usize) {
        self.page_size = size;
    }

    // ----- Tool registration -----

    /// Register a tool by name.
    pub fn tool(&mut self, name: &str, mut tool: Tool) {
        validate_permissions(name, &tool.permissions);
        // Cache the JSON schema at registration time so it isn't rebuilt per request.
        tool.cached_schema = tool.input.to_json_schema();
        self.tools.insert(name.to_string(), tool);
    }

    /// Convenience: register a tool with just a description, input, and handler.
    pub fn add_tool<F>(&mut self, name: &str, description: &str, input: Input, handler: F)
    where
        F: Fn(Value, Ctx) -> BoxFuture + Send + Sync + 'static,
    {
        let cached_schema = input.to_json_schema();
        self.tool(
            name,
            Tool {
                description: description.to_string(),
                input,
                permissions: Permissions::default(),
                execute: Box::new(handler),
                cached_schema,
            },
        );
    }

    // ----- Resource registration -----

    /// Register a static resource.
    pub fn resource(&mut self, resource: Resource) {
        self.resources.insert(resource.uri.clone(), resource);
    }

    /// Register a resource template.
    pub fn resource_template(&mut self, template: ResourceTemplate) {
        self.templates
            .insert(template.uri_template.clone(), template);
    }

    // ----- Prompt registration -----

    /// Register a prompt.
    pub fn prompt(&mut self, prompt: Prompt) {
        self.prompts.insert(prompt.name.clone(), prompt);
    }

    // ----- Transport -----

    /// Start the stdio JSON-RPC transport.
    pub async fn serve(&self) {
        let tool_count = self.tools.len();
        let resource_count = self.resources.len() + self.templates.len();
        let prompt_count = self.prompts.len();
        eprintln!("[zeromcp] {tool_count} tool(s), {resource_count} resource(s), {prompt_count} prompt(s) registered");
        eprintln!("[zeromcp] stdio transport ready");

        let stdin = io::stdin();
        let stdout = io::stdout();
        let mut reader = BufReader::new(stdin);
        let mut writer = stdout;

        let mut raw_line = Vec::new();
        loop {
            raw_line.clear();
            match reader.read_until(b'\n', &mut raw_line).await {
                Ok(0) => break, // EOF
                Ok(_) => {}
                Err(e) => {
                    eprintln!("[zeromcp] stdin read error: {e}");
                    break;
                }
            }

            // Handle invalid UTF-8 gracefully (binary_garbage resilience)
            let line = match std::str::from_utf8(&raw_line) {
                Ok(s) => s.trim().to_string(),
                Err(_) => {
                    eprintln!("[zeromcp] skipping non-UTF-8 input");
                    continue;
                }
            };

            let request: Value = match serde_json::from_str(&line) {
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

    /// Process a single JSON-RPC request and return a response.
    /// Returns `None` for notifications that require no response.
    ///
    /// # Example
    /// ```ignore
    /// let response = server.handle_request(&serde_json::json!({
    ///     "jsonrpc": "2.0", "id": 1, "method": "tools/list"
    /// })).await;
    /// ```
    pub async fn handle_request(&self, request: &Value) -> Option<Value> {
        let id = request.get("id");
        let method = request.get("method")?.as_str()?;
        let params = request.get("params");

        // Notifications (no id) — no response
        if id.is_none() {
            match method {
                "notifications/initialized" | "notifications/roots/list_changed" => {}
                _ => {}
            }
            return None;
        }

        let id_val = id.cloned().unwrap_or(Value::Null);

        match method {
            "initialize" => Some(self.handle_initialize(&id_val)),

            "tools/list" => Some(self.handle_tools_list(&id_val, params)),
            "tools/call" => Some(self.handle_tools_call(&id_val, params).await),

            "resources/list" => Some(self.handle_resources_list(&id_val, params)),
            "resources/read" => Some(self.handle_resources_read(&id_val, params).await),
            "resources/subscribe" => Some(self.handle_resources_subscribe(&id_val, params)),
            "resources/templates/list" => Some(self.handle_resources_templates_list(&id_val, params)),

            "prompts/list" => Some(self.handle_prompts_list(&id_val, params)),
            "prompts/get" => Some(self.handle_prompts_get(&id_val, params).await),

            "logging/setLevel" => Some(self.handle_logging_set_level(&id_val, params)),
            "completion/complete" => Some(self.handle_completion_complete(&id_val)),

            "ping" => Some(json!({
                "jsonrpc": "2.0",
                "id": id_val,
                "result": {}
            })),

            _ => {
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

    // -----------------------------------------------------------------------
    // Initialize
    // -----------------------------------------------------------------------

    fn handle_initialize(&self, id: &Value) -> Value {
        let mut capabilities = json!({
            "tools": { "listChanged": true }
        });

        if !self.resources.is_empty() || !self.templates.is_empty() {
            capabilities["resources"] = json!({ "subscribe": true, "listChanged": true });
        }

        if !self.prompts.is_empty() {
            capabilities["prompts"] = json!({ "listChanged": true });
        }

        capabilities["logging"] = json!({});

        let mut server_info = json!({
            "name": "zeromcp",
            "version": "0.2.0"
        });
        if let Some(ref icon) = self.icon {
            server_info["icon"] = json!(icon);
        }

        json!({
            "jsonrpc": "2.0",
            "id": id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": capabilities,
                "serverInfo": server_info
            }
        })
    }

    // -----------------------------------------------------------------------
    // Tools
    // -----------------------------------------------------------------------

    fn handle_tools_list(&self, id: &Value, params: Option<&Value>) -> Value {
        let list: Vec<Value> = self
            .tools
            .iter()
            .map(|(name, tool)| {
                let mut entry = json!({
                    "name": name,
                    "description": tool.description,
                    "inputSchema": tool.cached_schema
                });
                if let Some(ref icon) = self.icon {
                    entry["icons"] = json!([{ "uri": icon }]);
                }
                entry
            })
            .collect();

        let cursor = params.and_then(|p| p.get("cursor")).and_then(|v| v.as_str());
        let (items, next_cursor) = paginate(&list, cursor, self.page_size);

        let mut result = json!({ "tools": items });
        if let Some(nc) = next_cursor {
            result["nextCursor"] = json!(nc);
        }
        json!({ "jsonrpc": "2.0", "id": id, "result": result })
    }

    async fn handle_tools_call(&self, id: &Value, params: Option<&Value>) -> Value {
        let result = self.call_tool(params).await;
        json!({
            "jsonrpc": "2.0",
            "id": id,
            "result": result
        })
    }

    // -----------------------------------------------------------------------
    // Resources
    // -----------------------------------------------------------------------

    fn handle_resources_list(&self, id: &Value, params: Option<&Value>) -> Value {
        let list: Vec<Value> = self
            .resources
            .values()
            .map(|res| {
                let mut entry = json!({
                    "uri": res.uri,
                    "name": res.name,
                    "description": res.description,
                    "mimeType": res.mime_type
                });
                if let Some(ref icon) = self.icon {
                    entry["icons"] = json!([{ "uri": icon }]);
                }
                entry
            })
            .collect();

        let cursor = params.and_then(|p| p.get("cursor")).and_then(|v| v.as_str());
        let (items, next_cursor) = paginate(&list, cursor, self.page_size);

        let mut result = json!({ "resources": items });
        if let Some(nc) = next_cursor {
            result["nextCursor"] = json!(nc);
        }
        json!({ "jsonrpc": "2.0", "id": id, "result": result })
    }

    async fn handle_resources_read(&self, id: &Value, params: Option<&Value>) -> Value {
        let uri = params
            .and_then(|p| p.get("uri"))
            .and_then(|v| v.as_str())
            .unwrap_or("");

        // Check static resources
        if let Some(res) = self.resources.get(uri) {
            return match (res.read)().await {
                Ok(text) => json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": {
                        "contents": [{ "uri": uri, "mimeType": res.mime_type, "text": text }]
                    }
                }),
                Err(e) => json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "error": { "code": -32603, "message": format!("Error reading resource: {e}") }
                }),
            };
        }

        // Check templates
        for tmpl in self.templates.values() {
            if let Some(params_map) = match_template(&tmpl.uri_template, uri) {
                return match (tmpl.read)(params_map).await {
                    Ok(text) => json!({
                        "jsonrpc": "2.0",
                        "id": id,
                        "result": {
                            "contents": [{ "uri": uri, "mimeType": tmpl.mime_type, "text": text }]
                        }
                    }),
                    Err(e) => json!({
                        "jsonrpc": "2.0",
                        "id": id,
                        "error": { "code": -32603, "message": format!("Error reading resource: {e}") }
                    }),
                };
            }
        }

        json!({
            "jsonrpc": "2.0",
            "id": id,
            "error": { "code": -32002, "message": format!("Resource not found: {uri}") }
        })
    }

    fn handle_resources_subscribe(&self, id: &Value, params: Option<&Value>) -> Value {
        // Note: subscriptions is not &mut self currently; for a full impl the
        // server would need interior mutability.  For now we acknowledge the
        // subscription without persisting it (matches the protocol ACK).
        let _uri = params
            .and_then(|p| p.get("uri"))
            .and_then(|v| v.as_str());
        json!({ "jsonrpc": "2.0", "id": id, "result": {} })
    }

    fn handle_resources_templates_list(&self, id: &Value, params: Option<&Value>) -> Value {
        let list: Vec<Value> = self
            .templates
            .values()
            .map(|tmpl| {
                let mut entry = json!({
                    "uriTemplate": tmpl.uri_template,
                    "name": tmpl.name,
                    "description": tmpl.description,
                    "mimeType": tmpl.mime_type
                });
                if let Some(ref icon) = self.icon {
                    entry["icons"] = json!([{ "uri": icon }]);
                }
                entry
            })
            .collect();

        let cursor = params.and_then(|p| p.get("cursor")).and_then(|v| v.as_str());
        let (items, next_cursor) = paginate(&list, cursor, self.page_size);

        let mut result = json!({ "resourceTemplates": items });
        if let Some(nc) = next_cursor {
            result["nextCursor"] = json!(nc);
        }
        json!({ "jsonrpc": "2.0", "id": id, "result": result })
    }

    // -----------------------------------------------------------------------
    // Prompts
    // -----------------------------------------------------------------------

    fn handle_prompts_list(&self, id: &Value, params: Option<&Value>) -> Value {
        let list: Vec<Value> = self
            .prompts
            .values()
            .map(|prompt| {
                let mut entry = json!({ "name": prompt.name });
                if let Some(ref desc) = prompt.description {
                    entry["description"] = json!(desc);
                }
                if let Some(ref args) = prompt.arguments {
                    entry["arguments"] = serde_json::to_value(args).unwrap_or(json!([]));
                }
                if let Some(ref icon) = self.icon {
                    entry["icons"] = json!([{ "uri": icon }]);
                }
                entry
            })
            .collect();

        let cursor = params.and_then(|p| p.get("cursor")).and_then(|v| v.as_str());
        let (items, next_cursor) = paginate(&list, cursor, self.page_size);

        let mut result = json!({ "prompts": items });
        if let Some(nc) = next_cursor {
            result["nextCursor"] = json!(nc);
        }
        json!({ "jsonrpc": "2.0", "id": id, "result": result })
    }

    async fn handle_prompts_get(&self, id: &Value, params: Option<&Value>) -> Value {
        let name = params
            .and_then(|p| p.get("name"))
            .and_then(|v| v.as_str())
            .unwrap_or("");

        let args = params
            .and_then(|p| p.get("arguments"))
            .cloned()
            .unwrap_or_else(|| json!({}));

        let prompt = match self.prompts.get(name) {
            Some(p) => p,
            None => {
                return json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "error": { "code": -32002, "message": format!("Prompt not found: {name}") }
                });
            }
        };

        match (prompt.render)(args).await {
            Ok(messages) => {
                let msgs = serde_json::to_value(&messages).unwrap_or(json!([]));
                json!({
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": { "messages": msgs }
                })
            }
            Err(e) => json!({
                "jsonrpc": "2.0",
                "id": id,
                "error": { "code": -32603, "message": format!("Error rendering prompt: {e}") }
            }),
        }
    }

    // -----------------------------------------------------------------------
    // Logging / Completion
    // -----------------------------------------------------------------------

    fn handle_logging_set_level(&self, id: &Value, _params: Option<&Value>) -> Value {
        // Note: would need interior mutability to persist the level change.
        // We acknowledge it per protocol.
        json!({ "jsonrpc": "2.0", "id": id, "result": {} })
    }

    fn handle_completion_complete(&self, id: &Value) -> Value {
        json!({
            "jsonrpc": "2.0",
            "id": id,
            "result": { "completion": { "values": [] } }
        })
    }

    // -----------------------------------------------------------------------
    // Internal helpers
    // -----------------------------------------------------------------------

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

        // Validate input against cached schema
        let errors = validate(&args, &tool.cached_schema);
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

        // Determine timeout: tool-level overrides config default
        let timeout_ms = tool.permissions.execute_timeout
            .unwrap_or(self.config.execute_timeout);
        let timeout_dur = Duration::from_millis(timeout_ms);

        // Execute with timeout
        let execute_future = (tool.execute)(args, ctx);
        match tokio::time::timeout(timeout_dur, execute_future).await {
            Err(_elapsed) => {
                json!({
                    "content": [{ "type": "text", "text": format!("Tool \"{name}\" timed out after {timeout_ms}ms") }],
                    "isError": true
                })
            }
            Ok(Ok(result)) => {
                let text = if result.is_string() {
                    result.as_str().unwrap().to_string()
                } else {
                    serde_json::to_string(&result).unwrap_or_default()
                };
                json!({
                    "content": [{ "type": "text", "text": text }]
                })
            }
            Ok(Err(e)) => {
                json!({
                    "content": [{ "type": "text", "text": format!("Error: {e}") }],
                    "isError": true
                })
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Pagination — base64 cursor encoding
// ---------------------------------------------------------------------------

/// Paginate a slice of items.  If `page_size` is 0 (disabled), returns all
/// items.  The cursor is a base64-encoded stringified offset index.
fn paginate(items: &[Value], cursor: Option<&str>, page_size: usize) -> (Vec<Value>, Option<String>) {
    if page_size == 0 {
        return (items.to_vec(), None);
    }

    let start = cursor
        .and_then(|c| decode_cursor(c))
        .unwrap_or(0);

    if start >= items.len() {
        return (vec![], None);
    }

    let end = (start + page_size).min(items.len());
    let page = items[start..end].to_vec();

    let next = if end < items.len() {
        Some(encode_cursor(end))
    } else {
        None
    };

    (page, next)
}

fn encode_cursor(offset: usize) -> String {
    use std::io::Write;
    let plain = offset.to_string();
    let mut buf = Vec::new();
    // Simple base64 using a lookup table — avoids adding a dependency.
    let _ = write!(buf, "{}", base64_encode(plain.as_bytes()));
    String::from_utf8(buf).unwrap()
}

fn decode_cursor(cursor: &str) -> Option<usize> {
    let bytes = base64_decode(cursor)?;
    let s = std::str::from_utf8(&bytes).ok()?;
    s.parse::<usize>().ok()
}

// Minimal base64 encode/decode (no extra crate)
const B64_CHARS: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

fn base64_encode(data: &[u8]) -> String {
    let mut out = String::with_capacity((data.len() + 2) / 3 * 4);
    for chunk in data.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = if chunk.len() > 1 { chunk[1] as u32 } else { 0 };
        let b2 = if chunk.len() > 2 { chunk[2] as u32 } else { 0 };
        let triple = (b0 << 16) | (b1 << 8) | b2;
        out.push(B64_CHARS[((triple >> 18) & 0x3F) as usize] as char);
        out.push(B64_CHARS[((triple >> 12) & 0x3F) as usize] as char);
        if chunk.len() > 1 {
            out.push(B64_CHARS[((triple >> 6) & 0x3F) as usize] as char);
        } else {
            out.push('=');
        }
        if chunk.len() > 2 {
            out.push(B64_CHARS[(triple & 0x3F) as usize] as char);
        } else {
            out.push('=');
        }
    }
    out
}

fn base64_decode(input: &str) -> Option<Vec<u8>> {
    let input = input.trim_end_matches('=');
    let mut out = Vec::new();
    let mut buf: u32 = 0;
    let mut bits: u32 = 0;
    for c in input.chars() {
        let val = match c {
            'A'..='Z' => (c as u32) - ('A' as u32),
            'a'..='z' => (c as u32) - ('a' as u32) + 26,
            '0'..='9' => (c as u32) - ('0' as u32) + 52,
            '+' => 62,
            '/' => 63,
            _ => return None,
        };
        buf = (buf << 6) | val;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push(((buf >> bits) & 0xFF) as u8);
        }
    }
    Some(out)
}

// ---------------------------------------------------------------------------
// URI template matching
// ---------------------------------------------------------------------------

/// Match a URI against a simple URI template with `{param}` placeholders.
/// Returns extracted parameters or `None` if no match.
fn match_template(template: &str, uri: &str) -> Option<BTreeMap<String, String>> {
    // Build a regex from the template: {name} -> named capture group
    let mut pattern = String::from("^");
    let mut last = 0;
    let tmpl_bytes = template.as_bytes();
    let mut i = 0;
    let mut param_names: Vec<String> = Vec::new();

    while i < tmpl_bytes.len() {
        if tmpl_bytes[i] == b'{' {
            // Escape literal portion before this placeholder
            let literal = &template[last..i];
            pattern.push_str(&regex_escape(literal));

            let close = template[i..].find('}')? + i;
            let name = &template[i + 1..close];
            param_names.push(name.to_string());
            pattern.push_str("([^/]+)");
            i = close + 1;
            last = i;
        } else {
            i += 1;
        }
    }
    // Remaining literal
    pattern.push_str(&regex_escape(&template[last..]));
    pattern.push('$');

    // Simple manual regex matching — we avoid pulling in the regex crate by
    // doing a basic split-and-match approach.  For robustness we fall back to
    // a simple sequential scan.
    simple_match(&pattern, &param_names, template, uri)
}

/// Escape special regex characters in a literal string.
fn regex_escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        if "\\.*+?()[]{}|^$".contains(c) {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

/// Simple template matcher that avoids the regex crate.
/// Splits the template on `{param}` placeholders and checks that the URI
/// contains the literal segments in order, extracting the parts in between.
fn simple_match(
    _pattern: &str,
    param_names: &[String],
    template: &str,
    uri: &str,
) -> Option<BTreeMap<String, String>> {
    // Split template into literal segments around {param} placeholders
    let mut segments: Vec<&str> = Vec::new();
    let mut last = 0;
    let tmpl_bytes = template.as_bytes();
    let mut i = 0;

    while i < tmpl_bytes.len() {
        if tmpl_bytes[i] == b'{' {
            segments.push(&template[last..i]);
            let close = template[i..].find('}')? + i;
            i = close + 1;
            last = i;
        } else {
            i += 1;
        }
    }
    segments.push(&template[last..]);

    // Now match: segments[0] must be a prefix, segments[last] must be a suffix,
    // and we extract values between consecutive segments.
    if segments.is_empty() {
        return None;
    }

    if !uri.starts_with(segments[0]) {
        return None;
    }

    let mut pos = segments[0].len();
    let mut params = BTreeMap::new();

    for (idx, name) in param_names.iter().enumerate() {
        let next_segment = segments[idx + 1];
        if next_segment.is_empty() && idx + 1 == segments.len() - 1 {
            // Last segment is empty — rest of URI is the value
            params.insert(name.clone(), uri[pos..].to_string());
            pos = uri.len();
        } else {
            let found = uri[pos..].find(next_segment)?;
            let value = &uri[pos..pos + found];
            if value.is_empty() {
                return None;
            }
            params.insert(name.clone(), value.to_string());
            pos = pos + found + next_segment.len();
        }
    }

    if pos != uri.len() {
        return None;
    }

    Some(params)
}
