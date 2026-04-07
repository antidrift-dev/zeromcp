package io.antidrift.zeromcp

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.runInterruptible
import kotlinx.coroutines.withTimeout
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
    private val schemas = mutableMapOf<String, JsonObject>()
    private val resources = mutableMapOf<String, ResourceDefinition>()
    private val templates = mutableMapOf<String, ResourceTemplateDefinition>()
    private val prompts = mutableMapOf<String, PromptDefinition>()
    private val subscriptions = mutableSetOf<String>()
    private val json = Json { ignoreUnknownKeys = true }
    private var logLevel: String = "info"
    private var clientCapabilities: JsonObject = JsonObject(emptyMap())

    /** Optional icon URI exposed on list entries. */
    var icon: String? = null

    /** Page size for paginated list responses. 0 = no pagination. */
    var pageSize: Int = 0

    /**
     * Register a tool using the DSL builder.
     */
    fun tool(name: String, block: ToolBuilder.() -> Unit) {
        val builder = ToolBuilder(name)
        builder.block()
        val tool = builder.build()
        validatePermissions(name, tool.permissions)
        tools[name] = tool
        schemas[name] = toJsonSchema(tool.input)
    }

    /**
     * Register a pre-built ToolDefinition.
     */
    fun register(tool: ToolDefinition) {
        validatePermissions(tool.name, tool.permissions)
        tools[tool.name] = tool
        schemas[tool.name] = toJsonSchema(tool.input)
    }

    /**
     * Register a resource using the DSL builder.
     */
    fun resource(name: String, block: ResourceBuilder.() -> Unit) {
        val builder = ResourceBuilder(name)
        builder.block()
        val res = builder.build()
        resources[name] = res
    }

    /**
     * Register a resource template using the DSL builder.
     */
    fun resourceTemplate(name: String, block: ResourceTemplateBuilder.() -> Unit) {
        val builder = ResourceTemplateBuilder(name)
        builder.block()
        val tmpl = builder.build()
        templates[name] = tmpl
    }

    /**
     * Register a prompt using the DSL builder.
     */
    fun prompt(name: String, block: PromptBuilder.() -> Unit) {
        val builder = PromptBuilder(name)
        builder.block()
        val prompt = builder.build()
        prompts[name] = prompt
    }

    /**
     * Start the stdio JSON-RPC server. Blocks until stdin closes.
     */
    fun serve() {
        System.err.println("[zeromcp] ${tools.size} tool(s), ${resources.size + templates.size} resource(s), ${prompts.size} prompt(s) registered")
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
                println(json.encodeToString(JsonObject.serializer(), response))
                System.out.flush()
            }
        }
    }

    /**
     * Process a single JSON-RPC request and return a response.
     * Returns null for notifications that require no response.
     *
     * Usage:
     * ```kotlin
     * val request = json.parseToJsonElement("""{"jsonrpc":"2.0","id":1,"method":"tools/list"}""").jsonObject
     * val response = server.handleRequest(request)
     * ```
     */
    suspend fun handleRequest(request: JsonObject): JsonObject? {
        val id = request["id"]
        val method = request["method"]?.jsonPrimitive?.content ?: ""
        val params = request["params"]?.jsonObject

        // Handle notifications (no id)
        if (id == null) {
            handleNotification(method, params)
            return null
        }

        val response = when (method) {
            "initialize" -> {
                if (params?.get("capabilities") is JsonObject) {
                    clientCapabilities = params["capabilities"]!!.jsonObject
                }
                buildResponse(id, buildJsonObject {
                    put("protocolVersion", "2024-11-05")
                    putJsonObject("capabilities") {
                        putJsonObject("tools") {
                            put("listChanged", true)
                        }
                        if (resources.isNotEmpty() || templates.isNotEmpty()) {
                            putJsonObject("resources") {
                                put("subscribe", true)
                                put("listChanged", true)
                            }
                        }
                        if (prompts.isNotEmpty()) {
                            putJsonObject("prompts") {
                                put("listChanged", true)
                            }
                        }
                        putJsonObject("logging") {}
                    }
                    putJsonObject("serverInfo") {
                        put("name", config.name)
                        put("version", config.version)
                    }
                })
            }

            "tools/list" -> {
                val cursor = params?.get("cursor")?.jsonPrimitive?.content
                val list = tools.map { (name, tool) ->
                    buildJsonObject {
                        put("name", name)
                        put("description", tool.description)
                        put("inputSchema", schemas[name]!!)
                        icon?.let { putJsonArray("icons") { addJsonObject { put("uri", it) } } }
                    }
                }
                val (items, nextCursor) = paginate(list, cursor, pageSize)
                buildResponse(id, buildJsonObject {
                    putJsonArray("tools") { items.forEach { add(it) } }
                    nextCursor?.let { put("nextCursor", it) }
                })
            }

            "tools/call" -> {
                val toolName = params?.get("name")?.jsonPrimitive?.content ?: ""
                val argsElement = params?.get("arguments")
                val argsMap = if (argsElement is JsonObject) argsElement.toArgMap() else emptyMap()
                buildResponse(id, callTool(toolName, argsMap))
            }

            "resources/list" -> {
                val cursor = params?.get("cursor")?.jsonPrimitive?.content
                val list = resources.map { (_, res) ->
                    buildJsonObject {
                        put("uri", res.uri)
                        put("name", res.name)
                        put("description", res.description)
                        put("mimeType", res.mimeType)
                        icon?.let { putJsonArray("icons") { addJsonObject { put("uri", it) } } }
                    }
                }
                val (items, nextCursor) = paginate(list, cursor, pageSize)
                buildResponse(id, buildJsonObject {
                    putJsonArray("resources") { items.forEach { add(it) } }
                    nextCursor?.let { put("nextCursor", it) }
                })
            }

            "resources/read" -> {
                val uri = params?.get("uri")?.jsonPrimitive?.content ?: ""
                handleResourcesRead(id, uri)
            }

            "resources/subscribe" -> {
                val uri = params?.get("uri")?.jsonPrimitive?.content
                if (uri != null) subscriptions.add(uri)
                buildResponse(id, JsonObject(emptyMap()))
            }

            "resources/templates/list" -> {
                val cursor = params?.get("cursor")?.jsonPrimitive?.content
                val list = templates.map { (_, tmpl) ->
                    buildJsonObject {
                        put("uriTemplate", tmpl.uriTemplate)
                        put("name", tmpl.name)
                        put("description", tmpl.description)
                        put("mimeType", tmpl.mimeType)
                        icon?.let { putJsonArray("icons") { addJsonObject { put("uri", it) } } }
                    }
                }
                val (items, nextCursor) = paginate(list, cursor, pageSize)
                buildResponse(id, buildJsonObject {
                    putJsonArray("resourceTemplates") { items.forEach { add(it) } }
                    nextCursor?.let { put("nextCursor", it) }
                })
            }

            "prompts/list" -> {
                val cursor = params?.get("cursor")?.jsonPrimitive?.content
                val list = prompts.map { (_, prompt) ->
                    buildJsonObject {
                        put("name", prompt.name)
                        prompt.description?.let { put("description", it) }
                        if (prompt.arguments.isNotEmpty()) {
                            putJsonArray("arguments") {
                                for (arg in prompt.arguments) {
                                    addJsonObject {
                                        put("name", arg.name)
                                        arg.description?.let { put("description", it) }
                                        put("required", arg.required)
                                    }
                                }
                            }
                        }
                        icon?.let { putJsonArray("icons") { addJsonObject { put("uri", it) } } }
                    }
                }
                val (items, nextCursor) = paginate(list, cursor, pageSize)
                buildResponse(id, buildJsonObject {
                    putJsonArray("prompts") { items.forEach { add(it) } }
                    nextCursor?.let { put("nextCursor", it) }
                })
            }

            "prompts/get" -> {
                val promptName = params?.get("name")?.jsonPrimitive?.content ?: ""
                val argsElement = params?.get("arguments")
                val argsMap = if (argsElement is JsonObject) argsElement.toArgMap() else emptyMap()
                handlePromptsGet(id, promptName, argsMap)
            }

            "logging/setLevel" -> {
                val level = params?.get("level")?.jsonPrimitive?.content
                if (level != null) logLevel = level
                buildResponse(id, JsonObject(emptyMap()))
            }

            "completion/complete" -> {
                buildResponse(id, buildJsonObject {
                    putJsonObject("completion") {
                        putJsonArray("values") {}
                    }
                })
            }

            "ping" -> buildResponse(id, JsonObject(emptyMap()))

            else -> {
                buildErrorResponse(id, -32601, "Method not found: $method")
            }
        }

        return response
    }

    private suspend fun callTool(name: String, args: Map<String, Any?>): JsonObject {
        val tool = tools[name] ?: return buildToolResult("Unknown tool: $name", isError = true)

        val schema = schemas[name]!!
        val errors = validate(args, schema)
        if (errors.isNotEmpty()) {
            return buildToolResult("Validation errors:\n${errors.joinToString("\n")}", isError = true)
        }

        // Tool-level timeout overrides config default
        val timeoutMs = if (tool.permissions.executeTimeout > 0) tool.permissions.executeTimeout
                        else config.execute_timeout

        return try {
            val ctx = Ctx(toolName = name, permissions = tool.permissions)
            val result = withTimeout(timeoutMs) {
                runInterruptible(Dispatchers.IO) {
                    runBlocking { tool.execute(args, ctx) }
                }
            }
            val text = when (result) {
                is String -> result
                null -> "null"
                else -> json.encodeToString(JsonElement.serializer(), toJsonElement(result))
            }
            buildToolResult(text)
        } catch (e: kotlinx.coroutines.TimeoutCancellationException) {
            buildToolResult("Tool \"$name\" timed out after ${timeoutMs}ms", isError = true)
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

    private fun handleNotification(method: String, params: JsonObject?) {
        when (method) {
            "notifications/initialized" -> { /* no-op */ }
            "notifications/roots/list_changed" -> { /* accepted but unused */ }
        }
    }

    private suspend fun handleResourcesRead(id: JsonElement?, uri: String): JsonObject {
        // Check static resources
        for ((_, res) in resources) {
            if (res.uri == uri) {
                return try {
                    val text = res.read()
                    buildResponse(id, buildJsonObject {
                        putJsonArray("contents") {
                            addJsonObject {
                                put("uri", uri)
                                put("mimeType", res.mimeType)
                                put("text", text)
                            }
                        }
                    })
                } catch (e: Exception) {
                    buildErrorResponse(id, -32603, "Error reading resource: ${e.message}")
                }
            }
        }

        // Check templates
        for ((_, tmpl) in templates) {
            val match = matchTemplate(tmpl.uriTemplate, uri)
            if (match != null) {
                return try {
                    val text = tmpl.read(match)
                    buildResponse(id, buildJsonObject {
                        putJsonArray("contents") {
                            addJsonObject {
                                put("uri", uri)
                                put("mimeType", tmpl.mimeType)
                                put("text", text)
                            }
                        }
                    })
                } catch (e: Exception) {
                    buildErrorResponse(id, -32603, "Error reading resource: ${e.message}")
                }
            }
        }

        return buildErrorResponse(id, -32002, "Resource not found: $uri")
    }

    private suspend fun handlePromptsGet(id: JsonElement?, name: String, args: Map<String, Any?>): JsonObject {
        val prompt = prompts[name]
            ?: return buildErrorResponse(id, -32002, "Prompt not found: $name")

        return try {
            val messages = prompt.render(args)
            buildResponse(id, buildJsonObject {
                putJsonArray("messages") {
                    for (msg in messages) {
                        addJsonObject {
                            put("role", msg.role)
                            putJsonObject("content") {
                                put("type", msg.content.type)
                                put("text", msg.content.text)
                            }
                        }
                    }
                }
            })
        } catch (e: Exception) {
            buildErrorResponse(id, -32603, "Error rendering prompt: ${e.message}")
        }
    }
}

// --- Pagination (base64 cursor) ---

private data class PaginatedResult<T>(val items: List<T>, val nextCursor: String?)

private fun <T> paginate(items: List<T>, cursor: String?, pageSize: Int): PaginatedResult<T> {
    if (pageSize <= 0) return PaginatedResult(items, null)
    val offset = if (cursor != null) decodeCursor(cursor) else 0
    val slice = items.subList(offset.coerceAtMost(items.size), (offset + pageSize).coerceAtMost(items.size))
    val hasMore = offset + pageSize < items.size
    return PaginatedResult(slice, if (hasMore) encodeCursor(offset + pageSize) else null)
}

private fun encodeCursor(offset: Int): String =
    java.util.Base64.getEncoder().encodeToString(offset.toString().toByteArray())

private fun decodeCursor(cursor: String): Int =
    try { String(java.util.Base64.getDecoder().decode(cursor)).toInt() } catch (_: Exception) { 0 }

// --- URI template matching ---

private fun matchTemplate(template: String, uri: String): Map<String, String>? {
    val regex = template.replace(Regex("\\{(\\w+)}")) { "(?<${it.groupValues[1]}>[^/]+)" }
    val match = Regex("^$regex$").matchEntire(uri) ?: return null
    val groups = mutableMapOf<String, String>()
    // Extract named groups from the template
    val nameRegex = Regex("\\{(\\w+)}")
    for (m in nameRegex.findAll(template)) {
        val name = m.groupValues[1]
        val value = match.groups[name]?.value ?: continue
        groups[name] = value
    }
    return if (groups.isNotEmpty()) groups else null
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
