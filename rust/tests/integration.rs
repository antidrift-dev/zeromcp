use serde_json::{json, Value};
use zeromcp::{Ctx, Input, Permissions, Server, Tool};

fn make_server() -> Server {
    let mut server = Server::new();

    server.tool(
        "greet",
        Tool {
            description: "Greet someone".to_string(),
            input: Input::new().required("name", "string"),
            permissions: Permissions::default(),
            execute: Box::new(|args: Value, _ctx: Ctx| {
                Box::pin(async move {
                    let name = args["name"].as_str().unwrap_or("world");
                    Ok(Value::String(format!("Hello, {name}!")))
                })
            }),
            cached_schema: Default::default(),
        },
    );

    server.tool(
        "add",
        Tool {
            description: "Add numbers".to_string(),
            input: Input::new()
                .required("a", "number")
                .required("b", "number"),
            permissions: Permissions::default(),
            execute: Box::new(|args: Value, _ctx: Ctx| {
                Box::pin(async move {
                    let a = args["a"].as_f64().unwrap_or(0.0);
                    let b = args["b"].as_f64().unwrap_or(0.0);
                    Ok(json!(a + b))
                })
            }),
            cached_schema: Default::default(),
        },
    );

    server.tool(
        "fail",
        Tool {
            description: "Always fails".to_string(),
            input: Input::new(),
            permissions: Permissions::default(),
            execute: Box::new(|_args: Value, _ctx: Ctx| {
                Box::pin(async move { Err("something went wrong".to_string()) })
            }),
            cached_schema: Default::default(),
        },
    );

    server
}

/// Schema tests are in schema.rs. This file tests the full server round-trip
/// via its internal handle_request method. Since handle_request is private,
/// we test the public building blocks instead.

#[test]
fn tool_input_schema_generation() {
    let input = Input::new()
        .required_desc("name", "string", "A name")
        .optional("verbose", "boolean");
    let schema = input.to_json_schema();

    assert_eq!(schema.schema_type, "object");
    assert_eq!(schema.required, vec!["name"]);
    assert_eq!(schema.properties.len(), 2);
    assert_eq!(schema.properties["name"].prop_type, "string");
    assert_eq!(
        schema.properties["name"].description.as_deref(),
        Some("A name")
    );
    assert_eq!(schema.properties["verbose"].prop_type, "boolean");
}

#[test]
fn validation_catches_errors() {
    let input = Input::new()
        .required("name", "string")
        .required("count", "number");
    let schema = input.to_json_schema();

    // Missing both
    let errors = zeromcp::schema::validate(&json!({}), &schema);
    assert_eq!(errors.len(), 2);

    // Wrong type
    let errors = zeromcp::schema::validate(&json!({"name": 42, "count": 1}), &schema);
    assert_eq!(errors.len(), 1);
    assert!(errors[0].contains("expected string"));

    // Valid
    let errors = zeromcp::schema::validate(&json!({"name": "test", "count": 5}), &schema);
    assert!(errors.is_empty());
}

#[test]
fn server_registers_tools() {
    let server = make_server();
    // We can't inspect tools directly, but we can verify it doesn't panic
    // and the constructor works.
    drop(server);
}

#[test]
fn sandbox_network_check() {
    let perms = Permissions {
        network: Some(vec!["api.example.com".to_string()]),
        ..Default::default()
    };

    assert!(
        zeromcp::sandbox::check_network("test", "https://api.example.com/v1", &perms, false, false)
            .is_ok()
    );
    assert!(
        zeromcp::sandbox::check_network("test", "https://evil.com", &perms, false, false).is_err()
    );
    // Bypass allows anything
    assert!(
        zeromcp::sandbox::check_network("test", "https://evil.com", &perms, true, false).is_ok()
    );
}

#[test]
fn config_defaults() {
    let cfg = zeromcp::Config::default();
    assert!(!cfg.logging);
    assert!(!cfg.bypass_permissions);
    assert_eq!(cfg.separator, "_");
}

#[tokio::test]
async fn tool_execute_success() {
    let server = make_server();
    // We test the execute function directly
    let tool = Tool {
        description: "test".to_string(),
        input: Input::new().required("x", "string"),
        permissions: Permissions::default(),
        execute: Box::new(|args: Value, _ctx: Ctx| {
            Box::pin(async move {
                Ok(Value::String(
                    args["x"].as_str().unwrap_or("").to_string(),
                ))
            })
        }),
        cached_schema: Default::default(),
    };

    let ctx = Ctx::default();
    let result = (tool.execute)(json!({"x": "hello"}), ctx).await;
    assert_eq!(result.unwrap(), Value::String("hello".to_string()));
    drop(server);
}

#[tokio::test]
async fn tool_execute_failure() {
    let tool = Tool {
        description: "test".to_string(),
        input: Input::new(),
        permissions: Permissions::default(),
        execute: Box::new(|_args: Value, _ctx: Ctx| {
            Box::pin(async move { Err("boom".to_string()) })
        }),
        cached_schema: Default::default(),
    };

    let ctx = Ctx::default();
    let result = (tool.execute)(json!({}), ctx).await;
    assert_eq!(result.unwrap_err(), "boom");
}
