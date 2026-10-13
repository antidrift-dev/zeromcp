# ZeroMCP &mdash; Kotlin

Sandboxed MCP server library for Kotlin. DSL registration, call `server.serve()` for stdio, or mount `server.registry()` in your own HTTP server.

## Getting started

```kotlin
import io.antidrift.zeromcp.*

fun main() {
    val server = ZeroMcp()

    server.tool("hello") {
        description = "Say hello to someone"
        input {
            "name" to "string"
        }
        execute { args, _ ->
            "Hello, ${args.getString("name")}!"
        }
    }

    server.serve()
}
```

Stdio works immediately. No transport configuration needed.

## vs. the official SDK

The official Kotlin SDK (backed by JetBrains) requires server setup, transport configuration, and schema definition. ZeroMCP handles the protocol, transport, and schema generation with a clean Kotlin DSL and coroutine support.

In benchmarks, ZeroMCP Kotlin handles 8,396 requests/second over stdio versus the official SDK's 998 — 8.4x faster. Over HTTP (Ktor), ZeroMCP serves 2,848 rps at 188-194 MB versus the official SDK's 548 rps at 145-204 MB. The official SDK requires Kotlin 2.2+; ZeroMCP works with Kotlin 2.0+.

Kotlin passes all 10 conformance suites and survives 21/22 chaos monkey attacks.

The official SDK has **no sandbox**. ZeroMCP adds per-tool network allowlists, filesystem controls, and exec prevention.

## HTTP / Streamable HTTP

ZeroMCP doesn't own the HTTP layer and ships no HTTP server. You bring your own framework and mount ZeroMCP in it. `server.registry()` hands you everything as data:

- `routes`: tools that declared `route(method, path)`, as `RouteDefinition(name, method, path, tool)`. Paths use `:param` syntax.
- `openapi`: the OpenAPI 3.0 document for those routes, as a `JsonObject`.
- `mcp`: a suspend JSON-RPC handler, `(JsonObject) -> JsonObject?` (null for notifications).

`registry()` is a suspend function; call it once, after all `tool { ... }` registrations. If you only need MCP, `server.handleRequest(request)` is the same handler.

**Ktor**

```kotlin
import io.antidrift.zeromcp.*
import io.ktor.http.*
import io.ktor.server.application.*
import io.ktor.server.engine.*
import io.ktor.server.netty.*
import io.ktor.server.request.*
import io.ktor.server.response.*
import io.ktor.server.routing.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*

val registry = runBlocking { server.registry() }

embeddedServer(Netty, port = 4242) {
    routing {
        post("/mcp") {
            val request = Json.parseToJsonElement(call.receiveText()).jsonObject
            val response = registry.mcp(request)
            if (response == null) call.respond(HttpStatusCode.NoContent)
            else call.respondText(response.toString(), ContentType.Application.Json)
        }

        get("/openapi.json") {
            call.respondText(registry.openapi.toString(), ContentType.Application.Json)
        }

        for (r in registry.routes) {
            // Ktor uses {param}; ZeroMCP routes use :param.
            val path = r.path.replace(Regex(":(\\w+)"), "{$1}")
            route(path, HttpMethod.parse(r.method)) {
                handle {
                    val args = mutableMapOf<String, Any?>()
                    call.parameters.forEach { k, v -> args[k] = v.first() }
                    if (r.method != "GET") {
                        Json.parseToJsonElement(call.receiveText()).jsonObject
                            .forEach { (k, v) -> args[k] = (v as? JsonPrimitive)?.content ?: v }
                    }
                    val result = r.tool.execute(args, Ctx(r.name, r.tool.permissions))
                    call.respondText(
                        buildJsonObject { put("ok", true); put("result", result.toString()) }.toString(),
                        ContentType.Application.Json
                    )
                }
            }
        }
    }
}.start(wait = true)
```

A config with `"transport": "http"` (or any non-stdio transport) fails at startup with an error pointing here.

## Remote servers

List other MCP servers under `remote` in `zeromcp.config.json` and their tools are federated into yours, namespaced as `<name>.<tool>`:

```json
{
  "remote": [
    { "name": "probeo", "url": "https://mcp.probeo.io/mcp", "auth": "env:PROBEO_TOKEN", "tools": ["list_pages"] }
  ]
}
```

- `auth` is sent as `Authorization: Bearer <token>`; `env:VAR` reads it from the environment.
- `tools` is an optional allowlist of upstream tool names.
- A server that fails to connect is logged and skipped.
- A local tool with the same name overrides the remote one.
- Remote tools are MCP-only: they never appear in `registry().routes` or `openapi`.

`serve()` and `registry()` connect remotes for you. If you call `handleRequest` directly, call `server.connectRemotes()` once before serving.

## Runtime context

Set `runtimeProvider` to hand per-request data (a request object, tenant, DB handle) to tools. It is called on every local tool execution and its value arrives as `ctx.runtime`:

```kotlin
server.runtimeProvider = { currentTenant.get() }

server.tool("whoami") {
    description = "Current tenant"
    execute { _, ctx -> (ctx.runtime as Tenant).name }
}
```

It applies to `serve()`, `handleRequest` and `registry().mcp`. Remote tools never receive it.

## Config

`zeromcp.config.json` in the working directory (all keys optional):

| Key | Default | |
|---|---|---|
| `name`, `version` | `zeromcp`, `0.1.0` | `serverInfo` |
| `title` | `ZeroMCP` | OpenAPI title |
| `transport` | `stdio` | Only `stdio` is supported |
| `execute_timeout` | `30000` | ms; per-tool `executeTimeout` overrides |
| `page_size` | `0` | Page size for list responses; 0 = no pagination |
| `icon` | none | Data URI, http(s) URL, or file path; resolved to a data URI |
| `remote` | `[]` | See Remote servers |

## Requirements

- Kotlin 2.0+
- JVM 21
- Gradle

## Build & run

```sh
gradle :example:installDist -x test
./example/build/install/example/bin/example
```

## Sandbox

### Network allowlists

```kotlin
server.tool("fetch_url") {
    description = "Fetch a URL"
    input {
        required("url", "string", "The URL to fetch")
    }
    permissions {
        network("api.example.com", "*.github.com")
    }
    execute { args, ctx ->
        val url = args.getString("url") ?: return@execute "No URL provided"
        val host = java.net.URI(url).host
        if (!checkNetworkAccess(ctx.toolName, host, ctx.permissions)) {
            return@execute "Network access denied for $host"
        }
        "Fetched: $url"
    }
}
```

### Permission DSL

```kotlin
permissions {
    network("api.example.com", "*.internal.dev")
    fs("read")
    exec()
}
```

## Testing

```sh
gradle test
```
