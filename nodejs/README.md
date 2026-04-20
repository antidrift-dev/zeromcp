# ZeroMCP &mdash; Node.js

Drop a `.js` file in a folder, get a sandboxed MCP server. Stdio out of the box.

## Getting started

```js
// tools/hello.js — this is a complete MCP server
export default {
  description: "Say hello to someone",
  input: { name: 'string' },
  execute: async ({ name }) => `Hello, ${name}!`,
};
```

```sh
npm run build
node bin/mcp.js serve ./tools
```

That's it. Stdio transport works immediately. No server class, no transport config, no schema library. Drop another `.js` file to add another tool. Delete a file to remove one. Hot reload picks up changes automatically.

## vs. the official SDK

The official `@modelcontextprotocol/sdk` requires you to instantiate a server, configure a transport, wire them together, define zod schemas, and wrap every return in `{ content: [{ type: "text", text }] }`. ZeroMCP handles all of that &mdash; you just write the tool.

In benchmarks, ZeroMCP Node.js handles 14,173 requests/second over stdio versus the official SDK's 8,832 — 1.6x faster with 23% less memory. Over HTTP, ZeroMCP serves 4,539 rps at 22-26 MB versus the official SDK's 2,610 rps at 154-174 MB. The official SDK routes HTTP through a stdio proxy; ZeroMCP runs native inside your framework.

The official SDK also has **no sandbox**. ZeroMCP enforces per-tool network allowlists, credential isolation, filesystem controls, and exec prevention at runtime.

## HTTP / Streamable HTTP

ZeroMCP exposes a `createHandler` function that works with any HTTP framework. You handle the transport, ZeroMCP handles the MCP protocol.

```js
import { createHandler } from 'zeromcp/handler';

const handler = await createHandler('./tools');
```

**Express:**

```js
import express from 'express';
const app = express();
app.use(express.json());
app.post('/mcp', async (req, res) => res.json(await handler(req.body)));
app.listen(3000);
```

**Fastify:**

```js
import Fastify from 'fastify';
const app = Fastify();
app.post('/mcp', async (req) => handler(req.body));
app.listen({ port: 3000 });
```

**Hono:**

```js
import { Hono } from 'hono';
import { serve } from '@hono/node-server';
const app = new Hono();
app.post('/mcp', async (c) => c.json(await handler(await c.req.json())));
serve({ fetch: app.fetch, port: 3000 });
```

**Cloudflare Workers:**

```js
export default {
  async fetch(request) {
    return Response.json(await handler(await request.json()));
  }
};
```

**AWS Lambda:**

```js
export const handle = async (event) => handler(JSON.parse(event.body));
```

The handler takes a JSON-RPC object and returns a JSON-RPC response. No opinions about HTTP framework, headers, or routing.

## Requirements

- Node.js 14+

## Defining tools

Create a `.js` or `.mjs` file that default-exports a tool object:

```js
// tools/add.js
export default {
  description: "Add two numbers together",
  input: { a: 'number', b: 'number' },
  execute: async ({ a, b }) => ({ sum: a + b }),
};
```

### Input types

Shorthand strings: `'string'`, `'number'`, `'boolean'`, `'object'`, `'array'`. Expanded to JSON Schema automatically.

### Returning values

Return a string or an object. ZeroMCP wraps it in the MCP content envelope for you.

## Sandbox

The Node.js implementation has full runtime sandboxing.

### Network allowlists

```js
export default {
  description: "Fetch from our API",
  input: { endpoint: 'string' },
  permissions: {
    network: ['api.example.com', '*.internal.dev'],
  },
  execute: async ({ endpoint }, ctx) => {
    const res = await ctx.fetch(`https://api.example.com/${endpoint}`);
    return res.body;
  },
};
```

Requests to unlisted domains are blocked and logged.

### Credential injection

Tools receive secrets via `ctx.credentials`, configured per namespace in `zeromcp.config.json`. Tools never read `process.env` directly.

### Filesystem and exec control

- `fs: 'read'` or `fs: 'write'` &mdash; unauthorized access blocked via proxy objects and static source auditing
- `exec: true` required to spawn subprocesses &mdash; denied by default

### Permission logging

```
[zeromcp] fetch_data → GET api.example.com
[zeromcp] fetch_data ✗ GET evil.com (not in allowlist)
```

## Directory structure

Tools are discovered recursively. Subdirectory names become namespace prefixes. `node_modules` directories are skipped automatically.

```
tools/
  hello.js          -> tool "hello"
  math/
    add.js          -> tool "math_add"
    multiply.js     -> tool "math_multiply"
```

## Programmatic API

```js
import { createHandler } from 'zeromcp/handler';  // HTTP handler
import { ToolScanner } from 'zeromcp/scanner';     // Tool discovery
import { toJsonSchema, validate } from 'zeromcp/schema'; // Schema utils
```

## Configuration

Optional `zeromcp.config.json`:

```json
{
  "tools": ["./tools"],
  "transport": [
    { "type": "stdio" },
    { "type": "http", "port": 4242, "auth": "env:TOKEN" }
  ],
  "autoload_tools": true,
  "logging": true,
  "bypass_permissions": false,
  "credentials": {
    "api": { "env": "API_KEY" }
  }
}
```

## Testing

```sh
npm test
```

Node.js passes all 10 conformance suites and survives 21/22 chaos monkey attacks.
