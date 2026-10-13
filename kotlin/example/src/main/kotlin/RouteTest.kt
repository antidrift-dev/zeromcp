import com.sun.net.httpserver.HttpExchange
import com.sun.net.httpserver.HttpServer
import io.antidrift.zeromcp.*
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import java.net.InetSocketAddress
import java.net.URLDecoder

/**
 * Route conformance harness (ZEROMCP_ROUTE_TEST=true). Test-only: ZeroMCP ships
 * no HTTP server, so this mounts ZeroMcp.registry() on the JDK's built-in
 * HttpServer the way a user would mount it in their own framework.
 */
fun routeTestMain() {
    val server = ZeroMcp()

    server.tool("greet") {
        description = "Greet a person by name"
        input {
            "name" to "string"
        }
        route("GET", "/greet/:name")
        execute { args, _ ->
            "Hello, ${args.getString("name")}!"
        }
    }

    server.tool("echo") {
        description = "Echo a message back"
        input {
            "message" to "string"
        }
        route("POST", "/echo")
        execute { args, _ ->
            mapOf(
                "message" to args.getString("message"),
                "echoed" to true
            )
        }
    }

    val registry = runBlocking { server.registry() }
    val port = 14257
    val http = HttpServer.create(InetSocketAddress(port), 0)

    http.createContext("/mcp") { ex ->
        if (ex.requestMethod != "POST") { send(ex, 405, """{"error":"Method not allowed"}"""); return@createContext }
        val request = try {
            Json.parseToJsonElement(String(ex.requestBody.readBytes())).jsonObject
        } catch (_: Exception) {
            send(ex, 200, """{"jsonrpc":"2.0","error":{"code":-32700,"message":"Parse error"}}"""); return@createContext
        }
        val response = runBlocking { registry.mcp(request) }
        send(ex, 200, response?.toString() ?: """{"jsonrpc":"2.0","result":{}}""")
    }

    http.createContext("/openapi.json") { ex -> send(ex, 200, registry.openapi.toString()) }

    http.createContext("/docs") { ex -> send(ex, 200, SWAGGER_HTML, "text/html") }

    http.createContext("/") { ex ->
        val method = ex.requestMethod.uppercase()
        val urlPath = ex.requestURI.path
        for (route in registry.routes) {
            if (route.method != method) continue
            val params = matchPath(route.path, urlPath) ?: continue

            val args = mutableMapOf<String, Any?>()
            args.putAll(params)
            if (method == "GET") {
                for (pair in (ex.requestURI.rawQuery ?: "").split("&")) {
                    val i = pair.indexOf('=')
                    if (i > 0) args[decode(pair.substring(0, i))] = decode(pair.substring(i + 1))
                }
            } else {
                val body = ex.requestBody.readBytes()
                if (body.isNotEmpty()) {
                    try {
                        for ((k, v) in Json.parseToJsonElement(String(body)).jsonObject) {
                            args[k] = if (v is JsonPrimitive && v.isString) v.content else v
                        }
                    } catch (_: Exception) { /* ignore malformed body */ }
                }
            }

            try {
                val result = runBlocking { route.tool.execute(args, Ctx(route.name, route.tool.permissions)) }
                send(ex, 200, buildJsonObject {
                    put("ok", true)
                    put("result", toJson(result))
                }.toString())
            } catch (e: Exception) {
                send(ex, 500, buildJsonObject {
                    put("ok", false)
                    put("error", e.message ?: "error")
                }.toString())
            }
            return@createContext
        }
        send(ex, 404, """{"error":"Not found"}""")
    }

    http.start()
    System.err.println("[route-test] registry mounted on port $port")
    Thread.currentThread().join()
}

private fun matchPath(pattern: String, urlPath: String): Map<String, String>? {
    val pp = pattern.trim('/').split("/")
    val up = urlPath.trim('/').split("/")
    if (pp.size != up.size) return null
    val params = mutableMapOf<String, String>()
    for (i in pp.indices) {
        if (pp[i].startsWith(":")) params[pp[i].substring(1)] = up[i]
        else if (pp[i] != up[i]) return null
    }
    return params
}

private fun decode(s: String): String = URLDecoder.decode(s, Charsets.UTF_8)

private fun toJson(value: Any?): JsonElement = when (value) {
    null -> JsonNull
    is JsonElement -> value
    is String -> JsonPrimitive(value)
    is Number -> JsonPrimitive(value)
    is Boolean -> JsonPrimitive(value)
    is Map<*, *> -> JsonObject(value.entries.associate { (k, v) -> k.toString() to toJson(v) })
    is List<*> -> JsonArray(value.map { toJson(it) })
    else -> JsonPrimitive(value.toString())
}

private fun send(ex: HttpExchange, status: Int, body: String, contentType: String = "application/json") {
    val bytes = body.toByteArray()
    ex.responseHeaders.set("Content-Type", contentType)
    ex.sendResponseHeaders(status, bytes.size.toLong())
    ex.responseBody.use { it.write(bytes) }
}

private const val SWAGGER_HTML = """<!DOCTYPE html>
<html>
<head>
  <title>ZeroMCP API</title>
  <meta charset="utf-8"/>
  <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist/swagger-ui.css">
</head>
<body>
<div id="swagger-ui"></div>
<script src="https://unpkg.com/swagger-ui-dist/swagger-ui-bundle.js"></script>
<script>SwaggerUIBundle({ url: '/openapi.json', dom_id: '#swagger-ui' })</script>
</body>
</html>"""
