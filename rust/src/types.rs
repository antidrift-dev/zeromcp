use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;
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

// ---------------------------------------------------------------------------
// Resources
// ---------------------------------------------------------------------------

/// The boxed future returned by resource read closures.
pub type ReadFuture = Pin<Box<dyn Future<Output = Result<String, String>> + Send>>;

/// The type-erased read function for a static resource.
pub type ReadFn = Box<dyn Fn() -> ReadFuture + Send + Sync>;

/// The type-erased read function for a resource template (receives extracted params).
pub type TemplateReadFn =
    Box<dyn Fn(BTreeMap<String, String>) -> ReadFuture + Send + Sync>;

/// A registered static resource.
pub struct Resource {
    pub uri: String,
    pub name: String,
    pub description: String,
    pub mime_type: String,
    pub read: ReadFn,
}

/// A registered resource template (URI template with `{param}` placeholders).
pub struct ResourceTemplate {
    pub uri_template: String,
    pub name: String,
    pub description: String,
    pub mime_type: String,
    pub read: TemplateReadFn,
}

// ---------------------------------------------------------------------------
// Prompts
// ---------------------------------------------------------------------------

/// The boxed future returned by prompt render closures.
pub type RenderFuture = Pin<Box<dyn Future<Output = Result<Vec<PromptMessage>, String>> + Send>>;

/// The type-erased render function for a prompt.
pub type RenderFn =
    Box<dyn Fn(Value) -> RenderFuture + Send + Sync>;

/// A single message returned by a prompt.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PromptMessage {
    pub role: String,
    pub content: PromptContent,
}

/// Content of a prompt message.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum PromptContent {
    #[serde(rename = "text")]
    Text { text: String },
}

/// Describes a prompt argument in the listing.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PromptArgument {
    pub name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub required: Option<bool>,
}

/// A registered prompt.
pub struct Prompt {
    pub name: String,
    pub description: Option<String>,
    pub arguments: Option<Vec<PromptArgument>>,
    pub render: RenderFn,
}
