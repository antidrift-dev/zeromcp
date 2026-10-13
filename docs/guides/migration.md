# Migration Guide

Already using MCP? Two ways to move to ZeroMCP. Compose first, rewrite later.

## Path 1: Compose (zero effort)

Keep your existing MCP servers running. Add them as remotes in ZeroMCP. Done in 30 seconds:

```json
// zeromcp.config.json
{
  "remote": [
    {
      "name": "github",
      "url": "http://localhost:3001/mcp"
    },
    {
      "name": "jira",
      "url": "http://localhost:3002/mcp"
    }
  ]
}
```

Your existing servers keep running. ZeroMCP proxies them into one process with auto-namespacing. Your MCP client connects to ZeroMCP instead of each server individually.

You can add local tools on top at any time. They merge with the remote tools into a single tool surface.

### Why start here

-   Zero rewriting. Your existing tools work as-is.
-   Immediate benefit. One process, one connection, auto-namespacing.
-   Incremental migration. Rewrite tools to local files one at a time.

## Path 2: Rewrite as native tools

For when you want to kill the old servers entirely. Extract each tool into a native ZeroMCP tool:

### Before: Official SDK

**Node.js**

```
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";

const server = new McpServer({
  name: "my-tools",
  version: "1.0.0"
});

server.tool(
  "list_customers",
  {
    limit: z.number().optional().describe("Max results")
  },
  async ({ limit }) => {
    const res = await fetch(
      `https://api.stripe.com/v1/customers?limit=${limit || 10}`,
      {
        headers: {
          Authorization: `Bearer ${process.env.STRIPE_KEY}`
        }
      }
    );
    const data = await res.json();
    return {
      content: [
        { type: "text", text: JSON.stringify(data) }
      ]
    };
  }
);

const transport = new StdioServerTransport();
await server.connect(transport);
```

**Python**

```
from mcp.server.fastmcp import FastMCP

mcp = FastMCP("my-tools")

@mcp.tool()
async def list_customers(limit: int = 10) -> str:
    import httpx
    async with httpx.AsyncClient() as client:
        res = await client.get(
            f"https://api.stripe.com/v1/customers?limit={limit}",
            headers={"Authorization": f"Bearer {os.environ['STRIPE_KEY']}"}
        )
    return res.text

mcp.run()
```

**Go**

```
s := mcp.NewServer("my-tools", "1.0.0")
s.AddTool(mcp.NewTool("list_customers",
    mcp.WithNumber("limit", mcp.Description("Max results")),
), func(ctx context.Context, req mcp.CallToolRequest) (*mcp.CallToolResult, error) {
    limit := 10
    if v, ok := req.Params.Arguments["limit"].(float64); ok {
        limit = int(v)
    }
    url := fmt.Sprintf("https://api.stripe.com/v1/customers?limit=%d", limit)
    r, _ := http.NewRequest("GET", url, nil)
    r.Header.Set("Authorization", "Bearer "+os.Getenv("STRIPE_KEY"))
    resp, err := http.DefaultClient.Do(r)
    if err != nil { return nil, err }
    defer resp.Body.Close()
    body, _ := io.ReadAll(resp.Body)
    return mcp.NewToolResultText(string(body)), nil
})
```

**Rust**

```
use rmcp::{Server, tool};

#[tool(description = "List Stripe customers")]
async fn list_customers(limit: Option<u32>) -> String {
    let limit = limit.unwrap_or(10);
    let client = reqwest::Client::new();
    let res = client.get(
        format!("https://api.stripe.com/v1/customers?limit={limit}"))
        .header("Authorization",
            format!("Bearer {}", std::env::var("STRIPE_KEY").unwrap()))
        .send().await.unwrap();
    res.text().await.unwrap()
}

Server::new("my-tools", "1.0.0").tool(list_customers).serve_stdio().await;
```

**Kotlin**

```
val server = Server(ServerOptions(
    name = "my-tools", version = "1.0.0"))
server.addTool("list_customers", "List Stripe customers",
    inputSchema = mapOf("limit" to mapOf("type" to "number"))) { args ->
    val limit = (args["limit"] as? Number)?.toInt() ?: 10
    val url = "https://api.stripe.com/v1/customers?limit=$limit"
    val conn = URL(url).openConnection() as HttpURLConnection
    conn.setRequestProperty("Authorization", "Bearer " + System.getenv("STRIPE_KEY"))
    val body = conn.inputStream.bufferedReader().readText()
    CallToolResult(content = listOf(TextContent(body)))
}
server.connectStdio()
```

**Java**

```
var server = McpServer.sync("my-tools")
    .tool(new SyncToolSpecification(
        new Tool("list_customers", "List Stripe customers",
            new JsonSchemaObject(Map.of("limit", new JsonSchemaNumber()))),
        (exchange, args) -> {
            var limit = args.getOrDefault("limit", 10);
            var req = HttpRequest.newBuilder()
                .uri(URI.create("https://api.stripe.com/v1/customers?limit=" + limit))
                .header("Authorization", "Bearer " + System.getenv("STRIPE_KEY"))
                .build();
            var res = HttpClient.newHttpClient()
                .send(req, HttpResponse.BodyHandlers.ofString());
            return new CallToolResult(List.of(new TextContent(res.body())));
        }
    )).build();
server.connect(new StdioServerTransport());
```

**C#**

```
var server = new McpServerBuilder()
    .WithName("my-tools")
    .WithTool("list_customers", "List Stripe customers",
        new { limit = new { type = "number" } },
        async (args) => {
            var limit = args.TryGetValue("limit", out var v) ? v.GetInt32() : 10;
            var client = new HttpClient();
            client.DefaultRequestHeaders.Add("Authorization",
                $"Bearer {Environment.GetEnvironmentVariable("STRIPE_KEY")}");
            return await client.GetStringAsync(
                $"https://api.stripe.com/v1/customers?limit={limit}");
        })
    .Build();
await server.RunStdioAsync();
```

**Swift**

```
let server = MCPServer(name: "my-tools", version: "1.0.0")
server.registerTool("list_customers",
    description: "List Stripe customers",
    inputSchema: ["limit": .number]) { args in
    let limit = args["limit"] as? Int ?? 10
    var request = URLRequest(
        url: URL(string: "https://api.stripe.com/v1/customers?limit=\(limit)")!)
    request.setValue(
        "Bearer \(ProcessInfo.processInfo.environment["STRIPE_KEY"]!)",
        forHTTPHeaderField: "Authorization")
    let (data, _) = try await URLSession.shared.data(for: request)
    return .text(String(data: data, encoding: .utf8)!)
}
try await server.runStdio()
```

**Ruby**

```
require 'mcp'
require 'net/http'

server = MCP::Server.new(name: "my-tools", version: "1.0.0")
server.register_tool("list_customers",
  description: "List Stripe customers",
  input_schema: { limit: { type: "number" } }) do |args|
  limit = args['limit'] || 10
  uri = URI("https://api.stripe.com/v1/customers?limit=#{limit}")
  req = Net::HTTP::Get.new(uri)
  req['Authorization'] = "Bearer #{ENV['STRIPE_KEY']}"
  Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req).body }
end
server.run_stdio
```

**PHP**

```
use Mcp\Server\McpServer;

$server = new McpServer('my-tools', '1.0.0');
$server->registerTool('list_customers',
    'List Stripe customers',
    ['limit' => ['type' => 'number']],
    function($args) {
        $limit = $args['limit'] ?? 10;
        $ctx = stream_context_create(['http' => [
            'header' => "Authorization: Bearer " . getenv('STRIPE_KEY')
        ]]);
        return file_get_contents(
            "https://api.stripe.com/v1/customers?limit={$limit}",
            false, $ctx);
    });
$server->runStdio();
```

### After: ZeroMCP

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
      type: "number",
      optional: true,
      description: "Max results"
    }
  },

  execute: async ({ limit = 10 }, ctx) => {
    const res = await ctx.fetch(
      `https://api.stripe.com/v1/customers?limit=${limit}`,
      {
        headers: {
          Authorization: `Bearer ${ctx.credentials.apiKey}`
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

### What changes

| Before | After |
| --- | --- |
| Server class + transport setup | Just the tool |
| `z.number().optional()` | `{ type: "number", optional: true }` |
| `process.env.STRIPE_KEY` | `ctx.credentials.apiKey` |
| Global `fetch` | `ctx.fetch` (sandboxed) |
| Wrap in `{ content: [{ type: "text" }] }` | Return the data directly |
| 17 dependencies | 0 dependencies |

## Incremental approach

You don't have to migrate everything at once. Start with Path 1 (compose), then rewrite tools one at a time:

1.  Add existing servers as remotes
2.  Pick one tool to rewrite as a local file
3.  The local version automatically overrides the remote version (same name = local wins)
4.  Repeat until you've replaced all remote tools
5.  Shut down old servers
