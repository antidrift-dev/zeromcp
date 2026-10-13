//! Route conformance harness (tests/conformance/run-route.js, port 14255).
//!
//! ZeroMCP does not ship an HTTP server, so this example builds a registry
//! with `create_registry` and mounts it on a minimal hand-rolled HTTP/1.1
//! loop. It stands in for "your own HTTP server" and is test-only.

use serde_json::{json, Map, Value};
use std::sync::Arc;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use zeromcp::registry::{create_registry, Registry, RegistryOptions};
use zeromcp::{Ctx, Input, Permissions, RouteConfig, Tool};

const DOCS_HTML: &str = "<!DOCTYPE html>\n<html>\n<head>\n  <title>ZeroMCP API</title>\n  <meta charset=\"utf-8\"/>\n  <link rel=\"stylesheet\" href=\"https://unpkg.com/swagger-ui-dist/swagger-ui.css\">\n</head>\n<body>\n<div id=\"swagger-ui\"></div>\n<script src=\"https://unpkg.com/swagger-ui-dist/swagger-ui-bundle.js\"></script>\n<script>SwaggerUIBundle({ url: '/openapi.json', dom_id: '#swagger-ui' })</script>\n</body>\n</html>";

#[tokio::main]
async fn main() {
    let tools = vec![
        (
            "greet",
            Tool {
                description: "Greet a person by name".to_string(),
                input: Input::new().required_desc("name", "string", "The person to greet"),
                permissions: Permissions::default(),
                execute: Box::new(|args: Value, _ctx: Ctx| {
                    Box::pin(async move {
                        let name = args["name"].as_str().unwrap_or("world");
                        Ok(Value::String(format!("Hello, {name}!")))
                    })
                }),
                cached_schema: Default::default(),
                route: Some(RouteConfig {
                    method: "GET".to_string(),
                    path: "/greet/:name".to_string(),
                }),
            },
        ),
        (
            "echo",
            Tool {
                description: "Echo a message back".to_string(),
                input: Input::new().required_desc("message", "string", "The message to echo"),
                permissions: Permissions::default(),
                execute: Box::new(|args: Value, _ctx: Ctx| {
                    Box::pin(async move {
                        Ok(json!({
                            "message": args["message"],
                            "echoed": true
                        }))
                    })
                }),
                cached_schema: Default::default(),
                route: Some(RouteConfig {
                    method: "POST".to_string(),
                    path: "/echo".to_string(),
                }),
            },
        ),
    ];

    let registry = Arc::new(create_registry(tools, RegistryOptions::default()).await);

    let addr = "0.0.0.0:14255";
    let listener = TcpListener::bind(addr)
        .await
        .unwrap_or_else(|e| panic!("failed to bind {addr}: {e}"));
    eprintln!("[route_test] listening on http://{addr}");
    loop {
        let (stream, _) = match listener.accept().await {
            Ok(pair) => pair,
            Err(e) => {
                eprintln!("[route_test] accept error: {e}");
                continue;
            }
        };
        let registry = Arc::clone(&registry);
        tokio::spawn(async move { handle_conn(registry, stream).await });
    }
}

/// Read one HTTP/1.1 request: returns (method, path, body).
async fn read_request(stream: &mut TcpStream) -> Option<(String, String, Vec<u8>)> {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 8192];
    let header_end = loop {
        let n = stream.read(&mut chunk).await.ok()?;
        if n == 0 {
            return None;
        }
        buf.extend_from_slice(&chunk[..n]);
        if let Some(i) = buf.windows(4).position(|w| w == b"\r\n\r\n") {
            break i + 4;
        }
    };
    let head = std::str::from_utf8(&buf[..header_end]).ok()?.to_string();
    let mut lines = head.lines();
    let mut request_line = lines.next()?.split(' ');
    let method = request_line.next()?.to_uppercase();
    let target = request_line.next()?;
    let path = target.split('?').next().unwrap_or("/").to_string();
    let content_length = lines
        .filter_map(|l| l.split_once(':'))
        .find(|(k, _)| k.trim().eq_ignore_ascii_case("content-length"))
        .and_then(|(_, v)| v.trim().parse::<usize>().ok())
        .unwrap_or(0);
    let mut body = buf[header_end..].to_vec();
    while body.len() < content_length {
        let n = stream.read(&mut chunk).await.ok()?;
        if n == 0 {
            break;
        }
        body.extend_from_slice(&chunk[..n]);
    }
    body.truncate(content_length);
    Some((method, path, body))
}

/// Match `/greet/:name` against `/greet/World`, returning the path params.
fn match_route(pattern: &str, path: &str) -> Option<Map<String, Value>> {
    let pat: Vec<&str> = pattern.trim_matches('/').split('/').collect();
    let got: Vec<&str> = path.trim_matches('/').split('/').collect();
    if pat.len() != got.len() {
        return None;
    }
    let mut params = Map::new();
    for (p, g) in pat.iter().zip(got.iter()) {
        if let Some(name) = p.strip_prefix(':') {
            if g.is_empty() {
                return None;
            }
            params.insert(name.to_string(), Value::String(g.to_string()));
        } else if p != g {
            return None;
        }
    }
    Some(params)
}

async fn route(registry: &Registry, method: &str, path: &str, body: &[u8]) -> (u16, &'static str, String) {
    match (method, path) {
        ("GET", "/health") => return (200, "application/json", r#"{"status":"ok"}"#.to_string()),
        ("GET", "/openapi.json") => return (200, "application/json", registry.openapi.to_string()),
        ("GET", "/docs") => return (200, "text/html", DOCS_HTML.to_string()),
        ("POST", "/mcp") => {
            return match serde_json::from_slice::<Value>(body) {
                Ok(req) => {
                    let resp = (registry.mcp)(req)
                        .await
                        .unwrap_or_else(|| json!({ "jsonrpc": "2.0", "result": {} }));
                    (200, "application/json", resp.to_string())
                }
                Err(e) => {
                    let err = json!({
                        "jsonrpc": "2.0",
                        "error": { "code": -32700, "message": format!("Parse error: {e}") }
                    });
                    (400, "application/json", err.to_string())
                }
            };
        }
        _ => {}
    }

    for r in &registry.routes {
        if !r.method.eq_ignore_ascii_case(method) {
            continue;
        }
        let Some(mut args) = match_route(&r.path, path) else { continue };
        if method != "GET" && !body.is_empty() {
            match serde_json::from_slice::<Value>(body) {
                Ok(Value::Object(fields)) => args.extend(fields),
                Ok(_) => {}
                Err(e) => {
                    let err = json!({ "ok": false, "error": format!("Invalid JSON body: {e}") });
                    return (400, "application/json", err.to_string());
                }
            }
        }
        let ctx = registry.ctx_for(&r.tool);
        return match (r.tool.execute)(Value::Object(args), ctx).await {
            Ok(result) => (200, "application/json", json!({ "ok": true, "result": result }).to_string()),
            Err(e) => (500, "application/json", json!({ "ok": false, "error": e }).to_string()),
        };
    }

    (404, "application/json", r#"{"error":"Not found"}"#.to_string())
}

async fn handle_conn(registry: Arc<Registry>, mut stream: TcpStream) {
    let Some((method, path, body)) = read_request(&mut stream).await else { return };
    let (status, content_type, body) = route(&registry, &method, &path, &body).await;
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        _ => "Internal Server Error",
    };
    let response = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: {content_type}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    let _ = stream.write_all(response.as_bytes()).await;
}
