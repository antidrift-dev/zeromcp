package io.antidrift.zeromcp

import com.sun.net.httpserver.HttpServer
import kotlinx.serialization.json.*
import java.io.ByteArrayOutputStream
import java.io.PrintStream
import java.net.InetSocketAddress
import java.util.Collections

/**
 * A fake upstream MCP server over HTTP, answering like
 * nodejs/test/handler-remote.test.js: tools list_pages and get_page.
 */
class FakeUpstream(private val status: Int = 200) : AutoCloseable {
    val methods: MutableList<String> = Collections.synchronizedList(mutableListOf())
    val authHeaders: MutableList<String?> = Collections.synchronizedList(mutableListOf())
    val callArgs: MutableList<JsonElement?> = Collections.synchronizedList(mutableListOf())

    private val server: HttpServer = HttpServer.create(InetSocketAddress("127.0.0.1", 0), 0).apply {
        createContext("/") { ex ->
            val req = Json.parseToJsonElement(String(ex.requestBody.readBytes())).jsonObject
            val method = req["method"]!!.jsonPrimitive.content
            methods.add(method)
            authHeaders.add(ex.requestHeaders.getFirst("Authorization"))
            if (method == "tools/call") callArgs.add(req["params"]?.jsonObject?.get("arguments"))
            val body = buildJsonObject {
                put("jsonrpc", "2.0")
                req["id"]?.let { put("id", it) }
                put("result", resultFor(method))
            }.toString().toByteArray()
            ex.responseHeaders.set("Content-Type", "application/json")
            ex.sendResponseHeaders(status, body.size.toLong())
            ex.responseBody.use { it.write(body) }
        }
        start()
    }

    val url: String get() = "http://127.0.0.1:${server.address.port}"

    private fun resultFor(method: String): JsonObject = when (method) {
        "initialize" -> buildJsonObject {
            put("protocolVersion", "2025-03-26")
            putJsonObject("capabilities") {}
            putJsonObject("serverInfo") { put("name", "probeo"); put("version", "test") }
        }
        "tools/list" -> buildJsonObject {
            putJsonArray("tools") {
                addJsonObject {
                    put("name", "list_pages")
                    put("description", "Lists pages.")
                    putJsonObject("inputSchema") {
                        put("type", "object")
                        putJsonObject("properties") { putJsonObject("domain") { put("type", "string") } }
                        putJsonArray("required") { add("domain") }
                    }
                }
                addJsonObject {
                    put("name", "get_page")
                    put("description", "Gets a page.")
                    putJsonObject("inputSchema") {
                        put("type", "object")
                        putJsonObject("properties") { putJsonObject("url") { put("type", "string") } }
                        putJsonArray("required") { add("url") }
                    }
                }
            }
        }
        "tools/call" -> buildJsonObject {
            putJsonArray("content") { addJsonObject { put("type", "text"); put("text", PAGES_TEXT) } }
        }
        else -> JsonObject(emptyMap())
    }

    override fun close() = server.stop(0)

    companion object {
        const val PAGES_TEXT = """{"pages":[]}"""
    }
}

/** Runs [block] with System.err captured; returns what was written. */
fun captureStderr(block: () -> Unit): String {
    val original = System.err
    val buf = ByteArrayOutputStream()
    System.setErr(PrintStream(buf, true))
    try {
        block()
    } finally {
        System.setErr(original)
    }
    return buf.toString()
}

fun rpc(id: Int, method: String, params: JsonObject? = null): JsonObject = buildJsonObject {
    put("jsonrpc", "2.0")
    put("id", id)
    put("method", method)
    params?.let { put("params", it) }
}

fun callRpc(id: Int, name: String, args: JsonObject = JsonObject(emptyMap())): JsonObject =
    rpc(id, "tools/call", buildJsonObject { put("name", name); put("arguments", args) })

fun JsonObject?.toolNames(): List<String> =
    this?.get("result")?.jsonObject?.get("tools")?.jsonArray?.map { it.jsonObject["name"]!!.jsonPrimitive.content } ?: emptyList()

fun JsonObject?.firstText(): String? =
    this?.get("result")?.jsonObject?.get("content")?.jsonArray?.get(0)?.jsonObject?.get("text")?.jsonPrimitive?.content
