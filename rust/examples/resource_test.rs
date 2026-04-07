use serde_json::{json, Value};
use zeromcp::{
    Ctx, Input, Permissions, Prompt, PromptArgument, PromptContent, PromptMessage, Resource,
    Server, Tool,
};

#[tokio::main]
async fn main() {
    let mut server = Server::new();

    // 1. Register a "hello" tool
    server.tool(
        "hello",
        Tool {
            description: "Say hello to someone".to_string(),
            input: Input::new().required_desc("name", "string", "Who to greet"),
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

    // 2. Register resources
    server.resource(Resource {
        uri: "resource:///data.json".to_string(),
        name: "data".to_string(),
        description: "Static JSON data blob".to_string(),
        mime_type: "application/json".to_string(),
        read: Box::new(|| {
            Box::pin(async {
                Ok(json!({"key": "value", "items": [1, 2, 3], "status": "ok"}).to_string())
            })
        }),
    });

    server.resource(Resource {
        uri: "resource:///dynamic".to_string(),
        name: "dynamic".to_string(),
        description: "Dynamic JSON resource that changes per read".to_string(),
        mime_type: "application/json".to_string(),
        read: Box::new(|| {
            Box::pin(async {
                let ts = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_secs();
                Ok(json!({"timestamp": ts, "source": "dynamic"}).to_string())
            })
        }),
    });

    server.resource(Resource {
        uri: "resource:///readme.md".to_string(),
        name: "readme".to_string(),
        description: "Project README in markdown".to_string(),
        mime_type: "text/markdown".to_string(),
        read: Box::new(|| {
            Box::pin(async {
                Ok("# ZeroMCP\n\nMinimal MCP server framework.\n".to_string())
            })
        }),
    });

    // 3. Register prompt "greet" with arguments and render function
    server.prompt(Prompt {
        name: "greet".to_string(),
        description: Some("Generate a greeting for a user".to_string()),
        arguments: Some(vec![
            PromptArgument {
                name: "name".to_string(),
                description: Some("Name of the person to greet".to_string()),
                required: Some(true),
            },
            PromptArgument {
                name: "tone".to_string(),
                description: Some("Greeting tone: formal or casual".to_string()),
                required: Some(false),
            },
        ]),
        render: Box::new(|args: Value| {
            Box::pin(async move {
                let name = args["name"].as_str().unwrap_or("friend");
                let tone = args["tone"].as_str().unwrap_or("casual");

                let greeting = match tone {
                    "formal" => format!("Good day, {name}. How may I assist you?"),
                    _ => format!("Hey {name}! What's up?"),
                };

                Ok(vec![PromptMessage {
                    role: "user".to_string(),
                    content: PromptContent::Text { text: greeting },
                }])
            })
        }),
    });

    // 4. Serve on stdio
    server.serve().await;
}
