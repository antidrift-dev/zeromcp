# Configuration

ZeroMCP works with zero config. When you need more, everything goes in `zeromcp.config.json`.

## Config file

Create `zeromcp.config.json` in your project root. All fields are optional:

```json
{
  "tools": "./tools",
  "transport": {
    "type": "stdio"
  },
  "credentials": {},
  "remote": [],
  "logging": false,
  "bypass_permissions": false,
  "autoload_tools": false,
  "namespacing": {},
  "separator": "_"
}
```

## Reference

| Key | Type | Default | Description |
| --- | --- | --- | --- |
| `tools` | `string | Array` | `"./tools"` | Tool source directory or array of `{ path, prefix }` |
| `transport` | `object | Array` | `{ type: "stdio" }` | Transport config: `stdio`, `http`, or both |
| `credentials` | `object` | `{}` | Per-directory credential mapping |
| `remote` | `Array` | `[]` | Remote MCP servers to compose |
| `logging` | `boolean` | `false` | Log all sandboxed network calls |
| `bypass_permissions` | `boolean` | `false` | Warn instead of block on permission violations |
| `autoload_tools` | `boolean` | `false` | Hot reload tool files on change |
| `namespacing` | `object` | `{}` | Override tool name prefixes per directory |
| `separator` | `string` | `"_"` | Separator between namespace and tool name |

## Tools

Point to one or multiple tool directories:

```json
// Single directory
{
  "tools": "./tools"
}

// Multiple directories with prefixes
{
  "tools": [
    {
      "path": "./internal-tools",
      "prefix": "internal"
    },
    {
      "path": "./shared-tools"
    }
  ]
}
```

## Transport

stdio for local MCP clients. Built-in HTTP for development and testing. Library export for production.

```json
// stdio only (default)
{
  "transport": {
    "type": "stdio"
  }
}

// HTTP for dev/testing
{
  "transport": {
    "type": "http",
    "port": 4242,
    "auth": "env:MCP_TOKEN"
  }
}

// Both
{
  "transport": [
    { "type": "stdio" },
    { "type": "http", "port": 4242 }
  ]
}
```

The built-in HTTP server is a convenience for development. In production, use the [library export](https://github.com/antidrift-dev/zeromcp/blob/main/docs/guides/tool-authoring.md) to serve through your own infrastructure.

## Credentials

Map credentials per tool directory. Tools access them via `ctx.credentials`:

```json
{
  "credentials": {
    "stripe": {
      "env": "STRIPE_SECRET_KEY"
    },
    "github": {
      "env": "GITHUB_TOKEN"
    },
    "google": {
      "file": "~/.config/google/credentials.json"
    }
  }
}
```

The directory name in `tools/` maps to the credential key. `tools/stripe/list.js` gets the `stripe` credentials.

## Remote servers

Compose existing MCP servers. See the [Composability guide](https://github.com/antidrift-dev/zeromcp/blob/main/docs/guides/composability.md).

```json
{
  "remote": [
    {
      "name": "github",
      "url": "http://localhost:3001/mcp"
    },
    {
      "name": "jira",
      "url": "http://localhost:3002/mcp",
      "auth": "env:JIRA_TOKEN"
    }
  ]
}
```

## Namespacing

Override the prefix for a tool directory:

```json
{
  "namespacing": {
    "my-long-directory-name": {
      "prefix": "short"
    }
  }
}
```

`tools/my-long-directory-name/list.js` becomes `short_list` instead of `my-long-directory-name_list`.
