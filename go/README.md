# ZeroMCP &mdash; Go

Sandboxed MCP server library for Go. Register tools, call `ServeStdio()`, done.

## Getting started

```go
package main

import (
    "fmt"
    "github.com/antidrift-dev/zeromcp/pkg/zeromcp"
)

func main() {
    s := zeromcp.NewServer()

    s.Tool("hello", zeromcp.Tool{
        Description: "Say hello to someone",
        Input:       zeromcp.Input{"name": "string"},
        Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
            return fmt.Sprintf("Hello, %s!", args["name"]), nil
        },
    })

    s.ServeStdio()
}
```

```sh
go build -o my-server .
./my-server
```

Stdio works immediately. No transport configuration needed.

## vs. the official SDK

The official Go SDK (backed by Google) requires server setup, transport configuration, and schema definition. ZeroMCP handles the protocol, transport, and schema generation &mdash; you just define tools as struct literals and call `ServeStdio()`.

In benchmarks, ZeroMCP Go handles 13,317 requests/second over stdio versus the official SDK's 1,039 &mdash; 12.8x faster. Over HTTP (Chi), ZeroMCP serves 4,024 rps at 21&ndash;23 MB versus the official SDK's 893 rps at 30&ndash;44 MB. The official SDK requires Go 1.25+; ZeroMCP works with Go 1.22+.

Go passes all 10 conformance suites and survives 21/22 chaos monkey attacks.

The official SDK has **no sandbox**. ZeroMCP adds per-tool network allowlists, credential isolation, and a sandboxed `Ctx.Fetch()`.

## HTTP / Streamable HTTP

ZeroMCP doesn't own the HTTP layer. You bring your own framework; ZeroMCP gives you a `HandleRequest` method that takes a JSON-RPC map and returns a response map (or `nil` for notifications).

```go
// server.HandleRequest(request map[string]any) map[string]any
```

**net/http**

```go
import (
    "encoding/json"
    "net/http"
)

http.HandleFunc("/mcp", func(w http.ResponseWriter, r *http.Request) {
    var request map[string]any
    json.NewDecoder(r.Body).Decode(&request)

    response := s.HandleRequest(request)
    if response == nil {
        w.WriteHeader(http.StatusNoContent)
        return
    }
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(response)
})

http.ListenAndServe(":4242", nil)
```

## Requirements

- Go 1.22+

## Install

```sh
go get github.com/antidrift-dev/zeromcp/pkg/zeromcp
```

## Sandbox

### Network allowlists

```go
s.Tool("fetch_data", zeromcp.Tool{
    Description: "Fetch from our API",
    Input:       zeromcp.Input{"url": "string"},
    Permissions: &zeromcp.Permissions{
        Network: []string{"api.example.com", "*.internal.dev"},
    },
    Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
        return ctx.Fetch("GET", args["url"].(string), nil)
    },
})
```

`Ctx.Fetch()` validates the hostname against the allowlist before making the request. Unlisted domains are blocked and logged.

### Credential injection

Credentials configured in `zeromcp.config.json` are available via `ctx.Credentials`. Tools never read `os.Getenv()` directly.

## Input types

Shorthand strings in the `Input` map: `"string"`, `"number"`, `"boolean"`, `"object"`, `"array"`.

## Configuration

Optional `zeromcp.config.json`:

```json
{
  "transport": [
    { "type": "stdio" },
    { "type": "http", "port": 4242 }
  ],
  "logging": true,
  "bypass_permissions": false,
  "credentials": {
    "api": { "env": "API_KEY" }
  }
}
```

See the [root README](../README.md#configuration) for the full schema.

## Testing

```sh
go test ./...
```
