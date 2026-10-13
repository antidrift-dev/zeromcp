package io.antidrift.zeromcp

import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import java.io.File
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse
import java.util.Base64

/**
 * A remote MCP server whose tools are federated into this one, namespaced as
 * `<name>.<toolName>`. [tools], when set, is an allowlist of upstream tool names.
 */
@Serializable
data class RemoteServer(
    val name: String,
    val url: String,
    val auth: String? = null,
    val tools: List<String>? = null
)

@Serializable
data class ZeroMcpConfig(
    val transport: String = "stdio",
    val logging: Boolean = false,
    val bypass_permissions: Boolean = false,
    val separator: String = "_",
    val name: String = "zeromcp",
    val version: String = "0.1.0",
    val title: String = "ZeroMCP",
    val execute_timeout: Long = 30000, // ms
    val cache_credentials: Boolean = true,
    val icon: String? = null,
    val page_size: Int = 0,
    val remote: List<RemoteServer> = emptyList()
)

private val json = Json { ignoreUnknownKeys = true }

/**
 * The startup error for any transport other than stdio. ZeroMCP does not ship
 * an HTTP server; the registry and request handler are mounted in the user's own.
 */
internal fun unsupportedTransport(value: String): IllegalStateException =
    IllegalStateException(
        "transport \"$value\" is not supported: ZeroMCP does not ship an HTTP server. " +
            "Mount ZeroMcp.registry() (routes, openapi, mcp) or ZeroMcp.handleRequest() in your own HTTP server."
    )

/**
 * Throws if the raw `transport` value asks for anything but stdio. Accepts a
 * string or an array of `{ "type": ... }` objects.
 */
private fun checkRawTransport(transport: JsonElement?) {
    when (transport) {
        null -> return
        is JsonPrimitive -> if (transport.content != "stdio") throw unsupportedTransport(transport.content)
        is JsonArray -> for (entry in transport) {
            val type = when (entry) {
                is JsonObject -> (entry["type"] as? JsonPrimitive)?.content ?: entry.toString()
                is JsonPrimitive -> entry.content
                else -> entry.toString()
            }
            if (type != "stdio") throw unsupportedTransport(type)
        }
        else -> throw unsupportedTransport(transport.toString())
    }
}

/**
 * Loads configuration from zeromcp.config.json in the given directory.
 * Returns defaults if the file does not exist or cannot be parsed.
 * Throws [IllegalStateException] if the config asks for a transport other than stdio.
 */
fun loadConfig(dir: String = "."): ZeroMcpConfig {
    val file = File(dir, "zeromcp.config.json")
    if (!file.exists()) return ZeroMcpConfig()

    val raw = try {
        json.parseToJsonElement(file.readText()).jsonObject
    } catch (e: Exception) {
        System.err.println("[zeromcp] Warning: failed to parse config: ${e.message}")
        return ZeroMcpConfig()
    }

    // Outside the decode try below, so the startup error is never swallowed.
    checkRawTransport(raw["transport"])

    return try {
        // An all-stdio transport array is valid; normalise it to the string form.
        val normalized = if (raw["transport"] is JsonArray) {
            JsonObject(raw + ("transport" to JsonPrimitive("stdio")))
        } else raw
        json.decodeFromJsonElement(ZeroMcpConfig.serializer(), normalized)
    } catch (e: Exception) {
        System.err.println("[zeromcp] Warning: failed to parse config: ${e.message}")
        ZeroMcpConfig()
    }
}

/**
 * Resolves an auth string — if it starts with "env:", reads from environment.
 */
fun resolveAuth(auth: String?): String? {
    if (auth == null) return null
    if (auth.startsWith("env:")) {
        val envVar = auth.substring(4)
        val value = System.getenv(envVar)
        if (value == null) {
            System.err.println("[zeromcp] Warning: environment variable $envVar not set")
        }
        return value
    }
    return auth
}

private val ICON_MIME = mapOf(
    ".png" to "image/png",
    ".jpg" to "image/jpeg",
    ".jpeg" to "image/jpeg",
    ".gif" to "image/gif",
    ".svg" to "image/svg+xml",
    ".ico" to "image/x-icon",
    ".webp" to "image/webp"
)

/**
 * Resolve an icon config value to a data URI.
 * Accepts: data URI (passthrough), http(s) URL (fetched), file path (read, `~` expanded).
 * Returns null, with a warning on stderr, when the icon cannot be loaded.
 */
fun resolveIcon(icon: String?): String? {
    if (icon.isNullOrEmpty()) return null

    if (icon.startsWith("data:")) return icon

    val b64 = Base64.getEncoder()

    if (icon.startsWith("http://") || icon.startsWith("https://")) {
        return try {
            val client = HttpClient.newBuilder().followRedirects(HttpClient.Redirect.NORMAL).build()
            val res = client.send(HttpRequest.newBuilder(URI(icon)).GET().build(), HttpResponse.BodyHandlers.ofByteArray())
            if (res.statusCode() !in 200..299) {
                System.err.println("[zeromcp] Warning: failed to fetch icon $icon: ${res.statusCode()}")
                return null
            }
            val contentType = res.headers().firstValue("content-type").orElse("").ifEmpty { "image/png" }
            "data:$contentType;base64,${b64.encodeToString(res.body())}"
        } catch (e: Exception) {
            System.err.println("[zeromcp] Warning: failed to fetch icon $icon: ${e.message}")
            null
        }
    }

    return try {
        val path = if (icon.startsWith("~")) (System.getenv("HOME") ?: "") + icon.substring(1) else icon
        val bytes = File(path).readBytes()
        val dot = path.lastIndexOf('.')
        val slash = path.lastIndexOf('/')
        val ext = if (dot > slash + 1) path.substring(dot).lowercase() else ""
        val mime = ICON_MIME[ext] ?: "image/png"
        "data:$mime;base64,${b64.encodeToString(bytes)}"
    } catch (e: Exception) {
        System.err.println("[zeromcp] Warning: failed to read icon file $icon: ${e.message}")
        null
    }
}
