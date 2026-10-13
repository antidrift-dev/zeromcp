package io.antidrift.zeromcp

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.*
import java.net.URI
import java.net.http.HttpClient
import java.net.http.HttpRequest
import java.net.http.HttpResponse

/**
 * Federates tools from remote MCP servers over HTTP. Port of nodejs/src/remote.ts.
 */
internal class RemoteManager {
    private val client: HttpClient = HttpClient.newHttpClient()
    private val json = Json { ignoreUnknownKeys = true }

    /** Connects each server in order; returns namespaced tools in insertion order. */
    suspend fun connect(servers: List<RemoteServer>): LinkedHashMap<String, ToolDefinition> {
        val allTools = LinkedHashMap<String, ToolDefinition>()

        for (server in servers) {
            try {
                val tools = connectOne(server)
                for ((toolName, tool) in tools) {
                    val namespaced = "${server.name}.$toolName"
                    allTools[namespaced] = tool.copy(name = namespaced)
                    System.err.println("[mcp] Remote tool: $namespaced")
                }
            } catch (e: Exception) {
                System.err.println("[mcp] Failed to connect to ${server.name}: ${e.message}")
            }
        }

        return allTools
    }

    private suspend fun connectOne(server: RemoteServer): LinkedHashMap<String, ToolDefinition> {
        if (!server.url.startsWith("http://") && !server.url.startsWith("https://")) {
            throw IllegalArgumentException("Remote server \"${server.name}\" must have an HTTP/HTTPS URL, got: ${server.url}")
        }
        return connectHttp(server)
    }

    private suspend fun connectHttp(server: RemoteServer): LinkedHashMap<String, ToolDefinition> {
        val tools = LinkedHashMap<String, ToolDefinition>()
        val auth = resolveAuth(server.auth)

        // Initialize (result ignored)
        httpRpc(server.url, rpc(1, "initialize", JsonObject(emptyMap())), auth)

        // List tools
        val listRes = httpRpc(server.url, rpc(2, "tools/list", JsonObject(emptyMap())), auth)
        val listed = ((listRes["result"] as? JsonObject)?.get("tools") as? JsonArray) ?: JsonArray(emptyList())

        val remoteTools = listed.map { it.jsonObject }
            .filter { t -> server.tools == null || t.str("name") in server.tools }

        for (rt in remoteTools) {
            val upstreamName = rt.str("name") ?: continue
            val input = schemaToInput(rt["inputSchema"] as? JsonObject)
            tools[upstreamName] = ToolDefinition(
                name = upstreamName,
                description = rt.str("description") ?: "",
                input = input,
                permissions = Permissions(),
                route = null,
                execute = { args, _ ->
                    val callRes = httpRpc(server.url, buildJsonObject {
                        put("jsonrpc", "2.0")
                        put("id", System.currentTimeMillis())
                        put("method", "tools/call")
                        putJsonObject("params") {
                            put("name", upstreamName)
                            put("arguments", toJsonElement(args))
                        }
                    }, auth)

                    val result = callRes["result"]
                    val text = ((result as? JsonObject)?.get("content") as? JsonArray)
                        ?.firstOrNull()?.let { (it as? JsonObject)?.get("text") }
                        ?.let { (it as? JsonPrimitive)?.takeIf { p -> p.isString }?.content }
                    if (!text.isNullOrEmpty()) text
                    else result?.let { jsonElementToAny(it) }
                }
            )
        }

        System.err.println("[mcp] Connected to ${server.name} (HTTP): ${tools.size} tool(s)")
        return tools
    }

    private fun rpc(id: Int, method: String, params: JsonObject): JsonObject = buildJsonObject {
        put("jsonrpc", "2.0")
        put("id", id)
        put("method", method)
        put("params", params)
    }

    private suspend fun httpRpc(url: String, body: JsonObject, auth: String?): JsonObject {
        val builder = HttpRequest.newBuilder(URI(url))
            .header("Content-Type", "application/json")
            .POST(HttpRequest.BodyPublishers.ofString(json.encodeToString(JsonObject.serializer(), body)))
        if (!auth.isNullOrEmpty()) builder.header("Authorization", "Bearer $auth")

        val res = withContext(Dispatchers.IO) {
            client.send(builder.build(), HttpResponse.BodyHandlers.ofString())
        }
        if (res.statusCode() !in 200..299) throw RuntimeException("HTTP ${res.statusCode()}")
        return json.parseToJsonElement(res.body()).jsonObject
    }

    private fun schemaToInput(schema: JsonObject?): InputSchema {
        val input = LinkedHashMap<String, InputField>()
        val properties = schema?.get("properties") as? JsonObject ?: return input
        val required = (schema["required"] as? JsonArray)
            ?.mapNotNull { (it as? JsonPrimitive)?.content }?.toSet() ?: emptySet()

        for ((key, prop) in properties) {
            val p = prop as? JsonObject
            val rawType = p?.get("type")
            val typeName = when {
                rawType == null || rawType is JsonNull -> "string"
                rawType is JsonPrimitive -> rawType.content.ifEmpty { "string" }
                else -> rawType.toString()
            }
            input[key] = InputField(
                type = SimpleType.fromString(typeName),
                description = p?.str("description")?.ifEmpty { null },
                optional = key !in required
            )
        }
        return input
    }

    private fun JsonObject.str(key: String): String? =
        (this[key] as? JsonPrimitive)?.takeIf { it !is JsonNull }?.content
}
