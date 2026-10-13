# ZeroMCP &mdash; Java

Sandboxed MCP server library for Java. Builder API, call `server.serve()`, done.

## Getting started

```java
import io.antidrift.zeromcp.*;

public class Main {
    public static void main(String[] args) {
        var server = new ZeroMcp();

        server.tool("hello", Tool.builder()
            .description("Say hello to someone")
            .input(Input.required("name", "string", "The person's name"))
            .execute((a, ctx) -> "Hello, " + a.get("name") + "!")
            .build());

        server.serve();
    }
}
```

Stdio works immediately. No transport configuration needed.

## vs. the official SDK

The official Java SDK (backed by Spring AI) requires server setup, transport configuration, and schema definition. ZeroMCP handles the protocol, transport, and schema generation with a clean builder API &mdash; no Spring framework required, just a JAR.

In benchmarks, ZeroMCP Java handles 11,168 requests/second over stdio versus the official SDK's 4,469 &mdash; 2.5x faster with 53% less memory (47 MB vs 99 MB). Over HTTP (Javalin), ZeroMCP serves 3,791 rps at 184-207 MB versus the official SDK's 2,658 rps at 203-217 MB.

Java passes all 10 conformance suites and survives 21/22 chaos monkey attacks.

The official SDK has **no sandbox**. ZeroMCP adds per-tool network allowlists, filesystem controls, and exec prevention.

## Bring your own HTTP server

ZeroMCP does not ship an HTTP server. It speaks stdio out of the box; for HTTP, mount it in the server you already run. Setting `"transport": "http"` in `zeromcp.config.json` makes `serve()` throw at startup, pointing you here.

`server.registry()` gives you everything as plain data:

- `routes()`: one `RouteDefinition(name, method, path, tool)` per tool built with `.route(method, path)`. Paths use `:param` segments.
- `openapi()`: an OpenAPI 3.0 spec (`JsonObject`) for those routes.
- `mcp()`: a JSON-RPC handler. `mcp().handle(request)` takes a `JsonObject` and returns a `JsonObject`, or `null` for notifications.

```java
server.tool("greet", Tool.builder()
    .description("Greet a person by name")
    .input(Input.required("name", "string"))
    .route("GET", "/greet/:name")
    .execute((a, ctx) -> "Hello, " + a.get("name") + "!")
    .build());

var registry = server.registry();
```

**Javalin**

```java
import io.javalin.Javalin;
import com.google.gson.Gson;
import com.google.gson.JsonParser;

var gson = new Gson();
var app = Javalin.create().start(4242);

// MCP over HTTP POST
app.post("/mcp", ctx -> {
    var request = JsonParser.parseString(ctx.body()).getAsJsonObject();
    var response = registry.mcp().handle(request);
    if (response == null) ctx.status(204);
    else ctx.contentType("application/json").result(response.toString());
});

// OpenAPI spec
app.get("/openapi.json", ctx -> ctx.contentType("application/json").result(registry.openapi().toString()));

// Route-annotated tools as REST endpoints
for (var route : registry.routes()) {
    var path = route.path().replaceAll(":([^/]+)", "{$1}");   // :name -> {name}
    app.addHttpHandler(io.javalin.http.HandlerType.valueOf(route.method()), path, ctx -> {
        var args = new java.util.HashMap<String, Object>(ctx.pathParamMap());
        if ("GET".equals(route.method())) {
            ctx.queryParamMap().forEach((k, v) -> args.put(k, v.get(0)));
        } else if (!ctx.body().isBlank()) {
            args.putAll(gson.fromJson(ctx.body(), java.util.Map.class));
        }
        var result = route.tool().executor().execute(args, new Ctx(route.name(), route.tool().permissions()));
        ctx.json(java.util.Map.of("ok", true, "result", result));
    });
}
```

If you only need MCP, skip `registry()` and call `server.handleRequest(request)` directly; it is the same handler as `registry().mcp()`.

## Remote servers

Pull tools from other MCP servers over HTTP. They are listed and called as `<name>.<tool>`, next to your own tools. A local tool with the same name wins.

```json
{
  "remote": [
    { "name": "probeo", "url": "https://mcp.example.com/mcp", "auth": "env:PROBEO_TOKEN", "tools": ["list_pages"] }
  ]
}
```

Or in code:

```java
var server = new ZeroMcp()
    .remote(new RemoteServer("probeo", "https://mcp.example.com/mcp", "env:PROBEO_TOKEN", List.of("list_pages")));
```

`auth` is sent as `Authorization: Bearer <token>`; `env:VAR` reads the token from the environment. `tools` is an optional allowlist. Remotes connect once, on the first `serve()`, `handleRequest()` or `registry()` call. A server that fails to connect is logged and skipped. Remote tools are served over MCP only; they never appear in `routes()` or `openapi()`.

## Runtime context

Pass per-request or per-deployment state to every tool with a supplier. It is called once per tool call and the value is available as `ctx.runtime()`:

```java
server.runtime(() -> currentTenant());

server.tool("whoami", Tool.builder()
    .execute((a, ctx) -> "tenant: " + ctx.runtime(String.class))
    .build());
```

It applies to `serve()`, `handleRequest()` and `registry().mcp()`. Remote tools do not receive it. When you call a `RouteDefinition`'s executor yourself, pass the value through `new Ctx(name, permissions, runtime)`.

## Config

`zeromcp.config.json` in the working directory (all keys optional):

| Key | Default | |
|---|---|---|
| `name`, `version`, `title` | `zeromcp`, `0.1.0`, `ZeroMCP` | Server info; `title` is the OpenAPI title |
| `execute_timeout` | `30000` | Tool timeout in ms (per-tool override in `Permissions`) |
| `page_size` | `0` | Page size for list results; `0` disables pagination. `pageSize(int)` overrides |
| `icon` | none | Data URI, http(s) URL (fetched) or file path (read), sent as a `data:` URI. `icon(String)` overrides |
| `remote` | `[]` | Remote servers, see above |
| `transport` | `stdio` | Only `stdio` is supported |

## Requirements

- Java 17+
- Maven

## Build & run

```sh
mvn package -q -DskipTests
mvn dependency:copy-dependencies -DoutputDirectory=target/deps -q
javac -cp "target/zeromcp.jar:target/deps/*" -d /tmp/java-out example/src/main/java/Main.java
java -cp "target/zeromcp.jar:target/deps/*:/tmp/java-out" Main
```

## Sandbox

### Network allowlists

```java
server.tool("fetch_url", Tool.builder()
    .description("Fetch a URL")
    .input(Input.required("url", "string"))
    .permissions(new Permissions(
        Permissions.NetworkPermission.allowList("api.example.com", "*.github.com"),
        Permissions.FsPermission.NONE,
        false  // exec
    ))
    .execute((a, ctx) -> {
        var url = (String) a.get("url");
        var host = java.net.URI.create(url).getHost();
        if (!Sandbox.checkNetworkAccess(ctx.toolName(), host, ctx.permissions())) {
            return "Network access denied for " + host;
        }
        return "Fetched: " + url;
    })
    .build());
```

### Permission model

Sealed interface pattern for type-safe permissions:

- `NetworkPermission.allowList(...)` / `.all()` / `.denied()`
- `FsPermission.READ` / `.WRITE` / `.NONE` / `.FULL`
- `exec: true/false`

## Testing

```sh
mvn test
```
