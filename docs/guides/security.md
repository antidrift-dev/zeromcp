# Security

Security is the default, not an opt-in. Tools can't phone home. They can't access other tools' credentials. They can't touch the filesystem without declaring it.

## Permission declarations

Tools declare what they need. The runtime enforces it.

**Node.js**

```
export default {
  permissions: {
    network: ["api.stripe.com"],   // allowed domains
    fs: ["./data"],                 // filesystem paths
    exec: ["git"],                  // executables
  },
  execute: async (args, ctx) => {
    // ctx.fetch("https://api.stripe.com/...") → allowed
    // ctx.fetch("https://evil.com/...") → BLOCKED
  }
}
```

**Python**

```
tool = {
    "permissions": {
        "network": ["api.stripe.com"],   # allowed domains
        "fs": ["./data"],                 # filesystem paths
        "exec": ["git"],                  # executables
    },
}

async def execute(args, ctx):
    # ctx.fetch("https://api.stripe.com/...") → allowed
    # ctx.fetch("https://evil.com/...") → BLOCKED
    pass
```

**Go**

```
s.Tool("my_tool", zeromcp.Tool{
    Permissions: zeromcp.Permissions{
        Network: []string{"api.stripe.com"},   // allowed domains
        Fs:      []string{"./data"},             // filesystem paths
        Exec:    []string{"git"},                // executables
    },
    Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
        // ctx.Fetch("https://api.stripe.com/...") → allowed
        // ctx.Fetch("https://evil.com/...") → BLOCKED
        return nil, nil
    },
})
```

**Rust**

```
server.tool("my_tool", Tool {
    permissions: Permissions {
        network: vec!["api.stripe.com".to_string()], // allowed domains
        fs: vec!["./data".to_string()],               // filesystem paths
        exec: vec!["git".to_string()],                // executables
    },
    execute: Box::new(|args: Value, ctx: Ctx| {
        Box::pin(async move {
            // ctx.fetch("https://api.stripe.com/...") → allowed
            // ctx.fetch("https://evil.com/...") → BLOCKED
            Ok(Value::Null)
        })
    }),
    ..Default::default()
});
```

**Kotlin**

```
server.tool("my_tool") {
    permissions {
        network("api.stripe.com")   // allowed domains
        fs("./data")                 // filesystem paths
        exec("git")                  // executables
    }
    execute { args, ctx ->
        // ctx.fetch("https://api.stripe.com/...") → allowed
        // ctx.fetch("https://evil.com/...") → BLOCKED
    }
}
```

**Java**

```
server.tool("my_tool", Tool.builder()
    .permissions(Permissions.builder()
        .network("api.stripe.com")   // allowed domains
        .fs("./data")                 // filesystem paths
        .exec("git")                  // executables
        .build())
    .execute((args, ctx) -> {
        // ctx.fetch("https://api.stripe.com/...") → allowed
        // ctx.fetch("https://evil.com/...") → BLOCKED
        return null;
    })
    .build());
```

**C#**

```
server.Tool("my_tool", new ToolDefinition {
    Permissions = new Permissions {
        Network = new[] { "api.stripe.com" }, // allowed domains
        Fs = new[] { "./data" },               // filesystem paths
        Exec = new[] { "git" }                 // executables
    },
    Execute = async (args, ctx) => {
        // ctx.Fetch("https://api.stripe.com/...") → allowed
        // ctx.Fetch("https://evil.com/...") → BLOCKED
        return null;
    }
});
```

**Swift**

```
server.tool("my_tool",
    permissions: Permissions(
        network: ["api.stripe.com"],  // allowed domains
        fs: ["./data"],                // filesystem paths
        exec: ["git"]                  // executables
    )
) { args, ctx in
    // ctx.fetch("https://api.stripe.com/...") → allowed
    // ctx.fetch("https://evil.com/...") → BLOCKED
}
```

**Ruby**

```
tool permissions: {
       network: ["api.stripe.com"],   # allowed domains
       fs: ["./data"],                 # filesystem paths
       exec: ["git"]                   # executables
     }

execute do |args, ctx|
  # ctx.fetch("https://api.stripe.com/...") → allowed
  # ctx.fetch("https://evil.com/...") → BLOCKED
end
```

**PHP**

```
<?php
return [
    'permissions' => [
        'network' => ['api.stripe.com'], // allowed domains
        'fs' => ['./data'],               // filesystem paths
        'exec' => ['git'],                // executables
    ],
    'execute' => function ($args, $ctx) {
        // $ctx->fetch("https://api.stripe.com/...") → allowed
        // $ctx->fetch("https://evil.com/...") → BLOCKED
    },
];
```

Undeclared access is blocked at runtime. In development, set `"bypass_permissions": true` to get warnings instead of hard blocks.

## Sandboxed fetch

`ctx.fetch` is a drop-in replacement for your language's default HTTP client with domain allowlisting. Only domains declared in `permissions.network` are reachable. All calls are logged when `"logging": true`.

## Credential injection

Tools use `ctx.credentials`. They never touch raw environment variables. Credentials are mapped in your config:

**Node.js**

```
// zeromcp.config.json
{
  "credentials": {
    "stripe": {
      "env": "STRIPE_SECRET_KEY"
    },
    "google": {
      "file": "~/.config/google/creds.json"
    }
  }
}

// In your tool — credentials come from ctx
execute: async (args, ctx) => {
  ctx.credentials.apiKey  // mapped from STRIPE_SECRET_KEY
}
```

**Python**

```
# zeromcp.config.json
{
  "credentials": {
    "stripe": {
      "env": "STRIPE_SECRET_KEY"
    },
    "google": {
      "file": "~/.config/google/creds.json"
    }
  }
}

# In your tool — credentials come from ctx
async def execute(args, ctx):
    ctx.credentials["apiKey"]  # mapped from STRIPE_SECRET_KEY
```

**Go**

```
// zeromcp.config.json
{
  "credentials": {
    "stripe": {
      "env": "STRIPE_SECRET_KEY"
    },
    "google": {
      "file": "~/.config/google/creds.json"
    }
  }
}

// In your tool — credentials come from ctx
Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
    key := ctx.Credentials["apiKey"] // mapped from STRIPE_SECRET_KEY
    return nil, nil
}
```

**Rust**

```
// zeromcp.config.json
{
  "credentials": {
    "stripe": {
      "env": "STRIPE_SECRET_KEY"
    },
    "google": {
      "file": "~/.config/google/creds.json"
    }
  }
}

// In your tool — credentials come from ctx
let key = &ctx.credentials["apiKey"]; // mapped from STRIPE_SECRET_KEY
```

**Kotlin**

```
// zeromcp.config.json
{
  "credentials": {
    "stripe": {
      "env": "STRIPE_SECRET_KEY"
    },
    "google": {
      "file": "~/.config/google/creds.json"
    }
  }
}

// In your tool — credentials come from ctx
execute { args, ctx ->
    ctx.credentials["apiKey"]  // mapped from STRIPE_SECRET_KEY
}
```

**Java**

```
// zeromcp.config.json
{
  "credentials": {
    "stripe": {
      "env": "STRIPE_SECRET_KEY"
    },
    "google": {
      "file": "~/.config/google/creds.json"
    }
  }
}

// In your tool — credentials come from ctx
.execute((args, ctx) -> {
    var key = ctx.credentials().get("apiKey"); // mapped from STRIPE_SECRET_KEY
    return null;
})
```

**C#**

```
// zeromcp.config.json
{
  "credentials": {
    "stripe": {
      "env": "STRIPE_SECRET_KEY"
    },
    "google": {
      "file": "~/.config/google/creds.json"
    }
  }
}

// In your tool — credentials come from ctx
Execute = async (args, ctx) => {
    var key = ctx.Credentials["apiKey"]; // mapped from STRIPE_SECRET_KEY
    return null;
}
```

**Swift**

```
// zeromcp.config.json
{
  "credentials": {
    "stripe": {
      "env": "STRIPE_SECRET_KEY"
    },
    "google": {
      "file": "~/.config/google/creds.json"
    }
  }
}

// In your tool — credentials come from ctx
{ args, ctx in
    let key = ctx.credentials["apiKey"]! // mapped from STRIPE_SECRET_KEY
}
```

**Ruby**

```
# zeromcp.config.json
{
  "credentials": {
    "stripe": {
      "env": "STRIPE_SECRET_KEY"
    },
    "google": {
      "file": "~/.config/google/creds.json"
    }
  }
}

# In your tool — credentials come from ctx
execute do |args, ctx|
  ctx.credentials["apiKey"]  # mapped from STRIPE_SECRET_KEY
end
```

**PHP**

```
// zeromcp.config.json
{
  "credentials": {
    "stripe": {
      "env": "STRIPE_SECRET_KEY"
    },
    "google": {
      "file": "~/.config/google/creds.json"
    }
  }
}

// In your tool — credentials come from ctx
'execute' => function ($args, $ctx) {
    $key = $ctx->credentials['apiKey']; // mapped from STRIPE_SECRET_KEY
}
```

This means:

-   Tools in `tools/stripe/` get the Stripe key via `ctx.credentials`
-   Tools in `tools/github/` can't access Stripe credentials. Isolation is per-directory.
-   Credentials never appear in tool source code

## Audit CLI

`zeromcp audit` runs static analysis on tool files before they go live:

```bash
$ zeromcp audit ./tools
✓ stripe/list_customers.js — permissions declared, no raw env access
✗ github/issues.js — uses global fetch (should use ctx.fetch)
✗ utils/helper.js — accesses process.env directly
```

The audit CLI gates the community tool registry. Tools with violations can't be published.

## Community tool scanning

Every tool in the community registry is statically analyzed for:

-   Undeclared network access
-   Direct environment variable usage (should use `ctx.credentials`)
-   Unsandboxed HTTP calls (should use `ctx.fetch`)
-   Filesystem access without permission declarations
-   Credential hardcoding
