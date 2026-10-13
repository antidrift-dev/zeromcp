# Getting Started

Get ZeroMCP running in under 3 minutes. Pick your language, build a tool, connect it to Claude Code or Cursor.

## Install

**Node.js**

```
npm install -g zeromcp
```

**Python**

```
pip install zeromcp
```

**Go**

```
go get github.com/antidrift-dev/zeromcp-go
```

**Rust**

```
# Cargo.toml
[dependencies]
zeromcp = "0.1"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tokio = { version = "1", features = ["full"] }
```

**Kotlin**

```
// build.gradle.kts
plugins {
    kotlin("jvm") version "2.0.0"
    application
}

dependencies {
    implementation("dev.antidrift:zeromcp:0.1.0")
}

application {
    mainClass.set("MainKt")
}
```

**Java**

```
<!-- pom.xml -->
<dependency>
    <groupId>dev.antidrift</groupId>
    <artifactId>zeromcp</artifactId>
    <version>0.1.0</version>
</dependency>
```

**C#**

```
dotnet new console -n MyMcpServer
cd MyMcpServer
dotnet add package ZeroMcp
```

**Swift**

```
// Package.swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MyMcpServer",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(
            url: "https://github.com/antidrift-dev/zeromcp-swift",
            from: "0.1.0"
        )
    ],
    targets: [
        .executableTarget(
            name: "MyMcpServer",
            dependencies: [
                .product(
                    name: "ZeroMcp",
                    package: "zeromcp-swift"
                )
            ]
        )
    ]
)
```

**Ruby**

```
gem install zeromcp
```

**PHP**

```
composer global require antidrift/zeromcp
```

**Node.js**

Requires Node.js 14+. Also works on Bun and Deno.

**Python**

Requires Python 3.9+. Zero external dependencies.

**Go**

Requires Go 1.22+.

**Rust**

**Kotlin**

Requires Kotlin 2.0+ and JVM 21.

**Java**

Requires Java 17+.

**C#**

Requires .NET 8+. Available on NuGet.

**Swift**

Requires Swift 5.9+ and macOS 13+.

**Ruby**

Requires Ruby 3.0+. Zero external dependencies.

**PHP**

Requires PHP 8.1+. No extensions required.

## Create a tool

**Node.js**

Drop a file in `./tools/`. ZeroMCP discovers it automatically.

**Python**

Drop a file in `./tools/`. ZeroMCP discovers it automatically.

**Ruby**

Drop a file in `./tools/`. ZeroMCP discovers it automatically.

**PHP**

Drop a file in `./tools/`. ZeroMCP discovers it automatically.

**Go**

Register tools in your main function. No file conventions, no code generation.

**Rust**

Register tools in your main function. No file conventions, no code generation.

**Kotlin**

Register tools in your main function. No file conventions, no code generation.

**Java**

Register tools in your main function. No file conventions, no code generation.

**C#**

Register tools in your main function. No file conventions, no code generation.

**Swift**

Register tools in your main function. No file conventions, no code generation.

**Node.js**

```
mkdir tools
cat > tools/hello.js << 'EOF'
export default {
  description: "Say hello to someone",
  input: { name: "string" },
  execute: async ({ name }) => `Hello, ${name}!`
}
EOF
```

**Python**

```
mkdir tools
cat > tools/hello.py << 'EOF'
tool = {
    "description": "Say hello to someone",
    "input": {
        "name": "string"
    },
}

async def execute(args, ctx):
    return f"Hello, {args['name']}!"
EOF
```

**Go**

```
package main

import (
    "fmt"
    "github.com/antidrift-dev/zeromcp-go"
)

func main() {
    s := zeromcp.NewServer()

    s.Tool("hello", zeromcp.Tool{
        Description: "Say hello to someone",
        Input: zeromcp.Input{
            "name": "string",
        },
        Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
            return fmt.Sprintf("Hello, %s!", args["name"]), nil
        },
    })

    s.ServeStdio()
}
```

**Rust**

```
use zeromcp::{Server, Tool, Input, Permissions, Ctx};
use serde_json::Value;

#[tokio::main]
async fn main() {
    let mut server = Server::new();

    server.tool("hello", Tool {
        description: "Say hello to someone".to_string(),
        input: Input::new()
            .required_desc("name", "string", "Who to greet"),
        permissions: Permissions::default(),
        execute: Box::new(|args: Value, _ctx: Ctx| {
            Box::pin(async move {
                let name = args["name"]
                    .as_str()
                    .unwrap_or("world");
                Ok(Value::String(
                    format!("Hello, {name}!")
                ))
            })
        }),
    });

    server.serve_stdio().await;
}
```

**Kotlin**

```
import dev.antidrift.zeromcp.server

fun main() {
    val server = server()

    server.tool("hello") {
        description = "Say hello to someone"
        input {
            "name" to "string"
        }
        execute { args, _ ->
            "Hello, ${args.getString("name")}!"
        }
    }

    server.serveStdio()
}
```

**Java**

```
import dev.antidrift.zeromcp.*;

public class Main {
    public static void main(String[] args) {
        var server = new Server();

        server.tool("hello", Tool.builder()
            .description("Say hello to someone")
            .input(Input.required(
                "name",
                "string",
                "The person's name"
            ))
            .execute((a, ctx) ->
                "Hello, " + a.get("name") + "!"
            )
            .build());

        server.serveStdio();
    }
}
```

**C#**

```
using ZeroMcp;

var server = new Server();

server.Tool("hello", new ToolDefinition {
    Description = "Say hello to someone",
    Input = new Dictionary<string, InputField> {
        ["name"] = new InputField(SimpleType.String)
    },
    Execute = async (args, ctx) => {
        var name = args["name"].GetString() ?? "world";
        return $"Hello, {name}!";
    }
});

await server.ServeStdio();
```

**Swift**

```
import ZeroMcp

let server = Server()

server.tool("hello",
    description: "Say hello to someone",
    input: [
        "name": .simple(.string)
    ]
) { args, ctx in
    "Hello, \(args["name"] as? String ?? "world")!"
}

await server.serve()
```

**Ruby**

```
mkdir tools
cat > tools/hello.rb << 'EOF'
tool description: "Say hello to someone",
     input: {
       name: "string"
     }

execute do |args, ctx|
  "Hello, #{args['name']}!"
end
EOF
```

**PHP**

```
mkdir tools
cat > tools/hello.php << 'EOF'
<?php
return [
    'description' => 'Say hello to someone',
    'input' => [
        'name' => 'string'
    ],
    'execute' => function ($args, $ctx) {
        return "Hello, {$args['name']}!";
    },
];
EOF
```

**Node.js**

That's it. No JSON Schema, no Zod, no server class. A file with `description`, `input`, and `execute`.

**Python**

That's it. A `tool` dict and an `execute` function. No decorators, no classes, no framework.

**Go**

No code generation, no reflection. Just a struct and a function.

**Rust**

Type-safe inputs, async execution, zero-cost abstractions. Standard Rust.

**Kotlin**

The DSL keeps tool definitions readable. Description, input, execute — that's the whole API.

**Java**

Builder, description, input, execute. That's the whole API.

**C#**

A `ToolDefinition` with description, input, and execute. That's the whole API.

**Swift**

Description, input, execute. That's it.

**Ruby**

That's it. A DSL with `tool` and `execute`. No classes, no gems, no boilerplate.

**PHP**

That's it. Return an array with `description`, `input`, and `execute`. No framework, no classes, no Composer dependencies.

## Serve

**Node.js**

```
zeromcp serve
```

**Python**

```
python3 -m zeromcp serve ./tools
```

**Go**

```
go build -o my-server .
./my-server
```

**Rust**

```
cargo build --release
./target/release/my-server
```

**Kotlin**

```
./gradlew run
```

**Java**

```
mvn package
java -jar target/my-server.jar
```

**C#**

```
dotnet run --project MyMcpServer
```

**Swift**

```
swift build
swift run
```

**Ruby**

```
zeromcp serve ./tools
```

**PHP**

```
php zeromcp.php serve ./tools
```

**Node.js**

ZeroMCP scans the `tools/` directory, finds your files, and serves them over stdio. Any MCP client can now call your tools.

**Python**

ZeroMCP scans the `tools/` directory, finds your files, and serves them over stdio. Any MCP client can now call your tools.

**Ruby**

ZeroMCP scans the `tools/` directory, finds your files, and serves them over stdio. Any MCP client can now call your tools.

**PHP**

ZeroMCP scans the `tools/` directory, finds your files, and serves them over stdio. Any MCP client can now call your tools.

**Go**

You get a single binary. Ship it anywhere. Serves over stdio so any MCP client can connect.

**Rust**

You get a single binary. Ship it anywhere. Serves over stdio so any MCP client can connect.

**Kotlin**

You get a single binary. Ship it anywhere. Serves over stdio so any MCP client can connect.

**Java**

You get a single binary. Ship it anywhere. Serves over stdio so any MCP client can connect.

**C#**

You get a single binary. Ship it anywhere. Serves over stdio so any MCP client can connect.

**Swift**

You get a single binary. Ship it anywhere. Serves over stdio so any MCP client can connect.

## Serve over HTTP

For production, serve over HTTP. ZeroMCP gives you a handler function — plug it into your framework.

**Node.js**

```
// Express
import express from 'express';
import { createHandler } from '@antidrift/zeromcp';

const app = express();
app.post('/mcp', createHandler('./tools'));
app.listen(3000);
```

Also works with **Fastify**, **Hono**, and **bare http**. [See framework benchmarks.](https://github.com/antidrift-dev/zeromcp-benchmarks/blob/main/writeups/express-vs-fastify-vs-hono.md)

**Python**

```
# Starlette / FastAPI
from starlette.applications import Starlette
from starlette.routing import Route
from zeromcp import create_handler

app = Starlette(routes=[
    Route('/mcp', create_handler('./tools'), methods=['POST'])
])
```

Also works with **FastAPI** and **Flask**.

**Go**

```
// Chi
r := chi.NewRouter()
r.Post("/mcp", server.HandleRequest())
http.ListenAndServe(":3000", r)
```

Also works with **net/http** and **Gin**.

**Rust**

```
// Actix
HttpServer::new(move || {
    App::new()
        .route("/mcp", web::post(server.handle_request()))
})
.bind("0.0.0.0:3000")?
.run().await
```

Also works with **Axum**.

**Java**

```
// Javalin
var app = Javalin.create();
app.post("/mcp", server::handleRequest);
app.start(3000);
```

**Kotlin**

```
// Ktor
embeddedServer(Netty, port = 3000) {
    routing {
        post("/mcp") { server.handleRequest(call) }
    }
}.start(wait = true)
```

**C#**

```
// ASP.NET Minimal API
var app = WebApplication.Create();
app.MapPost("/mcp", server.HandleRequest);
app.Run();
```

**Swift**

```
// Vapor
let app = Application()
app.post("mcp") { req in
    try await server.handleRequest(req)
}
try await app.run()
```

**Ruby**

```
# Rack + Puma
# config.ru
require 'zeromcp'

handler = ZeroMcp.create_handler('./tools')
run handler
```

Also works with **Sinatra**.

**PHP**

```
// Slim
\$app = Slim\Factory\AppFactory::create();
\$app->post('/mcp', \$server->handleRequest());
\$app->run();
```

## Connect to Claude Code

Add to your Claude Code MCP config:

**Node.js**

```
{
  "mcpServers": {
    "zeromcp": {
      "command": "zeromcp",
      "args": ["serve"]
    }
  }
}
```

**Python**

```
{
  "mcpServers": {
    "zeromcp": {
      "command": "python3",
      "args": ["-m", "zeromcp", "serve", "./tools"]
    }
  }
}
```

**Go**

```
{
  "mcpServers": {
    "zeromcp": {
      "command": "./my-server"
    }
  }
}
```

**Rust**

```
{
  "mcpServers": {
    "zeromcp": {
      "command": "./target/release/my-server"
    }
  }
}
```

**Kotlin**

```
{
  "mcpServers": {
    "zeromcp": {
      "command": "./gradlew",
      "args": ["run", "-q"]
    }
  }
}
```

**Java**

```
{
  "mcpServers": {
    "zeromcp": {
      "command": "java",
      "args": ["-jar", "target/my-server.jar"]
    }
  }
}
```

**C#**

```
{
  "mcpServers": {
    "zeromcp": {
      "command": "dotnet",
      "args": ["run", "--project", "MyMcpServer"]
    }
  }
}
```

**Swift**

```
{
  "mcpServers": {
    "zeromcp": {
      "command": "swift",
      "args": ["run", "--package-path", "./MyMcpServer"]
    }
  }
}
```

**Ruby**

```
{
  "mcpServers": {
    "zeromcp": {
      "command": "zeromcp",
      "args": ["serve", "./tools"]
    }
  }
}
```

**PHP**

```
{
  "mcpServers": {
    "zeromcp": {
      "command": "php",
      "args": ["zeromcp.php", "serve", "./tools"]
    }
  }
}
```

## A real tool

Here's a tool that lists Stripe customers with credential injection and sandboxed fetch:

**Node.js**

```
// tools/stripe/list_customers.js
export default {
  description: "List Stripe customers",

  permissions: {
    network: ["api.stripe.com"]
  },

  input: {
    limit: {
      type: 'number',
      optional: true,
      description: "Max results"
    }
  },

  execute: async ({ limit = 10 }, ctx) => {
    const res = await ctx.fetch(
      `https://api.stripe.com/v1/customers?limit=${limit}`,
      {
        headers: {
          'Authorization': `Bearer ${ctx.credentials.apiKey}`
        }
      }
    );
    return (await res.json()).data;
  },
}
```

**Python**

```
# tools/stripe/list_customers.py
tool = {
    "description": "List Stripe customers",

    "permissions": {
        "network": ["api.stripe.com"]
    },

    "input": {
        "limit": {
            "type": "number",
            "optional": True,
            "description": "Max results"
        }
    },
}

async def execute(args, ctx):
    limit = args.get("limit", 10)
    res = await ctx.fetch(
        f"https://api.stripe.com/v1/customers?limit={limit}",
        headers={
            "Authorization": f"Bearer {ctx.credentials['apiKey']}"
        }
    )
    data = await res.json()
    return data["data"]
```

**Go**

```
s.Tool("stripe_list_customers", zeromcp.Tool{
    Description: "List Stripe customers",

    Permissions: zeromcp.Permissions{
        Network: []string{"api.stripe.com"},
    },

    Input: zeromcp.Input{
        "limit": zeromcp.Field{
            Type:        "number",
            Optional:    true,
            Description: "Max results",
        },
    },

    Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
        limit := 10
        if v, ok := args["limit"].(float64); ok {
            limit = int(v)
        }

        url := fmt.Sprintf(
            "https://api.stripe.com/v1/customers?limit=%d",
            limit,
        )
        res, err := ctx.Fetch(url, zeromcp.FetchOpts{
            Headers: map[string]string{
                "Authorization": "Bearer " + ctx.Credentials["apiKey"],
            },
        })
        if err != nil {
            return nil, err
        }

        return res.JSON()
    },
})
```

**Rust**

```
server.tool("stripe_list_customers", Tool {
    description: "List Stripe customers".to_string(),

    input: Input::new()
        .optional_desc("limit", "number", "Max results"),

    permissions: Permissions {
        network: vec!["api.stripe.com".to_string()],
        ..Default::default()
    },

    execute: Box::new(|args: Value, ctx: Ctx| {
        Box::pin(async move {
            let limit = args["limit"]
                .as_u64()
                .unwrap_or(10);

            let url = format!(
                "https://api.stripe.com/v1/customers?limit={limit}"
            );

            let res = ctx.fetch(&url, FetchOpts {
                headers: vec![(
                    "Authorization".to_string(),
                    format!(
                        "Bearer {}",
                        ctx.credentials["apiKey"]
                    ),
                )],
                ..Default::default()
            }).await?;

            res.json().await
        })
    }),
});
```

**Kotlin**

```
server.tool("stripe_list_customers") {
    description = "List Stripe customers"

    permissions {
        network("api.stripe.com")
    }

    input {
        "limit" to field {
            type = "number"
            optional = true
            description = "Max results"
        }
    }

    execute { args, ctx ->
        val limit = args.getInt("limit") ?: 10

        val res = ctx.fetch(
            "https://api.stripe.com/v1/customers?limit=${limit}",
            headers = mapOf(
                "Authorization" to "Bearer ${ctx.credentials["apiKey"]}"
            )
        )

        res.json()
    }
}
```

**Java**

```
server.tool("stripe_list_customers", Tool.builder()
    .description("List Stripe customers")

    .permissions(Permissions.builder()
        .network("api.stripe.com")
        .build())

    .input(Input.optional(
        "limit",
        "number",
        "Max results"
    ))

    .execute((a, ctx) -> {
        var limit = a.getOrDefault("limit", 10);

        var res = ctx.fetch(
            "https://api.stripe.com/v1/customers?limit=" + limit,
            FetchOpts.builder()
                .header(
                    "Authorization",
                    "Bearer " + ctx.credentials().get("apiKey")
                )
                .build()
        );

        return res.json();
    })

    .build());
```

**C#**

```
server.Tool("stripe_list_customers", new ToolDefinition {
    Description = "List Stripe customers",

    Permissions = new Permissions {
        Network = new[] { "api.stripe.com" }
    },

    Input = new Dictionary<string, InputField> {
        ["limit"] = new InputField(SimpleType.Number) {
            Optional = true,
            Description = "Max results"
        }
    },

    Execute = async (args, ctx) => {
        var limit = args.TryGetValue("limit", out var v)
            ? v.GetInt32()
            : 10;

        var res = await ctx.Fetch(
            $"https://api.stripe.com/v1/customers?limit={limit}",
            new FetchOptions {
                Headers = new Dictionary<string, string> {
                    ["Authorization"] =
                        $"Bearer {ctx.Credentials["apiKey"]}"
                }
            }
        );

        return await res.Json();
    }
});
```

**Swift**

```
server.tool("stripe_list_customers",
    description: "List Stripe customers",
    permissions: Permissions(
        network: ["api.stripe.com"]
    ),
    input: [
        "limit": .field(
            type: .number,
            optional: true,
            description: "Max results"
        )
    ]
) { args, ctx in
    let limit = args["limit"] as? Int ?? 10

    let res = try await ctx.fetch(
        "https://api.stripe.com/v1/customers?limit=\(limit)",
        headers: [
            "Authorization":
                "Bearer \(ctx.credentials["apiKey"]!)"
        ]
    )

    return try await res.json()
}
```

**Ruby**

```
# tools/stripe/list_customers.rb
tool description: "List Stripe customers",
     permissions: {
       network: ["api.stripe.com"]
     },
     input: {
       limit: {
         type: "number",
         optional: true,
         description: "Max results"
       }
     }

execute do |args, ctx|
  limit = args.fetch("limit", 10)

  res = ctx.fetch(
    "https://api.stripe.com/v1/customers?limit=#{limit}",
    headers: {
      "Authorization" => "Bearer #{ctx.credentials['apiKey']}"
    }
  )

  res.json
end
```

**PHP**

```
<?php
// tools/stripe/list_customers.php
return [
    'description' => 'List Stripe customers',

    'permissions' => [
        'network' => ['api.stripe.com']
    ],

    'input' => [
        'limit' => [
            'type' => 'number',
            'optional' => true,
            'description' => 'Max results'
        ]
    ],

    'execute' => function ($args, $ctx) {
        $limit = $args['limit'] ?? 10;

        $res = $ctx->fetch(
            "https://api.stripe.com/v1/customers?limit={$limit}",
            [
                'headers' => [
                    'Authorization' =>
                        "Bearer {$ctx->credentials['apiKey']}"
                ]
            ]
        );

        return $res->json();
    },
];
```

The tool declares that it only needs network access to `api.stripe.com`. The runtime enforces this. Undeclared domains are blocked. Credentials come from the context object, mapped in your config file:

**Node.js**

```
// zeromcp.config.json
{
  "credentials": {
    "stripe": { "env": "STRIPE_SECRET_KEY" }
  }
}
```

**Python**

```
# zeromcp.config.json
{
  "credentials": {
    "stripe": {
        "env": "STRIPE_SECRET_KEY"
    }
  }
}
```

**Go**

```
// zeromcp.config.json
{
  "credentials": {
    "stripe": {
        "env": "STRIPE_SECRET_KEY"
    }
  }
}
```

**Rust**

```
// zeromcp.config.json
{
  "credentials": {
    "stripe": {
        "env": "STRIPE_SECRET_KEY"
    }
  }
}
```

**Kotlin**

```
// zeromcp.config.json
{
  "credentials": {
    "stripe": {
        "env": "STRIPE_SECRET_KEY"
    }
  }
}
```

**Java**

```
// zeromcp.config.json
{
  "credentials": {
    "stripe": {
        "env": "STRIPE_SECRET_KEY"
    }
  }
}
```

**C#**

```
// zeromcp.config.json
{
  "credentials": {
    "stripe": {
        "env": "STRIPE_SECRET_KEY"
    }
  }
}
```

**Swift**

```
// zeromcp.config.json
{
  "credentials": {
    "stripe": {
        "env": "STRIPE_SECRET_KEY"
    }
  }
}
```

**Ruby**

```
# zeromcp.config.json
{
  "credentials": {
    "stripe": {
        "env": "STRIPE_SECRET_KEY"
    }
  }
}
```

**PHP**

```
// zeromcp.config.json
{
  "credentials": {
    "stripe": {
        "env": "STRIPE_SECRET_KEY"
    }
  }
}
```

## Next steps

-   [Tool Authoring Guide](https://github.com/antidrift-dev/zeromcp/blob/main/docs/guides/tool-authoring.md): schema reference, permissions, ctx API
-   [Configuration](https://github.com/antidrift-dev/zeromcp/blob/main/docs/guides/configuration.md): full config file reference
-   [Composability](https://github.com/antidrift-dev/zeromcp/blob/main/docs/guides/composability.md): connect remote MCP servers
-   [Security](https://github.com/antidrift-dev/zeromcp/blob/main/docs/guides/security.md): permission model, sandbox, audit CLI
