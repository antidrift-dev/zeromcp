use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::future::Future;
use std::pin::Pin;

/// Permissions a tool can request.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Permissions {
    /// Network allowlist. `None` = full access, `Some(vec![])` = no access,
    /// `Some(vec!["api.example.com"])` = only those hosts.
    #[serde(default)]
    pub network: Option<Vec<String>>,

    /// Filesystem access: `None` = denied, `Some("read")` or `Some("write")`.
    #[serde(default)]
    pub fs: Option<String>,

    /// Whether child-process execution is allowed.
    #[serde(default)]
    pub exec: bool,

    /// Per-tool execute timeout in milliseconds. Overrides config default.
    #[serde(default)]
    pub execute_timeout: Option<u64>,
}

/// Context passed to every tool execution.
#[derive(Clone)]
pub struct Ctx {
    pub permissions: Permissions,
    pub logging: bool,
    pub bypass: bool,
}

impl Default for Ctx {
    fn default() -> Self {
        Self {
            permissions: Permissions::default(),
            logging: false,
            bypass: false,
        }
    }
}

/// The return type of a tool's execute function.
pub type ToolResult = Result<Value, String>;

/// The boxed future returned by execute closures.
pub type BoxFuture = Pin<Box<dyn Future<Output = ToolResult> + Send>>;

/// The type-erased execute function.
pub type ExecuteFn =
    Box<dyn Fn(Value, Ctx) -> BoxFuture + Send + Sync>;

/// A registered tool.
pub struct Tool {
    pub description: String,
    pub input: crate::schema::Input,
    pub permissions: Permissions,
    pub execute: ExecuteFn,
    /// Pre-computed JSON schema, populated at registration time.
    pub cached_schema: crate::schema::JsonSchema,
}
