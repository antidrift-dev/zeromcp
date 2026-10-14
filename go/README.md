# ZeroMCP &mdash; Go

Sandboxed MCP server library for Go. Register tools, call `ServeStdio()`, done. For HTTP, mount `HandleRequest` or `Registry()` in your own server.

## Getting started

```go
package main

import (
    "fmt"
    "github.com/antidrift-dev/zeromcp-go/pkg/zeromcp"
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

For tool routes and an OpenAPI document as well, use `Registry()` (next section).

ZeroMCP has no built-in HTTP server. A config with an `http` transport makes `Serve()` exit at startup with an error pointing to `Registry()`.

## HTTP routes & OpenAPI: `Registry()`

Give a tool a `Route` and it can be mounted as a plain REST endpoint, in addition to being callable over MCP:

```go
s.Tool("greet", zeromcp.Tool{
    Description: "Greet a person by name",
    Input:       zeromcp.Input{"name": "string"},
    Route:       &zeromcp.RouteConfig{Method: "GET", Path: "/greet/:name"},
    Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
        return fmt.Sprintf("Hello, %s!", args["name"]), nil
    },
})
```

`s.Registry()` returns plain data for your own HTTP server: `Routes` (one entry per routed tool, with an `Invoke` func), `OpenAPI` (an OpenAPI 3.0 spec built from every routed tool's `Input`; set `"title"` in the config to name it, default `"ZeroMCP"`), and `MCP` (a JSON-RPC handler over raw bytes). Mounting it on a `net/http` `ServeMux` (Go 1.22 patterns):

```go
import (
    "encoding/json"
    "io"
    "net/http"
    "regexp"
    "strings"
)

reg := s.Registry()
mux := http.NewServeMux()

mux.HandleFunc("GET /openapi.json", func(w http.ResponseWriter, r *http.Request) {
    w.Header().Set("Content-Type", "application/json")
    json.NewEncoder(w).Encode(reg.OpenAPI)
})

mux.HandleFunc("POST /mcp", func(w http.ResponseWriter, r *http.Request) {
    body, _ := io.ReadAll(r.Body)
    out := reg.MCP(body)
    if out == nil { // notification
        w.WriteHeader(http.StatusNoContent)
        return
    }
    w.Header().Set("Content-Type", "application/json")
    w.Write(out)
})

param := regexp.MustCompile(`:(\w+)`)
for _, route := range reg.Routes {
    route := route
    var names []string
    pattern := param.ReplaceAllStringFunc(route.Route.Path, func(m string) string {
        names = append(names, m[1:])
        return "{" + m[1:] + "}"
    })
    method := strings.ToUpper(route.Route.Method)

    mux.HandleFunc(method+" "+pattern, func(w http.ResponseWriter, r *http.Request) {
        args := map[string]any{}
        for _, n := range names {
            args[n] = r.PathValue(n)
        }
        if method == "GET" {
            for k, v := range r.URL.Query() {
                args[k] = v[0]
            }
        } else {
            json.NewDecoder(r.Body).Decode(&args)
        }
        result, err := route.Invoke(args)
        w.Header().Set("Content-Type", "application/json")
        if err != nil {
            w.WriteHeader(http.StatusInternalServerError)
            json.NewEncoder(w).Encode(map[string]any{"error": err.Error()})
            return
        }
        json.NewEncoder(w).Encode(result)
    })
}

http.ListenAndServe(":4242", mux)
```

How args are built, the response shape, auth and CORS are up to you. `Registry()` snapshots `Routes` and `OpenAPI`, so call it after registering tools. `MCP` dispatches live, so it sees tools registered later.

## Remote servers

Federate tools from other MCP servers over HTTP. Remote tools are named `<server>.<tool>`, appear in `tools/list` and `tools/call` (stdio, `HandleRequest`, and `Registry().MCP`), and are never in `Routes` or `OpenAPI`.

```go
s := zeromcp.NewServerWithConfig(zeromcp.Config{
    Remote: []zeromcp.RemoteServer{{
        Name:  "probeo",
        URL:   "https://mcp.example.com/mcp",
        Auth:  "env:PROBEO_TOKEN",       // or a literal token; sent as "Authorization: Bearer ..."
        Tools: []string{"list_pages"},   // optional allowlist; nil = all, empty = none
    }},
})
```

```json
{ "remote": [{ "name": "probeo", "url": "https://mcp.example.com/mcp", "auth": "env:PROBEO_TOKEN", "tools": ["list_pages"] }] }
```

`NewServerWithConfig` connects to each remote (`initialize`, then `tools/list`) before it returns. A server that is not `http(s)`, that returns a non-2xx status, or that offers an unsupported type is logged and skipped. A local tool registered under the same name replaces the remote one and logs `Local tool "<name>" overrides remote`.

## Runtime context

`SetRuntime` installs a function called on every local tool execution. A non-nil result is exposed to the tool as `ctx.Runtime`. It applies to stdio, `HandleRequest`/`HandleRequestBytes`, and `Registry()` (`MCP` and `Routes[i].Invoke`). Remote tools ignore it.

```go
s.SetRuntime(func() any { return currentTenant() })

s.Tool("whoami", zeromcp.Tool{
    Input: zeromcp.Input{},
    Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
        return ctx.Runtime, nil // nil when no runtime is set
    },
})
```

## Requirements

- Go 1.22+

## Install

```sh
go get github.com/antidrift-dev/zeromcp-go/pkg/zeromcp
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

Credentials configured in `zeromcp.config.json` are resolved by namespace via `server.ResolveToolCredentials(ns)`, where `ns` matches a key in the `credentials` map. Results are cached after the first read by default (set `"cache_credentials": false` to re-read on every call). Tools never read `os.Getenv()` directly.

```go
s.Tool("search_contacts", zeromcp.Tool{
    Description: "Search contacts in a CRM",
    Input:       zeromcp.Input{"query": "string"},
    Execute: func(args map[string]any, ctx *zeromcp.Ctx) (any, error) {
        creds := s.ResolveToolCredentials("api") // matches "api" in credentials config
        // use creds...
        return nil, nil
    },
})
```

## Input types

Shorthand strings in the `Input` map: `"string"`, `"number"`, `"boolean"`, `"object"`, `"array"`.

## Configuration

Optional `zeromcp.config.json`:

```json
{
  "transport": { "type": "stdio" },
  "logging": true,
  "bypass_permissions": false,
  "credentials": {
    "api": { "env": "API_KEY" }
  }
}
```

`"stdio"` is the only transport. See the [root README](../README.md#configuration) for the full schema.

## CLI: plugin tools, resources and prompts

The `zeromcp` command (`cmd/zeromcp`) loads Go plugins (`go build -buildmode=plugin`) from directories:

```json
{
  "tools": ["./tools", { "path": "./vendor-tools", "prefix": "vendor" }],
  "namespacing": { "crm": { "prefix": "" }, "db": { "prefix": "data" } },
  "separator": "_",
  "resources": "./resources",
  "prompts": "./prompts",
  "autoload_tools": true
}
```

- **`tools`**: a path, or an array of paths and `{ "path", "prefix" }` objects. The default is `./tools`, and `--tools <dir>` overrides it. Each `.so` exports `var Tool = zeromcp.PluginTool{...}`. A file in a subdirectory is named `<dir><separator><file>`, and a source `prefix` is put in front of that.
- **`namespacing`**: overrides the prefix for a top-level directory. `""` drops it.
- **`resources`**: every file becomes a resource. Static files are served as-is, with the URI `resource:///<relative path>` and a MIME type from the extension. A `.so` exports `var Resource = zeromcp.ResourceDef{...}` or `var ResourceTemplate = zeromcp.ResourceTemplateDef{...}`.
- **`prompts`**: each `.so` exports `var Prompt = zeromcp.PromptDef{...}`.
- **`autoload_tools`**: polls the tool directories once a second. When a `.so` is added or changed, the CLI rescans, registers the tools, and sends `notifications/tools/list_changed` over stdio. Tools are added or replaced, never removed. Go cannot unload or reload a plugin: `plugin.Open` returns the already-loaded plugin for a path it has opened before. So only a `.so` at a **new path** takes effect, and a plugin rebuilt in place keeps its old code until restart. Library users can call `Scanner.Watch` and `Server.Notify` themselves.

## Testing

```sh
go test ./pkg/...
```
