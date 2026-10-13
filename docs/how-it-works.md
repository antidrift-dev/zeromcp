# How It Works

Drop a file. ZeroMCP scans it. It's an MCP tool. Three steps, zero config.

## 1\. Drop a file

Create a file in your `tools/` directory. Each file is one tool. The filename becomes the tool name.

```javascript
// tools/hello.js
export default {
  description: "Say hello to someone",
  input: {
    name: 'string',
  },
  execute: async ({ name }) => {
    return `Hello, ${name}!`;
  },
};
```

That's a complete MCP tool. No imports. No server class. No schema library.

Subdirectories become namespaces. `tools/stripe/list.js` becomes the tool `stripe_list`. Credentials are scoped per directory — Stripe tools get Stripe credentials, GitHub tools get GitHub credentials.

## 2\. ZeroMCP scans it

When you run `zeromcp serve`, ZeroMCP:

-   **Scans** the tools directory recursively
-   **Namespaces** tools by folder structure (`stripe/list.js` → `stripe_list`)
-   **Injects credentials** per directory from your config
-   **Enforces permissions** — network allowlists, filesystem controls, exec prevention
-   **Validates inputs** — generates JSON Schema from your shorthand types

If `autoload_tools` is enabled, ZeroMCP watches for file changes and hot-reloads without restarting.

## 3\. Serve over MCP

ZeroMCP speaks the MCP protocol (JSON-RPC 2.0). Connect any MCP client.

### stdio (default)

Works out of the box with Claude Code, Cursor, and any MCP client that uses stdio transport:

```bash
zeromcp serve ./tools
```

Output goes to stderr. stdout is reserved for MCP JSON-RPC.

### Streamable HTTP

ZeroMCP supports streamable HTTP by default. Embed the handler in any HTTP framework:

```javascript
import { createHandler } from 'zeromcp/handler';

const handler = await createHandler('./tools');

// Express, Fastify, Hono, Cloudflare Workers, Lambda — anything
app.post('/mcp', async (req, res) => res.json(await handler(req.body)));
```

No proxy. No sidecar. The handler runs in your process, behind your router.

### Both at once

Run stdio and HTTP from the same config:

```json
{
  "tools": "./tools",
  "transport": [
    { "type": "stdio" },
    { "type": "http", "port": 4242 }
  ]
}
```

## What happens under the hood

When an MCP client sends a `tools/call` request:

1.  **Input validation** — ZeroMCP checks the arguments against the tool's declared input schema
2.  **Credential injection** — The tool receives `ctx.credentials` scoped to its directory
3.  **Sandbox enforcement** — `ctx.fetch` only reaches declared domains. Undeclared calls are blocked.
4.  **Execution** — The tool's `execute` function runs with a 30-second default timeout
5.  **Response** — The return value is wrapped in MCP's content format and sent back

The entire pipeline handles `initialize`, `tools/list`, `tools/call`, and `ping`. That's the full MCP protocol surface for tools.

## Composing remote servers

ZeroMCP can also proxy tools from other MCP servers. Add them to your config:

```json
{
  "tools": "./tools",
  "remote": [
    { "name": "github", "url": "http://localhost:3001/mcp" },
    { "name": "jira", "url": "http://localhost:3002/mcp" }
  ]
}
```

Remote tools are auto-namespaced: `github.create_issue`, `jira.list_tickets`. Local tools override remote tools with the same name. One process, one stdio connection, one flat tool list for your client.

## 10 languages, same architecture

This same architecture runs in Node.js, Python, Go, Rust, Java, Kotlin, Swift, C#, Ruby, and PHP. File-based tools for dynamic languages (Node, Python, Ruby, PHP). Code registration for compiled languages (Go, Rust, Java, Kotlin, Swift, C#). Same protocol, same sandbox, same config format.

See the [Getting Started guide](https://github.com/antidrift-dev/zeromcp/blob/main/docs/getting-started.md) for install commands and code examples in your language.
