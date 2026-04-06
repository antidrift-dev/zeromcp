# ZeroMCP

Drop a tool file, get a sandboxed MCP server. Stdio out of the box, 10 languages, zero setup.

## Why ZeroMCP?

### Drop a tool and go

With the official MCP SDKs, you write a tool, then you write the server around it &mdash; instantiate a server class, pick a transport, wire them together, configure schemas. With ZeroMCP, you skip all of that.

**This is a complete MCP server:**

```js
// tools/hello.js
export default {
  description: "Say hello to someone",
  input: { name: 'string' },
  execute: async ({ name }) => `Hello, ${name}!`,
};
```

```sh
node bin/mcp.js serve ./tools
```

Stdio transport works immediately. No server class to instantiate, no transport to configure, no schema library to learn. Drop a file in the tools directory, run the command, connect a client.

Want another tool? Drop another file. Want to remove one? Delete it. Hot reload picks up changes automatically.

### Built-in sandbox

The official MCP SDKs give tools unrestricted access to the network, filesystem, environment variables, and child processes. ZeroMCP is the only MCP runtime that sandboxes tool execution:

- **Network allowlists** &mdash; tools declare which domains they can reach. Requests to anything else are blocked.
- **Credential isolation** &mdash; tools receive secrets through `ctx.credentials`, not `process.env`. A tool only sees the credentials it was given.
- **Filesystem controls** &mdash; tools must declare `fs: 'read'` or `fs: 'write'`. Unauthorized access is blocked.
- **Exec prevention** &mdash; subprocess spawning is denied by default.
- **Permission logging** &mdash; every permission decision is logged, so you can see exactly what your tools are doing.

```js
// tools/fetch_data.js
export default {
  description: "Fetch data from our API",
  input: { endpoint: 'string' },
  permissions: {
    network: ['api.example.com'],
  },
  execute: async ({ endpoint }, ctx) => {
    const res = await ctx.fetch(`https://api.example.com/${endpoint}`);
    return res.body;
  },
};
```

```
[zeromcp] fetch_data → GET api.example.com          (allowed)
[zeromcp] fetch_data ✗ GET evil.com (not in allowlist)  (denied)
```

### What's different

| | Official SDKs | ZeroMCP |
|---|---|---|
| Getting started | Instantiate server, configure transport, register tools | Drop a file, run the command |
| Adding a tool | Write code, register with server, restart | Drop a file in the directory |
| Stdio transport | Manual setup | Works out of the box |
| Network sandboxing | None | Per-tool domain allowlists |
| Credential isolation | None | Injected via `ctx.credentials` |
| Filesystem/exec control | None | Declared per tool, enforced at runtime |
| Cross-language conformance | Each SDK tested independently | 10 suites, 67 implementations, 0 failures |
| Performance | No built-in benchmarking | 1.1x to 740x faster, benchmarked against all 10 official SDKs |
| Chaos resilience | Not tested | 21-22/22 attacks survived across all 10 languages |

## Quick start

**Node.js** &mdash; `tools/hello.js`

```js
export default {
  description: "Say hello to someone",
  input: { name: 'string' },
  execute: async ({ name }) => `Hello, ${name}!`,
};
```

```sh
cd nodejs && npm run build
node bin/mcp.js serve ./examples/tools
```

**Python** &mdash; `tools/hello.py`

```python
tool = {
    "description": "Say hello to someone",
    "input": {"name": "string"},
}

async def execute(args, ctx):
    return f"Hello, {args['name']}!"
```

```sh
cd python
python3 -m zeromcp serve ./examples/tools
```

**Go**

```go
s := zeromcp.NewServer()
s.Tool("hello", zeromcp.Tool{
    Description: "Say hello to someone",
    Input:       zeromcp.Input{"name": "string"},
    Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
        return fmt.Sprintf("Hello, %s!", args["name"]), nil
    },
})
s.ServeStdio()
```

**Rust** / **Java** / **Kotlin** / **Swift** / **C#** / **Ruby** / **PHP** &mdash; see language-specific READMEs below.

## Languages

| Language | Directory | Runtime | Tool model | Performance |
|----------|-----------|---------|------------|-------------|
| [Node.js](nodejs/) | `nodejs/` | Node 14+ (also Bun, Deno) | Drop a `.js` file, it's a tool | 1.6x faster, 23% less memory |
| [Python](python/) | `python/` | Python 3.9+ | Drop a `.py` file, it's a tool | 12.7x faster, 59% less memory |
| [Ruby](ruby/) | `ruby/` | Ruby 3.0+ | Drop a `.rb` file, it's a tool | 1.2x faster, 50% less memory |
| [PHP](php/) | `php/` | PHP 8.1+ | Drop a `.php` file, it's a tool | 740x faster |
| [Go](go/) | `go/` | Go 1.22+ | Register tools in code | 12.8x faster |
| [Rust](rust/) | `rust/` | Rust 1.78+ | Register tools in code | 1.1x faster, 50% less memory |
| [Java](java/) | `java/` | Java 17+ | Register tools in code (builder API) | 2.5x faster, 53% less memory |
| [Kotlin](kotlin/) | `kotlin/` | Kotlin 2.0 / JVM 21 | Register tools in code (DSL) | 8.4x faster |
| [Swift](swift/) | `swift/` | Swift 5.9+ / macOS 13+ | Register tools in code | 99x faster |
| [C#](csharp/) | `csharp/` | .NET 8 | Register tools in code | 1.4x faster, 34% less memory |

## Sandbox

ZeroMCP's sandbox is a runtime permission layer that the official MCP SDKs don't have.

### Per-tool permissions

```js
export default {
  description: "Search our CRM",
  input: { query: 'string' },
  permissions: {
    network: ['crm.example.com'],   // only this domain
    fs: 'read',                      // read-only filesystem
    exec: false,                     // no subprocess spawning (default)
  },
  execute: async ({ query }, ctx) => {
    const res = await ctx.fetch(`https://crm.example.com/search?q=${query}`);
    return res.body;
  },
};
```

### Credential injection

Credentials are configured once and injected per namespace. Tools never access env vars directly:

```json
{
  "credentials": {
    "stripe": { "env": "STRIPE_SECRET_KEY" },
    "internal": { "file": "~/.config/internal-api.json" }
  }
}
```

Tools in the `stripe/` directory receive `ctx.credentials` with the Stripe key. Tools in other directories don't see it.

### Bypass mode

For local development, `"bypass_permissions": true` allows all access with warning logs:

```
[zeromcp] ⚠ fetch_data → GET unknown-host.com (not in allowlist — bypassed)
```

## Performance

Benchmarked against every official MCP SDK across all 10 languages.

| Language | vs. Official SDK | HTTP throughput | Memory |
|---|---|---|---|
| Node.js | 1.6x faster | 4,539 rps | 22-26 MB |
| Python | 12.7x faster | 2,623 rps | 27 MB |
| Go | 12.8x faster | 4,024 rps | 21-23 MB |
| Rust | 1.1x faster | 5,111 rps | 3-4 MB |
| Java | 2.5x faster | 3,791 rps | 184-207 MB |
| Kotlin | 8.4x faster | 2,848 rps | 188-194 MB |
| Ruby | 1.2x faster | 3,217 rps | 26 MB |
| PHP | 740x faster | 1,561 rps | 11-33 MB |
| Swift | 99x faster | 1,730 rps | 49-96 MB |
| C# | 1.4x faster | 4,421 rps | 126-314 MB |

The "vs. Official SDK" column is stdio throughput (1,000 requests). ZeroMCP runs native inside your HTTP framework &mdash; no proxy, no subprocess. The official SDKs route HTTP through a stdio proxy, serializing every request through a single child process.

Over sustained HTTP load (5 minutes), ZeroMCP is 1.4x to 92x faster than official SDKs across all 10 languages. The official Rust SDK leaks to 2.4 GB in 5 minutes; ZeroMCP Rust uses 3 MB.

A 22-attack chaos monkey suite tests resilience against malformed input, giant payloads, concurrent floods, and protocol abuse. ZeroMCP survives 21-22/22 attacks across all 10 languages. Official SDKs survive 19-20/21.

## Configuration

All implementations support an optional `zeromcp.config.json`:

```json
{
  "tools": ["./tools"],
  "transport": [
    { "type": "stdio" },
    { "type": "http", "port": 4242, "auth": "env:TOKEN" }
  ],
  "logging": true,
  "bypass_permissions": false,
  "credentials": {
    "api": { "env": "API_KEY" }
  },
  "remote": [
    { "name": "other-server", "url": "http://localhost:5000", "auth": "env:TOKEN" }
  ]
}
```

## HTTP / Streamable HTTP

ZeroMCP doesn't own the HTTP layer — you bring your own framework. ZeroMCP gives you a handler function that takes JSON-RPC in and returns JSON-RPC out.

```js
import { createHandler } from 'zeromcp/handler';

const handler = await createHandler('./tools');

// Express, Fastify, Hono, Cloudflare Workers, Lambda — anything
app.post('/mcp', async (req, res) => res.json(await handler(req.body)));
```

This is compatible with MCP's Streamable HTTP transport. The handler processes `initialize`, `tools/list`, `tools/call`, and `ping`. Your framework handles the HTTP.

See [Node.js README](nodejs/) for examples with Express, Fastify, Hono, Cloudflare Workers, and Lambda.

## Features

- **Drop and go** &mdash; stdio out of the box, no server setup, no transport config
- **Framework-agnostic HTTP** &mdash; `createHandler` works with any HTTP framework or serverless runtime
- **Built-in sandbox** &mdash; network allowlists, filesystem controls, exec prevention, credential isolation
- **File-based tools** &mdash; add a tool by creating a file, remove it by deleting (Node.js, Python, Ruby, PHP)
- **Hot reload** &mdash; tool changes detected automatically
- **Input validation** &mdash; JSON Schema generated from shorthand types (`string`, `number`, `boolean`, `object`, `array`)
- **Execute timeout** &mdash; default 30s, configurable per tool
- **Remote federation** &mdash; proxy tools from other MCP servers over HTTP

## Testing

A cross-language conformance suite validates all implementations across 10 suites and 67 test implementations covering protocol compliance, sandbox enforcement, timeout handling, credential isolation, namespace resolution, and HTTP transport. 0 failures, 0 skipped. Additionally, a 22-attack chaos monkey suite tests resilience against malformed input, giant payloads, concurrent floods, and protocol abuse.

### Run with Docker (all languages)

```sh
docker build -t zeromcp .
docker run zeromcp
```

### Run locally (single language)

```sh
node tests/conformance/run-all.js
```

Languages whose binaries aren't built locally are skipped automatically.

## Project structure

```
zeromcp/
  nodejs/       TypeScript/Node.js implementation
  python/       Python implementation
  go/           Go implementation
  rust/         Rust implementation
  java/         Java implementation (Maven)
  kotlin/       Kotlin implementation (Gradle)
  swift/        Swift implementation (SPM)
  csharp/       C# implementation (.NET 8)
  ruby/         Ruby implementation (gem)
  php/          PHP implementation
  tests/        Cross-language conformance suite
  Dockerfile    Multi-language build & test container
```

## License

MIT
