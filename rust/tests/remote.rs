//! Remote federation: `Server::prepare` + `handle_request`, and `create_registry`
//! with `RegistryOptions::remote`, against a loopback mock upstream.

use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use zeromcp::registry::{create_registry, RegistryOptions};
use zeromcp::{Ctx, Input, Permissions, RemoteServer, Server, Tool};

const PAGES_TEXT: &str = r#"{"pages":[]}"#;

struct Upstream {
    url: String,
    /// `Authorization` header of every request received (None if absent).
    auth_seen: Arc<Mutex<Vec<Option<String>>>>,
}

fn response_for(request: &Value) -> Value {
    let id = request["id"].clone();
    let body = match request["method"].as_str().unwrap_or("") {
        "initialize" => json!({ "result": {
            "protocolVersion": "2025-03-26", "capabilities": {},
            "serverInfo": { "name": "probeo", "version": "test" }
        } }),
        "tools/list" => json!({ "result": { "tools": [
            { "name": "list_pages", "description": "Lists pages.",
              "inputSchema": { "type": "object", "properties": { "domain": { "type": "string" } }, "required": ["domain"] } },
            { "name": "get_page", "description": "Gets a page.",
              "inputSchema": { "type": "object", "properties": { "url": { "type": "string" } }, "required": ["url"] } }
        ] } }),
        "tools/call" => json!({ "result": { "content": [{ "type": "text", "text": PAGES_TEXT }] } }),
        other => json!({ "error": { "message": format!("Unexpected method: {other}") } }),
    };
    let mut out = json!({ "jsonrpc": "2.0", "id": id });
    for (k, v) in body.as_object().unwrap() {
        out[k] = v.clone();
    }
    out
}

async fn serve_one(mut stream: TcpStream, status: u16, auth_seen: Arc<Mutex<Vec<Option<String>>>>) {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 8192];
    let header_end = loop {
        let n = match stream.read(&mut chunk).await {
            Ok(0) | Err(_) => return,
            Ok(n) => n,
        };
        buf.extend_from_slice(&chunk[..n]);
        if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break i + 4;
        }
    };
    let head = String::from_utf8_lossy(&buf[..header_end]).to_string();
    let header = |name: &str| {
        head.lines()
            .filter_map(|l| l.split_once(':'))
            .find(|(k, _)| k.trim().eq_ignore_ascii_case(name))
            .map(|(_, v)| v.trim().to_string())
    };
    let len: usize = header("content-length").and_then(|v| v.parse().ok()).unwrap_or(0);
    auth_seen.lock().unwrap().push(header("authorization"));
    let mut body = buf[header_end..].to_vec();
    while body.len() < len {
        match stream.read(&mut chunk).await {
            Ok(0) | Err(_) => break,
            Ok(n) => body.extend_from_slice(&chunk[..n]),
        }
    }
    let request: Value = serde_json::from_slice(&body[..len.min(body.len())]).unwrap_or(Value::Null);
    let payload = if status == 200 {
        response_for(&request).to_string()
    } else {
        r#"{"error":"nope"}"#.to_string()
    };
    let resp = format!(
        "HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{payload}",
        payload.len()
    );
    let _ = stream.write_all(resp.as_bytes()).await;
}

async fn start_upstream(status: u16) -> Upstream {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let auth_seen = Arc::new(Mutex::new(Vec::new()));
    let seen = Arc::clone(&auth_seen);
    tokio::spawn(async move {
        loop {
            let Ok((stream, _)) = listener.accept().await else { return };
            tokio::spawn(serve_one(stream, status, Arc::clone(&seen)));
        }
    });
    Upstream { url, auth_seen }
}

fn remote(name: &str, url: &str) -> RemoteServer {
    RemoteServer { name: name.to_string(), url: url.to_string(), auth: None, tools: None }
}

/// Build a `Server` from a temp config file holding `remote`.
fn server_with_remote(tag: &str, remote: Vec<RemoteServer>) -> Server {
    let path = std::env::temp_dir().join(format!("zeromcp-remote-{}-{tag}.json", std::process::id()));
    std::fs::write(&path, json!({ "remote": remote }).to_string()).unwrap();
    let server = Server::from_config(path.to_str().unwrap());
    let _ = std::fs::remove_file(&path);
    server
}

fn local_tool(text: &'static str) -> Tool {
    Tool {
        description: "Local".to_string(),
        input: Input::new(),
        permissions: Permissions::default(),
        execute: Box::new(move |_args: Value, _ctx: Ctx| Box::pin(async move { Ok(json!(text)) })),
        cached_schema: Default::default(),
        route: None,
    }
}

async fn list_names(server: &Server) -> Vec<String> {
    let resp = server
        .handle_request(&json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/list" }))
        .await
        .unwrap();
    resp["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap().to_string())
        .collect()
}

async fn call(server: &Server, name: &str, args: Value) -> Value {
    server
        .handle_request(&json!({
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": { "name": name, "arguments": args }
        }))
        .await
        .unwrap()
}

// ---------------------------------------------------------------------------
// Server::prepare + handle_request
// ---------------------------------------------------------------------------

#[tokio::test]
async fn remote_tools_listed_and_callable_via_handle_request() {
    let up = start_upstream(200).await;
    let mut server = server_with_remote("list", vec![remote("probeo", &up.url)]);
    server.prepare().await;

    assert_eq!(list_names(&server).await, vec!["probeo.get_page", "probeo.list_pages"]);

    let resp = call(&server, "probeo.list_pages", json!({ "domain": "example.com" })).await;
    assert_eq!(resp["result"]["content"], json!([{ "type": "text", "text": PAGES_TEXT }]));
    assert!(resp["result"]["isError"].is_null());
}

#[tokio::test]
async fn remote_schema_is_carried_over() {
    let up = start_upstream(200).await;
    let mut server = server_with_remote("schema", vec![remote("probeo", &up.url)]);
    server.prepare().await;
    let resp = call(&server, "probeo.list_pages", json!({})).await;
    assert_eq!(resp["result"]["isError"], true);
    assert!(resp["result"]["content"][0]["text"].as_str().unwrap().contains("domain"));
}

#[tokio::test]
async fn allowlist_limits_remote_tools() {
    let up = start_upstream(200).await;
    let mut only = remote("probeo", &up.url);
    only.tools = Some(vec!["list_pages".to_string()]);
    let mut server = server_with_remote("allow", vec![only]);
    server.prepare().await;
    assert_eq!(list_names(&server).await, vec!["probeo.list_pages"]);
}

#[tokio::test]
async fn non_http_url_is_skipped_and_others_connect() {
    let up = start_upstream(200).await;
    let mut server = server_with_remote(
        "ftp",
        vec![remote("bad", "ftp://example.com/mcp"), remote("probeo", &up.url)],
    );
    server.prepare().await;
    assert_eq!(list_names(&server).await, vec!["probeo.get_page", "probeo.list_pages"]);
}

#[tokio::test]
async fn non_2xx_upstream_is_skipped() {
    let bad = start_upstream(500).await;
    let good = start_upstream(200).await;
    let mut server = server_with_remote(
        "500",
        vec![remote("broken", &bad.url), remote("probeo", &good.url)],
    );
    server.prepare().await;
    assert_eq!(list_names(&server).await, vec!["probeo.get_page", "probeo.list_pages"]);
}

#[tokio::test]
async fn local_tool_registered_before_prepare_overrides_remote() {
    let up = start_upstream(200).await;
    let mut server = server_with_remote("override-before", vec![remote("probeo", &up.url)]);
    server.tool("probeo.list_pages", local_tool("local override"));
    server.prepare().await;
    let resp = call(&server, "probeo.list_pages", json!({})).await;
    assert_eq!(resp["result"]["content"][0]["text"], "local override");
}

#[tokio::test]
async fn local_tool_registered_after_prepare_overrides_remote() {
    let up = start_upstream(200).await;
    let mut server = server_with_remote("override-after", vec![remote("probeo", &up.url)]);
    server.prepare().await;
    server.tool("probeo.list_pages", local_tool("local override"));
    let resp = call(&server, "probeo.list_pages", json!({})).await;
    assert_eq!(resp["result"]["content"][0]["text"], "local override");
}

#[tokio::test]
async fn env_auth_sends_bearer_token() {
    std::env::set_var("ZEROMCP_REMOTE_TEST_TOKEN", "s3cret");
    let up = start_upstream(200).await;
    let mut with_auth = remote("probeo", &up.url);
    with_auth.auth = Some("env:ZEROMCP_REMOTE_TEST_TOKEN".to_string());
    let mut server = server_with_remote("auth", vec![with_auth]);
    server.prepare().await;
    call(&server, "probeo.list_pages", json!({ "domain": "x" })).await;

    let seen = up.auth_seen.lock().unwrap().clone();
    assert_eq!(seen.len(), 3, "initialize, tools/list, tools/call");
    for header in seen {
        assert_eq!(header.as_deref(), Some("Bearer s3cret"));
    }
}

#[tokio::test]
async fn no_auth_sends_no_header() {
    let up = start_upstream(200).await;
    let mut server = server_with_remote("noauth", vec![remote("probeo", &up.url)]);
    server.prepare().await;
    let seen = up.auth_seen.lock().unwrap().clone();
    assert_eq!(seen, vec![None, None]);
}

#[tokio::test]
async fn prepare_is_idempotent() {
    let up = start_upstream(200).await;
    let mut server = server_with_remote("idem", vec![remote("probeo", &up.url)]);
    server.prepare().await;
    server.prepare().await;
    assert_eq!(up.auth_seen.lock().unwrap().len(), 2);
}

// ---------------------------------------------------------------------------
// create_registry with RegistryOptions::remote
// ---------------------------------------------------------------------------

#[tokio::test]
async fn registry_lists_and_calls_remote_tools() {
    let up = start_upstream(200).await;
    let registry = create_registry(
        Vec::<(String, Tool)>::new(),
        RegistryOptions { remote: vec![remote("probeo", &up.url)] },
    )
    .await;

    let listed = (registry.mcp)(json!({ "jsonrpc": "2.0", "id": 1, "method": "tools/list" }))
        .await
        .unwrap();
    assert_eq!(listed["result"]["tools"][0]["name"], "probeo.get_page");
    assert_eq!(listed["result"]["tools"][1]["name"], "probeo.list_pages");

    let called = (registry.mcp)(json!({
        "jsonrpc": "2.0", "id": 2, "method": "tools/call",
        "params": { "name": "probeo.list_pages", "arguments": { "domain": "example.com" } }
    }))
    .await
    .unwrap();
    assert_eq!(called["result"]["content"], json!([{ "type": "text", "text": PAGES_TEXT }]));
}

#[tokio::test]
async fn registry_local_tool_overrides_remote() {
    let up = start_upstream(200).await;
    let registry = create_registry(
        vec![("probeo.list_pages", local_tool("local override"))],
        RegistryOptions { remote: vec![remote("probeo", &up.url)] },
    )
    .await;
    let called = (registry.mcp)(json!({
        "jsonrpc": "2.0", "id": 1, "method": "tools/call",
        "params": { "name": "probeo.list_pages", "arguments": {} }
    }))
    .await
    .unwrap();
    assert_eq!(called["result"]["content"][0]["text"], "local override");
}

#[tokio::test]
async fn registry_remote_tools_not_in_routes_or_openapi() {
    let up = start_upstream(200).await;
    let registry = create_registry(
        Vec::<(String, Tool)>::new(),
        RegistryOptions { remote: vec![remote("probeo", &up.url)] },
    )
    .await;
    assert!(registry.routes.is_empty());
    assert_eq!(registry.openapi["paths"], json!({}));
}
