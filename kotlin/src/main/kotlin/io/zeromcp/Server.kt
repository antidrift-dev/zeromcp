package io.zeromcp

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*

/**
 * ZeroMcp — zero-config MCP runtime for Kotlin.
 *
 * Usage:
 * ```kotlin
 * val server = ZeroMcp()
 * server.tool("hello") {
 *     description = "Say hello"
 *     input { "name" to "string" }
 *     execute { args, ctx -> "Hello, ${args.getString("name")}!" }
 * }
 * server.serve()
 * ```
 */
class ZeroMcp(private val config: ZeroMcpConfig = loadConfig()) {

    private val tools = mutableMapOf<String, ToolDefinition>()
    private val json = Json { ignoreUnknownKeys = true }

    /**
     * Register a tool using the DSL builder.
     */
    fun tool(name: String, block: ToolBuilder.() -> Unit) {
        val builder = ToolBuilder(name)
        builder.block()
        val tool = builder.build()
        validatePermissions(name, tool.permissions)
        tools[name] = tool
    }

    /**
     * Register a pre-built ToolDefinition.
     */
    fun register(tool: ToolDefinition) {
        validatePermissions(tool.name, tool.permissions)
        tools[tool.name] = tool
    }

    /**
     * Start the stdio JSON-RPC server. Blocks until stdin closes.
     */
    fun serve() {
        System.err.println("[zeromcp] ${tools.size} tool(s) registered")
        System.err.println("[zeromcp] stdio transport ready")

        val reader = System.`in`.bufferedReader()

        while (true) {
            val line = reader.readLine() ?: break
            if (line.isBlank()) continue

            val request = try {
                json.parseToJsonElement(line).jsonObject
            } catch (e: Exception) {
                continue
            }

            val response = runBlocking { handleRequest(request) }
            if (response != null) {
                println(response)
                System.out.flush()
            }
        }
    }

    private suspend fun handleRequest(request: JsonObject): String? {
        val id = request["id"]
        val method = request["method"]?.jsonPrimitive?.content ?: ""
        val params = request["params"]?.jsonObject

        // Notification — no response needed
        if (id == null && method == "notifications/initialized") return null

        val response = when (method) {
            "initialize" -> buildResponse(id, buildJsonObject {
                put("protocolVersion", "2024-11-05")
                putJsonObject("capabilities") {
                    putJsonObject("tools") {
                        put("listChanged", true)
                    }
                }
                putJsonObject("serverInfo") {
                    put("name", config.name)
                    put("version", config.version)
                }
            })

            "tools/list" -> buildResponse(id, buildJsonObject {
                putJsonArray("tools") {
                    for ((name, tool) in tools) {
                        addJsonObject {
                            put("name", name)
                            put("description", tool.description)
                            put("inputSchema", toJsonSchema(tool.input))
                        }
                    }
                }
            })

            "tools/call" -> {
                val toolName = params?.get("name")?.jsonPrimitive?.content ?: ""
                val args = params?.get("arguments")?.jsonObject
                val argsMap = args?.toArgMap() ?: emptyMap()
                buildResponse(id, callTool(toolName, argsMap))
            }

            "ping" -> buildResponse(id, JsonObject(emptyMap()))

            else -> {
                if (id == null) return null
                buildErrorResponse(id, -32601, "Method not found: $method")
            }
        }

        return json.encodeToString(JsonObject.serializer(), response)
    }

    private suspend fun callTool(name: String, args: Map<String, Any?>): JsonObject {
        val tool = tools[name] ?: return buildToolResult("Unknown tool: $name", isError = true)

        val schema = toJsonSchema(tool.input)
        val errors = validate(args, schema)
        if (errors.isNotEmpty()) {
            return buildToolResult("Validation errors:\n${errors.joinToString("\n")}", isError = true)
        }

        return try {
            val ctx = Ctx(toolName = name, permissions = tool.permissions)
            val result = tool.execute(args, ctx)
            val text = when (result) {
                is String -> result
                null -> "null"
                else -> json.encodeToString(JsonElement.serializer(), toJsonElement(result))
            }
            buildToolResult(text)
        } catch (e: Exception) {
            buildToolResult("Error: ${e.message}", isError = true)
        }
    }

    private fun buildToolResult(text: String, isError: Boolean = false): JsonObject {
        return buildJsonObject {
            putJsonArray("content") {
                addJsonObject {
                    put("type", "text")
                    put("text", text)
                }
            }
            if (isError) put("isError", true)
        }
    }

    private fun buildResponse(id: JsonElement?, result: JsonObject): JsonObject {
        return buildJsonObject {
            put("jsonrpc", "2.0")
            id?.let { put("id", it) }
            put("result", result)
        }
    }

    private fun buildErrorResponse(id: JsonElement?, code: Int, message: String): JsonObject {
        return buildJsonObject {
            put("jsonrpc", "2.0")
            id?.let { put("id", it) }
            putJsonObject("error") {
                put("code", code)
                put("message", message)
            }
        }
    }
}

private fun JsonObject.toArgMap(): Map<String, Any?> {
    val map = mutableMapOf<String, Any?>()
    for ((key, element) in this) {
        map[key] = jsonElementToAny(element)
    }
    return map
}

private fun jsonElementToAny(element: JsonElement): Any? = when (element) {
    is JsonNull -> null
    is JsonPrimitive -> {
        when {
            element.isString -> element.content
            element.booleanOrNull != null -> element.boolean
            element.doubleOrNull != null -> {
                val d = element.double
                if (d == d.toLong().toDouble()) d.toLong() else d
            }
            else -> element.content
        }
    }
    is JsonArray -> element.map { jsonElementToAny(it) }
    is JsonObject -> element.toArgMap()
}

private fun toJsonElement(value: Any?): JsonElement = when (value) {
    null -> JsonNull
    is String -> JsonPrimitive(value)
    is Number -> JsonPrimitive(value)
    is Boolean -> JsonPrimitive(value)
    is Map<*, *> -> JsonObject(value.entries.associate { (k, v) -> k.toString() to toJsonElement(v) })
    is List<*> -> JsonArray(value.map { toJsonElement(it) })
    else -> JsonPrimitive(value.toString())
}
