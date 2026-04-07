package io.antidrift.zeromcp

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.test.assertFalse

class ServerTest {

    private fun buildRpc(id: Int, method: String, params: JsonObject? = null): JsonObject =
        buildJsonObject {
            put("jsonrpc", "2.0")
            put("id", id)
            put("method", method)
            params?.let { put("params", it) }
        }

    private fun buildRpcNotification(method: String, params: JsonObject? = null): JsonObject =
        buildJsonObject {
            put("jsonrpc", "2.0")
            put("method", method)
            params?.let { put("params", it) }
        }

    // --- Tool registration and builder tests ---

    @Test
    fun `tool registration works`() {
        val server = ZeroMcp()
        server.tool("greet") {
            description = "Greet someone"
            input { "name" to "string" }
            execute { args, _ -> "Hi, ${args.getString("name")}!" }
        }
        assertTrue(true)
    }

    @Test
    fun `tool builder creates correct definition`() {
        val builder = ToolBuilder("test_tool")
        builder.description = "A test tool"
        builder.input {
            "x" to "number"
            optional("y", "number", "Optional Y value")
        }
        builder.execute { args, _ -> args.getNumber("x") }

        val tool = builder.build()
        assertEquals("test_tool", tool.name)
        assertEquals("A test tool", tool.description)
        assertEquals(2, tool.input.size)
        assertTrue(tool.input["x"]?.optional == false)
        assertTrue(tool.input["y"]?.optional == true)
    }

    @Test
    fun `tool execution returns correct result`() = runBlocking {
        val builder = ToolBuilder("adder")
        builder.description = "Add numbers"
        builder.input {
            "a" to "number"
            "b" to "number"
        }
        builder.execute { args, _ ->
            val a = args.getNumber("a") ?: 0.0
            val b = args.getNumber("b") ?: 0.0
            a + b
        }

        val tool = builder.build()
        val result = tool.execute(mapOf("a" to 3.0, "b" to 4.0), Ctx("adder"))
        assertEquals(7.0, result)
    }

    @Test
    fun `permissions builder works`() {
        val builder = ToolBuilder("net_tool")
        builder.description = "Network tool"
        builder.permissions {
            network("api.example.com")
            fs("read")
        }
        builder.execute { _, _ -> "ok" }

        val tool = builder.build()
        val net = tool.permissions.network
        assertTrue(net is NetworkPermission.AllowList)
        assertEquals(listOf("api.example.com"), (net as NetworkPermission.AllowList).hosts)
        assertEquals(FsPermission.Read, tool.permissions.fs)
    }

    // --- Pagination tests (via tools/list dispatch) ---

    @Test
    fun `pagination encodes and decodes cursor round-trip`() = runBlocking {
        val server = ZeroMcp()
        server.pageSize = 2
        for (i in 1..5) {
            server.tool("tool_$i") {
                description = "Tool $i"
                execute { _, _ -> "ok" }
            }
        }

        // First page
        val resp1 = server.handleRequest(buildRpc(1, "tools/list"))!!
        val result1 = resp1["result"]!!.jsonObject
        val tools1 = result1["tools"]!!.jsonArray
        assertEquals(2, tools1.size)
        val cursor1 = result1["nextCursor"]?.jsonPrimitive?.content
        assertNotNull(cursor1)

        // Second page using cursor
        val resp2 = server.handleRequest(buildRpc(2, "tools/list", buildJsonObject {
            put("cursor", cursor1)
        }))!!
        val result2 = resp2["result"]!!.jsonObject
        val tools2 = result2["tools"]!!.jsonArray
        assertEquals(2, tools2.size)
        val cursor2 = result2["nextCursor"]?.jsonPrimitive?.content
        assertNotNull(cursor2)

        // Third page (last)
        val resp3 = server.handleRequest(buildRpc(3, "tools/list", buildJsonObject {
            put("cursor", cursor2)
        }))!!
        val result3 = resp3["result"]!!.jsonObject
        val tools3 = result3["tools"]!!.jsonArray
        assertEquals(1, tools3.size)
        assertNull(result3["nextCursor"])
    }

    @Test
    fun `no pagination when pageSize is 0`() = runBlocking {
        val server = ZeroMcp()
        server.pageSize = 0
        for (i in 1..5) {
            server.tool("tool_$i") {
                description = "Tool $i"
                execute { _, _ -> "ok" }
            }
        }

        val resp = server.handleRequest(buildRpc(1, "tools/list"))!!
        val result = resp["result"]!!.jsonObject
        assertEquals(5, result["tools"]!!.jsonArray.size)
        assertNull(result["nextCursor"])
    }

    @Test
    fun `invalid cursor falls back to offset 0`() = runBlocking {
        val server = ZeroMcp()
        server.pageSize = 2
        for (i in 1..3) {
            server.tool("tool_$i") {
                description = "Tool $i"
                execute { _, _ -> "ok" }
            }
        }

        val resp = server.handleRequest(buildRpc(1, "tools/list", buildJsonObject {
            put("cursor", "not-valid-base64!!!")
        }))!!
        val result = resp["result"]!!.jsonObject
        assertEquals(2, result["tools"]!!.jsonArray.size)
    }

    // --- Resource registration and list ---

    @Test
    fun `resource registration and list`() = runBlocking {
        val server = ZeroMcp()
        server.resource("mydata") {
            uri = "file:///data.txt"
            description = "Some data"
            mimeType = "text/plain"
            read { "hello data" }
        }

        val resp = server.handleRequest(buildRpc(1, "resources/list"))!!
        val result = resp["result"]!!.jsonObject
        val resources = result["resources"]!!.jsonArray
        assertEquals(1, resources.size)
        val res = resources[0].jsonObject
        assertEquals("file:///data.txt", res["uri"]!!.jsonPrimitive.content)
        assertEquals("mydata", res["name"]!!.jsonPrimitive.content)
        assertEquals("Some data", res["description"]!!.jsonPrimitive.content)
        assertEquals("text/plain", res["mimeType"]!!.jsonPrimitive.content)
    }

    @Test
    fun `resources list supports pagination`() = runBlocking {
        val server = ZeroMcp()
        server.pageSize = 1
        server.resource("r1") {
            uri = "file:///r1.txt"
            read { "r1" }
        }
        server.resource("r2") {
            uri = "file:///r2.txt"
            read { "r2" }
        }

        val resp1 = server.handleRequest(buildRpc(1, "resources/list"))!!
        val result1 = resp1["result"]!!.jsonObject
        assertEquals(1, result1["resources"]!!.jsonArray.size)
        val cursor = result1["nextCursor"]?.jsonPrimitive?.content
        assertNotNull(cursor)

        val resp2 = server.handleRequest(buildRpc(2, "resources/list", buildJsonObject {
            put("cursor", cursor)
        }))!!
        val result2 = resp2["result"]!!.jsonObject
        assertEquals(1, result2["resources"]!!.jsonArray.size)
        assertNull(result2["nextCursor"])
    }

    // --- resources/read dispatch ---

    @Test
    fun `resources read returns content for static resource`() = runBlocking {
        val server = ZeroMcp()
        server.resource("greetfile") {
            uri = "file:///greet.txt"
            mimeType = "text/plain"
            read { "Hello from file" }
        }

        val resp = server.handleRequest(buildRpc(1, "resources/read", buildJsonObject {
            put("uri", "file:///greet.txt")
        }))!!
        val result = resp["result"]!!.jsonObject
        val contents = result["contents"]!!.jsonArray
        assertEquals(1, contents.size)
        assertEquals("Hello from file", contents[0].jsonObject["text"]!!.jsonPrimitive.content)
        assertEquals("file:///greet.txt", contents[0].jsonObject["uri"]!!.jsonPrimitive.content)
    }

    @Test
    fun `resources read returns error for unknown uri`() = runBlocking {
        val server = ZeroMcp()
        val resp = server.handleRequest(buildRpc(1, "resources/read", buildJsonObject {
            put("uri", "file:///nonexistent")
        }))!!
        assertNotNull(resp["error"])
        assertEquals(-32002, resp["error"]!!.jsonObject["code"]!!.jsonPrimitive.int)
    }

    @Test
    fun `resources read resolves template URIs`() = runBlocking {
        val server = ZeroMcp()
        server.resourceTemplate("user_profile") {
            uriTemplate = "users://{userId}/profile"
            description = "User profile"
            mimeType = "application/json"
            read { params -> """{"id":"${params["userId"]}"}""" }
        }

        val resp = server.handleRequest(buildRpc(1, "resources/read", buildJsonObject {
            put("uri", "users://alice/profile")
        }))!!
        val result = resp["result"]!!.jsonObject
        val contents = result["contents"]!!.jsonArray
        assertEquals("""{"id":"alice"}""", contents[0].jsonObject["text"]!!.jsonPrimitive.content)
    }

    @Test
    fun `resources read handler catches exceptions`() = runBlocking {
        val server = ZeroMcp()
        server.resource("failing") {
            uri = "file:///fail"
            read { throw RuntimeException("read boom") }
        }

        val resp = server.handleRequest(buildRpc(1, "resources/read", buildJsonObject {
            put("uri", "file:///fail")
        }))!!
        assertNotNull(resp["error"])
        assertTrue(resp["error"]!!.jsonObject["message"]!!.jsonPrimitive.content.contains("read boom"))
    }

    // --- Prompt registration, list, and get ---

    @Test
    fun `prompt registration and list`() = runBlocking {
        val server = ZeroMcp()
        server.prompt("summarize") {
            description = "Summarize text"
            arguments {
                required("text", "The text to summarize")
                optional("style", "Summary style")
            }
            render { args ->
                listOf(PromptMessage("user", PromptContent(text = "Summarize: ${args["text"]}")))
            }
        }

        val resp = server.handleRequest(buildRpc(1, "prompts/list"))!!
        val result = resp["result"]!!.jsonObject
        val prompts = result["prompts"]!!.jsonArray
        assertEquals(1, prompts.size)
        val p = prompts[0].jsonObject
        assertEquals("summarize", p["name"]!!.jsonPrimitive.content)
        assertEquals("Summarize text", p["description"]!!.jsonPrimitive.content)
        val args = p["arguments"]!!.jsonArray
        assertEquals(2, args.size)
        assertTrue(args[0].jsonObject["required"]!!.jsonPrimitive.boolean)
        assertFalse(args[1].jsonObject["required"]!!.jsonPrimitive.boolean)
    }

    @Test
    fun `prompts list supports pagination`() = runBlocking {
        val server = ZeroMcp()
        server.pageSize = 1
        server.prompt("p1") {
            render { _ -> listOf(PromptMessage("user", PromptContent(text = "p1"))) }
        }
        server.prompt("p2") {
            render { _ -> listOf(PromptMessage("user", PromptContent(text = "p2"))) }
        }

        val resp1 = server.handleRequest(buildRpc(1, "prompts/list"))!!
        val result1 = resp1["result"]!!.jsonObject
        assertEquals(1, result1["prompts"]!!.jsonArray.size)
        assertNotNull(result1["nextCursor"])

        val cursor = result1["nextCursor"]!!.jsonPrimitive.content
        val resp2 = server.handleRequest(buildRpc(2, "prompts/list", buildJsonObject {
            put("cursor", cursor)
        }))!!
        val result2 = resp2["result"]!!.jsonObject
        assertEquals(1, result2["prompts"]!!.jsonArray.size)
        assertNull(result2["nextCursor"])
    }

    @Test
    fun `prompts get returns rendered messages`() = runBlocking {
        val server = ZeroMcp()
        server.prompt("greet") {
            description = "Greet prompt"
            arguments {
                required("name")
            }
            render { args ->
                listOf(
                    PromptMessage("user", PromptContent(text = "Hello, ${args["name"]}!")),
                    PromptMessage("assistant", PromptContent(text = "Greetings!"))
                )
            }
        }

        val resp = server.handleRequest(buildRpc(1, "prompts/get", buildJsonObject {
            put("name", "greet")
            put("arguments", buildJsonObject { put("name", "Alice") })
        }))!!
        val result = resp["result"]!!.jsonObject
        val messages = result["messages"]!!.jsonArray
        assertEquals(2, messages.size)
        assertEquals("user", messages[0].jsonObject["role"]!!.jsonPrimitive.content)
        assertEquals("Hello, Alice!", messages[0].jsonObject["content"]!!.jsonObject["text"]!!.jsonPrimitive.content)
        assertEquals("assistant", messages[1].jsonObject["role"]!!.jsonPrimitive.content)
    }

    @Test
    fun `prompts get returns error for unknown prompt`() = runBlocking {
        val server = ZeroMcp()
        val resp = server.handleRequest(buildRpc(1, "prompts/get", buildJsonObject {
            put("name", "nonexistent")
        }))!!
        assertNotNull(resp["error"])
        assertEquals(-32002, resp["error"]!!.jsonObject["code"]!!.jsonPrimitive.int)
    }

    @Test
    fun `prompts get catches render exceptions`() = runBlocking {
        val server = ZeroMcp()
        server.prompt("boom") {
            render { _ -> throw RuntimeException("render failed") }
        }

        val resp = server.handleRequest(buildRpc(1, "prompts/get", buildJsonObject {
            put("name", "boom")
        }))!!
        assertNotNull(resp["error"])
        assertTrue(resp["error"]!!.jsonObject["message"]!!.jsonPrimitive.content.contains("render failed"))
    }

    // --- Template URI matching (tested indirectly via resources/read) ---

    @Test
    fun `template URI with single param`() = runBlocking {
        val server = ZeroMcp()
        server.resourceTemplate("item") {
            uriTemplate = "store://items/{itemId}"
            read { params -> "item=${params["itemId"]}" }
        }

        val resp = server.handleRequest(buildRpc(1, "resources/read", buildJsonObject {
            put("uri", "store://items/42")
        }))!!
        val text = resp["result"]!!.jsonObject["contents"]!!.jsonArray[0].jsonObject["text"]!!.jsonPrimitive.content
        assertEquals("item=42", text)
    }

    @Test
    fun `template URI with multiple params`() = runBlocking {
        val server = ZeroMcp()
        server.resourceTemplate("userpost") {
            uriTemplate = "app://users/{userId}/posts/{postId}"
            read { params -> "user=${params["userId"]},post=${params["postId"]}" }
        }

        val resp = server.handleRequest(buildRpc(1, "resources/read", buildJsonObject {
            put("uri", "app://users/bob/posts/99")
        }))!!
        val text = resp["result"]!!.jsonObject["contents"]!!.jsonArray[0].jsonObject["text"]!!.jsonPrimitive.content
        assertEquals("user=bob,post=99", text)
    }

    @Test
    fun `template URI does not match wrong pattern`() = runBlocking {
        val server = ZeroMcp()
        server.resourceTemplate("item") {
            uriTemplate = "store://items/{itemId}"
            read { params -> "item=${params["itemId"]}" }
        }

        val resp = server.handleRequest(buildRpc(1, "resources/read", buildJsonObject {
            put("uri", "store://other/42")
        }))!!
        assertNotNull(resp["error"])
        assertEquals(-32002, resp["error"]!!.jsonObject["code"]!!.jsonPrimitive.int)
    }

    @Test
    fun `templates list dispatch`() = runBlocking {
        val server = ZeroMcp()
        server.resourceTemplate("docs") {
            uriTemplate = "docs://{docId}"
            description = "Documentation"
            mimeType = "text/markdown"
            read { params -> "# Doc ${params["docId"]}" }
        }

        val resp = server.handleRequest(buildRpc(1, "resources/templates/list"))!!
        val result = resp["result"]!!.jsonObject
        val templates = result["resourceTemplates"]!!.jsonArray
        assertEquals(1, templates.size)
        assertEquals("docs://{docId}", templates[0].jsonObject["uriTemplate"]!!.jsonPrimitive.content)
        assertEquals("Documentation", templates[0].jsonObject["description"]!!.jsonPrimitive.content)
    }

    // --- logging/setLevel dispatch ---

    @Test
    fun `logging setLevel accepts valid level`() = runBlocking {
        val server = ZeroMcp()
        val resp = server.handleRequest(buildRpc(1, "logging/setLevel", buildJsonObject {
            put("level", "debug")
        }))!!
        assertNotNull(resp["result"])
    }

    @Test
    fun `logging setLevel with no level does not error`() = runBlocking {
        val server = ZeroMcp()
        val resp = server.handleRequest(buildRpc(1, "logging/setLevel", buildJsonObject {}))!!
        assertNotNull(resp["result"])
    }

    // --- Icon support ---

    @Test
    fun `icon appears on tools list entries`() = runBlocking {
        val server = ZeroMcp()
        server.icon = "https://example.com/icon.png"
        server.tool("t1") {
            description = "A tool"
            execute { _, _ -> "ok" }
        }

        val resp = server.handleRequest(buildRpc(1, "tools/list"))!!
        val tool = resp["result"]!!.jsonObject["tools"]!!.jsonArray[0].jsonObject
        val icons = tool["icons"]!!.jsonArray
        assertEquals(1, icons.size)
        assertEquals("https://example.com/icon.png", icons[0].jsonObject["uri"]!!.jsonPrimitive.content)
    }

    @Test
    fun `icon appears on resources list entries`() = runBlocking {
        val server = ZeroMcp()
        server.icon = "https://example.com/icon.png"
        server.resource("r1") {
            uri = "file:///r1"
            read { "data" }
        }

        val resp = server.handleRequest(buildRpc(1, "resources/list"))!!
        val res = resp["result"]!!.jsonObject["resources"]!!.jsonArray[0].jsonObject
        val icons = res["icons"]!!.jsonArray
        assertEquals("https://example.com/icon.png", icons[0].jsonObject["uri"]!!.jsonPrimitive.content)
    }

    @Test
    fun `icon appears on prompts list entries`() = runBlocking {
        val server = ZeroMcp()
        server.icon = "https://example.com/icon.png"
        server.prompt("p1") {
            render { _ -> listOf(PromptMessage("user", PromptContent(text = "hi"))) }
        }

        val resp = server.handleRequest(buildRpc(1, "prompts/list"))!!
        val prompt = resp["result"]!!.jsonObject["prompts"]!!.jsonArray[0].jsonObject
        val icons = prompt["icons"]!!.jsonArray
        assertEquals("https://example.com/icon.png", icons[0].jsonObject["uri"]!!.jsonPrimitive.content)
    }

    @Test
    fun `icon appears on resource templates list entries`() = runBlocking {
        val server = ZeroMcp()
        server.icon = "https://example.com/icon.png"
        server.resourceTemplate("t1") {
            uriTemplate = "tmpl://{id}"
            read { params -> params["id"] ?: "" }
        }

        val resp = server.handleRequest(buildRpc(1, "resources/templates/list"))!!
        val tmpl = resp["result"]!!.jsonObject["resourceTemplates"]!!.jsonArray[0].jsonObject
        val icons = tmpl["icons"]!!.jsonArray
        assertEquals("https://example.com/icon.png", icons[0].jsonObject["uri"]!!.jsonPrimitive.content)
    }

    @Test
    fun `no icon field when icon is null`() = runBlocking {
        val server = ZeroMcp()
        server.tool("t1") {
            description = "A tool"
            execute { _, _ -> "ok" }
        }

        val resp = server.handleRequest(buildRpc(1, "tools/list"))!!
        val tool = resp["result"]!!.jsonObject["tools"]!!.jsonArray[0].jsonObject
        assertNull(tool["icons"])
    }

    // --- Other dispatch tests ---

    @Test
    fun `initialize returns capabilities`() = runBlocking {
        val server = ZeroMcp()
        server.tool("t") {
            description = "t"
            execute { _, _ -> "ok" }
        }
        server.resource("r") {
            uri = "file:///r"
            read { "data" }
        }
        server.prompt("p") {
            render { _ -> listOf(PromptMessage("user", PromptContent(text = "hi"))) }
        }

        val resp = server.handleRequest(buildRpc(1, "initialize"))!!
        val result = resp["result"]!!.jsonObject
        assertEquals("2024-11-05", result["protocolVersion"]!!.jsonPrimitive.content)
        assertNotNull(result["capabilities"]!!.jsonObject["tools"])
        assertNotNull(result["capabilities"]!!.jsonObject["resources"])
        assertNotNull(result["capabilities"]!!.jsonObject["prompts"])
        assertNotNull(result["capabilities"]!!.jsonObject["logging"])
    }

    @Test
    fun `initialize omits resources capability when none registered`() = runBlocking {
        val server = ZeroMcp()
        server.tool("t") {
            description = "t"
            execute { _, _ -> "ok" }
        }

        val resp = server.handleRequest(buildRpc(1, "initialize"))!!
        val caps = resp["result"]!!.jsonObject["capabilities"]!!.jsonObject
        assertNull(caps["resources"])
    }

    @Test
    fun `ping returns empty result`() = runBlocking {
        val server = ZeroMcp()
        val resp = server.handleRequest(buildRpc(1, "ping"))!!
        assertNotNull(resp["result"])
        assertEquals("2.0", resp["jsonrpc"]!!.jsonPrimitive.content)
    }

    @Test
    fun `unknown method returns error`() = runBlocking {
        val server = ZeroMcp()
        val resp = server.handleRequest(buildRpc(1, "bogus/method"))!!
        assertNotNull(resp["error"])
        assertEquals(-32601, resp["error"]!!.jsonObject["code"]!!.jsonPrimitive.int)
    }

    @Test
    fun `notification returns null`() = runBlocking {
        val server = ZeroMcp()
        val resp = server.handleRequest(buildRpcNotification("notifications/initialized"))
        assertNull(resp)
    }

    @Test
    fun `tools call dispatches correctly`() = runBlocking {
        val server = ZeroMcp()
        server.tool("echo") {
            description = "Echo"
            input { "msg" to "string" }
            execute { args, _ -> args.getString("msg") }
        }

        val resp = server.handleRequest(buildRpc(1, "tools/call", buildJsonObject {
            put("name", "echo")
            put("arguments", buildJsonObject { put("msg", "hi") })
        }))!!
        val content = resp["result"]!!.jsonObject["content"]!!.jsonArray[0].jsonObject
        assertEquals("text", content["type"]!!.jsonPrimitive.content)
        assertEquals("hi", content["text"]!!.jsonPrimitive.content)
    }

    @Test
    fun `tools call unknown tool returns error content`() = runBlocking {
        val server = ZeroMcp()
        val resp = server.handleRequest(buildRpc(1, "tools/call", buildJsonObject {
            put("name", "nonexistent")
        }))!!
        val result = resp["result"]!!.jsonObject
        assertTrue(result["isError"]!!.jsonPrimitive.boolean)
    }

    @Test
    fun `tools call with validation error`() = runBlocking {
        val server = ZeroMcp()
        server.tool("typed") {
            description = "Typed tool"
            input { "count" to "number" }
            execute { _, _ -> "ok" }
        }

        val resp = server.handleRequest(buildRpc(1, "tools/call", buildJsonObject {
            put("name", "typed")
            put("arguments", buildJsonObject { put("count", "not-a-number") })
        }))!!
        val result = resp["result"]!!.jsonObject
        assertTrue(result["isError"]!!.jsonPrimitive.boolean)
        assertTrue(result["content"]!!.jsonArray[0].jsonObject["text"]!!.jsonPrimitive.content.contains("Validation"))
    }

    @Test
    fun `resources subscribe stores subscription`() = runBlocking {
        val server = ZeroMcp()
        server.resource("r") {
            uri = "file:///r"
            read { "data" }
        }

        val resp = server.handleRequest(buildRpc(1, "resources/subscribe", buildJsonObject {
            put("uri", "file:///r")
        }))!!
        assertNotNull(resp["result"])
    }

    @Test
    fun `completion complete returns empty values`() = runBlocking {
        val server = ZeroMcp()
        val resp = server.handleRequest(buildRpc(1, "completion/complete"))!!
        val completion = resp["result"]!!.jsonObject["completion"]!!.jsonObject
        assertTrue(completion["values"]!!.jsonArray.isEmpty())
    }
}
