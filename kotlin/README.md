# ZeroMCP &mdash; Kotlin

Sandboxed MCP server library for Kotlin. DSL registration, call `server.serve()`, done.

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

ZeroMCP doesn't own the HTTP layer. You bring your own framework; ZeroMCP gives you a suspend `handleRequest` method that takes a `JsonObject` and returns `JsonObject?`.

```kotlin
// val response: JsonObject? = server.handleRequest(request)
```

**Ktor**

```kotlin
import io.ktor.server.application.*
import io.ktor.server.engine.*
import io.ktor.server.netty.*
import io.ktor.server.routing.*
import kotlinx.serialization.json.Json

embeddedServer(Netty, port = 4242) {
    routing {
        post("/mcp") {
            val body = call.receiveText()
            val request = Json.parseToJsonElement(body).jsonObject
            val response = server.handleRequest(request)
            if (response == null) {
                call.respond(HttpStatusCode.NoContent)
            } else {
                call.respondText(response.toString(), ContentType.Application.Json)
            }
        }
    }
}.start(wait = true)
```

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
    fs(FsPermission.READ)
    exec(false)
}
```

## Testing

```sh
gradle test
```
