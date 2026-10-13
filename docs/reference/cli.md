# CLI Reference

ZeroMCP ships two commands: `serve` and `audit`.

## zeromcp serve

Start the MCP server over stdio. Scans tool directories and connects remote servers. There is no built-in HTTP server; mount the handler or registry in your own server for HTTP.

```
zeromcp serve [options] [config-path]
```

### Arguments

| Argument | Default | Description |
| --- | --- | --- |
| `config-path` | `./zeromcp.config.json` | Path to config file. If omitted, searches current directory. |

### Flags

| Flag | Default | Description |
| --- | --- | --- |
| `--tools` | `./tools` | Override tool directory (takes precedence over config file) |
| `--watch`, `-w` | `false` | Watch tool files for changes and hot-reload |
| `--verbose`, `-v` | `false` | Enable verbose logging to stderr |
| `--quiet`, `-q` | `false` | Suppress all non-error output |
| `--version` | — | Print version and exit |
| `--help`, `-h` | — | Print help and exit |

### Example: stdio transport (default)

```
$ zeromcp serve
[zeromcp] v0.1.0
[zeromcp] Config: ./zeromcp.config.json
[zeromcp] Tools:  ./tools
[zeromcp] Loaded: hello
[zeromcp] Loaded: stripe_list_customers
[zeromcp] Loaded: github_list_issues
[zeromcp] 3 local + 0 remote = 3 tool(s)
[zeromcp] stdio transport ready
```

All log output goes to stderr. stdout is reserved for MCP JSON-RPC communication.

## zeromcp audit

Run static analysis on tool files. Checks for security violations before publishing or deploying.

```
zeromcp audit [options] [tools-path]
```

### Arguments

| Argument | Default | Description |
| --- | --- | --- |
| `tools-path` | `./tools` | Directory of tool files to audit |

### Flags

| Flag | Default | Description |
| --- | --- | --- |
| `--format`, `-f` | `text` | Output format: `text` or `json` |
| `--strict` | `false` | Treat warnings as failures |
| `--fix` | `false` | Auto-fix simple violations (e.g., add missing permission blocks) |
| `--verbose`, `-v` | `false` | Show detailed violation context |
| `--help`, `-h` | — | Print help and exit |

### What it checks

-   **Permission declarations:** Every tool must declare a `permissions` block (network, fs, exec)
-   **No direct env access:** No `process.env`, `os.environ`, `System.getenv`, or `ENV[]` — use `ctx.credentials`
-   **No global fetch:** No global `fetch`, `http.get`, `urllib`, etc. — use `ctx.fetch`
-   **No undeclared filesystem access:** No `fs.readFile`, `open()`, etc. without declared `fs` permissions
-   **No hardcoded credentials:** Scans for API key patterns, bearer tokens, and base64-encoded secrets
-   **No exec without permission:** No `child_process`, `subprocess`, or `exec()` without declared `exec` permissions

### Example: text output

```bash
$ zeromcp audit ./tools
✓ stripe/list_customers.js — permissions declared, no raw env access
✓ stripe/create_charge.js — permissions declared, no raw env access
✗ github/issues.js — uses global fetch (should use ctx.fetch)
✗ utils/helper.js — accesses process.env directly

2 passed, 2 failed
```

### Example: JSON output

```bash
$ zeromcp audit --format json ./tools
{
  "passed": 2,
  "failed": 2,
  "results": [
    { "file": "stripe/list_customers.js", "status": "pass" },
    { "file": "stripe/create_charge.js", "status": "pass" },
    { "file": "github/issues.js", "status": "fail", "reason": "uses global fetch" },
    { "file": "utils/helper.js", "status": "fail", "reason": "accesses process.env" }
  ]
}
```

The audit CLI gates the community tool registry. Tools with violations cannot be published.

## Environment Variables

| Variable | Description |
| --- | --- |
| `ZEROMCP_CONFIG` | Path to config file (overrides default `./zeromcp.config.json`) |
| `ZEROMCP_TOOLS` | Path to tools directory (overrides config file `tools` field) |
| `ZEROMCP_TRANSPORT` | Transport type: `stdio` or `http` |
| `ZEROMCP_PORT` | HTTP port (default: `3000`) |
| `ZEROMCP_HOST` | HTTP bind address (default: `127.0.0.1`) |
| `ZEROMCP_LOG_LEVEL` | Log verbosity: `error`, `warn`, `info`, `debug` |
| `NO_COLOR` | Disable colored output (respects the [no-color standard](https://no-color.org)) |

CLI flags take precedence over environment variables. Environment variables take precedence over config file values.

## Exit Codes

| Code | Meaning |
| --- | --- |
| `0` | Success. For `serve`: clean shutdown. For `audit`: all tools passed. |
| `1` | General error (invalid config, missing tools directory, etc.) |
| `2` | Audit failures detected (one or more tools have violations) |
| `130` | Interrupted (SIGINT / Ctrl+C) |

## Precedence Order

When the same setting is specified in multiple places, the following order applies (highest to lowest):

1.  CLI flags (`--port 8080`)
2.  Environment variables (`ZEROMCP_PORT=8080`)
3.  Config file (`zeromcp.config.json`)
4.  Built-in defaults
