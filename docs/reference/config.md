# Config File Reference

Complete reference for `zeromcp.config.json`.

## Full example

```json
{
  "tools": [
    {
      "path": "./tools",
      "prefix": ""
    },
    {
      "path": "./shared-tools",
      "prefix": "shared"
    }
  ],
  "transport": [
    { "type": "stdio" },
    {
      "type": "http",
      "port": 4242,
      "auth": "env:MCP_AUTH_TOKEN"
    }
  ],
  "credentials": {
    "stripe": {
      "env": "STRIPE_SECRET_KEY"
    },
    "google": {
      "file": "~/.config/google/credentials.json"
    }
  },
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
  ],
  "logging": true,
  "bypass_permissions": false,
  "autoload_tools": true,
  "namespacing": {
    "my-long-name": {
      "prefix": "short"
    }
  },
  "separator": "_"
}
```

## tools

**Type:** `string | Array<string | { path, prefix }>`  
**Default:** `"./tools"`

Where to scan for tool files. Accepts a single directory path, or an array of paths with optional prefixes.

## transport

**Type:** `object | Array<object>`  
**Default:** `{ "type": "stdio" }`

| Field | Type | Description |
| --- | --- | --- |
| `type` | `"stdio" | "http"` | Transport type |
| `port` | `number` | HTTP port (default: 4242) |
| `auth` | `string` | Auth token or `"env:VAR_NAME"` |

## credentials

**Type:** `Record<string, { env?: string, file?: string }>`  
**Default:** `{}`

Maps directory names to credential sources. Tools in `tools/stripe/` get the credentials from the `"stripe"` key.

## remote

**Type:** `Array<{ name, url, auth? }>`  
**Default:** `[]`

| Field | Type | Description |
| --- | --- | --- |
| `name` | `string` | Namespace prefix for this server's tools |
| `url` | `string` | HTTP/HTTPS URL of the MCP server |
| `auth` | `string` | Bearer token or `"env:VAR_NAME"` |

## Other fields

| Field | Type | Default | Description |
| --- | --- | --- | --- |
| `logging` | `boolean` | `false` | Log all sandboxed network calls |
| `bypass_permissions` | `boolean` | `false` | Warn instead of block |
| `autoload_tools` | `boolean` | `false` | Watch files and hot reload |
| `separator` | `string` | `"_"` | Namespace separator |
| `namespacing` | `Record<string, { prefix? }>` | `{}` | Override directory prefixes |
