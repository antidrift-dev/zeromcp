//! # zeromcp
//!
//! Zero-config MCP runtime for Rust.
//!
//! ```rust,no_run
//! use zeromcp::{Server, Tool, Input, Ctx, Permissions};
//! use serde_json::{json, Value};
//!
//! #[tokio::main]
//! async fn main() {
//!     let mut server = Server::new();
//!
//!     server.tool("hello", Tool {
//!         description: "Say hello".to_string(),
//!         input: Input::new().required("name", "string"),
//!         permissions: Permissions::default(),
//!         execute: Box::new(|args: Value, _ctx: Ctx| Box::pin(async move {
//!             let name = args["name"].as_str().unwrap_or("world");
//!             Ok(Value::String(format!("Hello, {name}!")))
//!         })),
//!     });
//!
//!     server.serve().await;
//! }
//! ```

pub mod config;
pub mod sandbox;
pub mod schema;
pub mod server;
pub mod types;

// Re-export the main API surface.
pub use config::Config;
pub use schema::Input;
pub use server::Server;
pub use types::{BoxFuture, Ctx, ExecuteFn, Permissions, Tool, ToolResult};
