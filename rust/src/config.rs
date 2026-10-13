use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::Path;

/// A remote MCP server whose tools are federated as `<name>.<tool>`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RemoteServer {
    /// Namespace prefix for this server's tools.
    pub name: String,
    /// HTTP(S) URL of the server's JSON-RPC endpoint.
    pub url: String,
    /// Bearer token, or `env:VAR` to read it from the environment.
    #[serde(default)]
    pub auth: Option<String>,
    /// Allowlist of upstream tool names to expose. `None` exposes all.
    #[serde(default)]
    pub tools: Option<Vec<String>>,
}

/// Configuration loaded from `zeromcp.config.json`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Config {
    /// Whether to log sandbox decisions to stderr.
    #[serde(default)]
    pub logging: bool,

    /// Bypass permission checks (allow everything with a warning).
    #[serde(default)]
    pub bypass_permissions: bool,

    /// Tool-name separator (default `_`).
    #[serde(default = "default_separator")]
    pub separator: String,

    /// Default execute timeout in milliseconds (default 30000).
    #[serde(default = "default_execute_timeout")]
    pub execute_timeout: u64,

    /// Cache credentials after first read when true (default). Set false to re-read on every tool call.
    #[serde(default = "default_cache_credentials")]
    pub cache_credentials: bool,

    /// Title used in the OpenAPI spec (default "ZeroMCP").
    #[serde(default = "default_title")]
    pub title: String,

    /// Remote MCP servers to federate as `<server>.<tool>`.
    #[serde(default)]
    pub remote: Vec<RemoteServer>,

    /// Page size for paginated list responses. 0 = no pagination (default).
    #[serde(default)]
    pub page_size: usize,

    /// Icon applied to the server, tools, resources and prompts: a data URI,
    /// an http(s) URL (fetched), or a file path (read). Resolved to a data URI
    /// by `Server::prepare`.
    #[serde(default)]
    pub icon: Option<String>,
}

fn default_separator() -> String {
    "_".to_string()
}

fn default_execute_timeout() -> u64 {
    30000
}

fn default_cache_credentials() -> bool {
    true
}

fn default_title() -> String {
    "ZeroMCP".to_string()
}

impl Default for Config {
    fn default() -> Self {
        Self {
            logging: false,
            bypass_permissions: false,
            separator: "_".to_string(),
            execute_timeout: 30000,
            cache_credentials: true,
            title: "ZeroMCP".to_string(),
            remote: Vec::new(),
            page_size: 0,
            icon: None,
        }
    }
}

/// Attempt to load a `Config` from a JSON file. Returns `Config::default()`
/// if the file does not exist.
///
/// # Panics
/// If the config asks for an `http` transport. ZeroMCP no longer ships an
/// HTTP server; mount `zeromcp::registry::create_registry` or
/// `Server::handle_request` in your own HTTP server instead.
pub fn load_config(path: &str) -> Config {
    let p = Path::new(path);
    if !p.exists() {
        return Config::default();
    }
    match std::fs::read_to_string(p) {
        Ok(raw) => parse_config(&raw),
        Err(e) => {
            eprintln!("[zeromcp] Warning: failed to read config: {e}");
            Config::default()
        }
    }
}

const HTTP_TRANSPORT_ERROR: &str = "[zeromcp] \"transport\" type \"http\" is not supported: ZeroMCP no longer ships an HTTP server. Mount zeromcp::registry::create_registry (routes, openapi, mcp) or Server::handle_request in your own HTTP server.";

fn parse_config(raw: &str) -> Config {
    let value: Value = match serde_json::from_str(raw) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("[zeromcp] Warning: failed to parse config: {e}");
            return Config::default();
        }
    };
    if wants_http_transport(&value) {
        panic!("{HTTP_TRANSPORT_ERROR}");
    }
    serde_json::from_value(value).unwrap_or_else(|e| {
        eprintln!("[zeromcp] Warning: failed to parse config: {e}");
        Config::default()
    })
}

fn wants_http_transport(config: &Value) -> bool {
    let is_http = |t: &Value| t.get("type").and_then(Value::as_str) == Some("http");
    match config.get("transport") {
        Some(Value::Array(entries)) => entries.iter().any(is_http),
        Some(t @ Value::Object(_)) => is_http(t),
        _ => false,
    }
}

/// Resolve a remote server's `auth` value: `env:VAR` reads `VAR` from the
/// environment (warning and returning `None` if it is unset or empty);
/// anything else is returned as-is.
pub fn resolve_auth(auth: Option<&str>) -> Option<String> {
    let auth = auth.filter(|a| !a.is_empty())?;
    if let Some(var) = auth.strip_prefix("env:") {
        return match std::env::var(var) {
            Ok(v) if !v.is_empty() => Some(v),
            _ => {
                eprintln!("[zeromcp] Warning: environment variable {var} not set");
                None
            }
        };
    }
    Some(auth.to_string())
}

fn icon_mime(path: &str) -> &'static str {
    let ext = Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .map(|e| e.to_ascii_lowercase());
    match ext.as_deref() {
        Some("png") => "image/png",
        Some("jpg") | Some("jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("svg") => "image/svg+xml",
        Some("ico") => "image/x-icon",
        Some("webp") => "image/webp",
        _ => "image/png",
    }
}

/// Resolve an icon config value to a data URI. A `data:` value passes
/// through; an http(s) URL is fetched; anything else is read as a file path
/// (a leading `~` expands to `$HOME`). Failures warn and return `None`.
pub(crate) async fn resolve_icon(icon: &str) -> Option<String> {
    use crate::server::base64_encode;

    if icon.is_empty() {
        return None;
    }
    if icon.starts_with("data:") {
        return Some(icon.to_string());
    }

    if icon.starts_with("http://") || icon.starts_with("https://") {
        let res = match reqwest::get(icon).await {
            Ok(r) => r,
            Err(e) => {
                eprintln!("[zeromcp] Warning: failed to fetch icon {icon}: {e}");
                return None;
            }
        };
        if !res.status().is_success() {
            eprintln!(
                "[zeromcp] Warning: failed to fetch icon {icon}: {}",
                res.status().as_u16()
            );
            return None;
        }
        let content_type = res
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .filter(|v| !v.is_empty())
            .unwrap_or("image/png")
            .to_string();
        return match res.bytes().await {
            Ok(buf) => Some(format!("data:{content_type};base64,{}", base64_encode(&buf))),
            Err(e) => {
                eprintln!("[zeromcp] Warning: failed to fetch icon {icon}: {e}");
                None
            }
        };
    }

    let path = match icon.strip_prefix('~') {
        Some(rest) => format!("{}{rest}", std::env::var("HOME").unwrap_or_default()),
        None => icon.to_string(),
    };
    match tokio::fs::read(&path).await {
        Ok(buf) => Some(format!(
            "data:{};base64,{}",
            icon_mime(&path),
            base64_encode(&buf)
        )),
        Err(e) => {
            eprintln!("[zeromcp] Warning: failed to read icon file {icon}: {e}");
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn missing_file_returns_default() {
        let cfg = load_config("/tmp/nonexistent_zeromcp_config_12345.json");
        assert!(!cfg.logging);
        assert!(!cfg.bypass_permissions);
        assert_eq!(cfg.separator, "_");
    }

    #[test]
    fn deserialize_config() {
        let json = r#"{"logging": true, "bypass_permissions": true, "separator": "."}"#;
        let cfg: Config = serde_json::from_str(json).unwrap();
        assert!(cfg.logging);
        assert!(cfg.bypass_permissions);
        assert_eq!(cfg.separator, ".");
    }

    #[test]
    fn page_size_deserializes_and_defaults_to_zero() {
        let cfg: Config = serde_json::from_str(r#"{"page_size": 2}"#).unwrap();
        assert_eq!(cfg.page_size, 2);
        let cfg: Config = serde_json::from_str("{}").unwrap();
        assert_eq!(cfg.page_size, 0);
    }

    #[test]
    fn remote_and_icon_deserialize() {
        let cfg: Config = serde_json::from_str(
            r#"{"icon": "data:image/png;base64,AA==", "remote": [{"name": "probeo", "url": "http://x", "auth": "env:T", "tools": ["a"]}]}"#,
        )
        .unwrap();
        assert_eq!(cfg.icon.as_deref(), Some("data:image/png;base64,AA=="));
        assert_eq!(cfg.remote.len(), 1);
        assert_eq!(cfg.remote[0].name, "probeo");
        assert_eq!(cfg.remote[0].auth.as_deref(), Some("env:T"));
        assert_eq!(cfg.remote[0].tools, Some(vec!["a".to_string()]));
    }

    #[test]
    #[should_panic(expected = "create_registry")]
    fn http_transport_array_panics() {
        parse_config(r#"{"transport": [{"type": "stdio"}, {"type": "http", "port": 4242}]}"#);
    }

    #[test]
    #[should_panic(expected = "create_registry")]
    fn http_transport_object_panics() {
        parse_config(r#"{"transport": {"type": "http"}}"#);
    }

    #[test]
    #[should_panic(expected = "create_registry")]
    fn http_transport_in_file_panics() {
        let path = temp_path("http-transport.json");
        std::fs::write(&path, r#"{"transport": {"type": "http", "port": 4242}}"#).unwrap();
        let path_str = path.to_str().unwrap().to_string();
        let result = std::panic::catch_unwind(|| load_config(&path_str));
        let _ = std::fs::remove_file(&path);
        if let Err(e) = result {
            std::panic::resume_unwind(e);
        }
    }

    #[test]
    fn stdio_transport_loads() {
        let cfg = parse_config(r#"{"transport": [{"type": "stdio"}], "logging": true}"#);
        assert!(cfg.logging);
        let cfg = parse_config(r#"{"transport": {"type": "stdio"}}"#);
        assert!(!cfg.logging);
    }

    #[test]
    fn invalid_json_falls_back_to_default() {
        let cfg = parse_config("{not json");
        assert_eq!(cfg.separator, "_");
    }

    #[test]
    fn resolve_auth_literal_and_env() {
        assert_eq!(resolve_auth(None), None);
        assert_eq!(resolve_auth(Some("tok")), Some("tok".to_string()));
        std::env::set_var("ZEROMCP_TEST_AUTH_SET", "secret");
        assert_eq!(
            resolve_auth(Some("env:ZEROMCP_TEST_AUTH_SET")),
            Some("secret".to_string())
        );
        assert_eq!(resolve_auth(Some("env:ZEROMCP_TEST_AUTH_UNSET_XYZ")), None);
    }

    fn temp_path(name: &str) -> std::path::PathBuf {
        std::env::temp_dir().join(format!("zeromcp-{}-{name}", std::process::id()))
    }

    #[tokio::test]
    async fn resolve_icon_data_uri_passes_through() {
        let uri = "data:image/png;base64,AAAA";
        assert_eq!(resolve_icon(uri).await.as_deref(), Some(uri));
    }

    #[tokio::test]
    async fn resolve_icon_svg_file() {
        let path = temp_path("icon.svg");
        std::fs::write(&path, "<svg/>").unwrap();
        let icon = resolve_icon(path.to_str().unwrap()).await.unwrap();
        let _ = std::fs::remove_file(&path);
        assert!(icon.starts_with("data:image/svg+xml;base64,"), "{icon}");
        assert_eq!(
            icon,
            format!(
                "data:image/svg+xml;base64,{}",
                crate::server::base64_encode(b"<svg/>")
            )
        );
    }

    #[tokio::test]
    async fn resolve_icon_missing_file_is_none() {
        assert_eq!(resolve_icon("/nonexistent/zeromcp/icon.png").await, None);
    }

    #[tokio::test]
    async fn resolve_icon_fetches_url() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut buf = [0u8; 4096];
            let _ = stream.read(&mut buf).await;
            let body = b"GIF89a";
            let head = format!(
                "HTTP/1.1 200 OK\r\nContent-Type: image/gif\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            stream.write_all(head.as_bytes()).await.unwrap();
            stream.write_all(body).await.unwrap();
        });
        let icon = resolve_icon(&format!("http://{addr}/icon.gif")).await.unwrap();
        assert!(icon.starts_with("data:image/gif;base64,"), "{icon}");
    }
}
