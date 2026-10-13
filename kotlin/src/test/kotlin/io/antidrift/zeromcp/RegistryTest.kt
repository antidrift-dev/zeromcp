package io.antidrift.zeromcp

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class RegistryTest {

    private fun routedServer(): ZeroMcp {
        val server = ZeroMcp()
        server.tool("greet") {
            description = "Greet a person by name"
            input { "name" to "string" }
            route("GET", "/greet/:name")
            execute { args, _ -> "hi ${args.getString("name")}" }
        }
        return server
    }

    @Test
    fun `routes only includes routed tools`() = runBlocking {
        val server = routedServer()
        server.tool("hidden") {
            description = "No route"
            execute { _, _ -> null }
        }

        val registry = server.registry()
        assertEquals(1, registry.routes.size)
        assertEquals("greet", registry.routes[0].name)
        assertEquals("GET", registry.routes[0].method)
        assertEquals("/greet/:name", registry.routes[0].path)
    }

    @Test
    fun `routes preserve insertion order`() = runBlocking {
        val server = ZeroMcp()
        for (n in listOf("charlie", "alpha", "bravo")) {
            server.tool(n) {
                description = n
                route("GET", "/$n")
                execute { _, _ -> null }
            }
        }

        val registry = server.registry()
        assertEquals(listOf("charlie", "alpha", "bravo"), registry.routes.map { it.name })
    }

    @Test
    fun `openapi matches routed tools`() = runBlocking {
        val server = routedServer()
        val registry = server.registry()
        val paths = registry.openapi["paths"]?.jsonObject
        assertTrue(paths?.containsKey("/greet/{name}") == true)
    }

    @Test
    fun `route tool invoked directly produces expected result`() = runBlocking {
        val server = routedServer()
        val registry = server.registry()
        val route = registry.routes[0]
        val ctx = Ctx(toolName = route.name, permissions = route.tool.permissions)
        val result = route.tool.execute(mapOf("name" to "Ada"), ctx)
        assertEquals("hi Ada", result)
    }

    @Test
    fun `mcp dispatches tools list`() = runBlocking {
        val server = routedServer()
        val registry = server.registry()
        val request = buildJsonObject {
            put("jsonrpc", "2.0")
            put("id", 1)
            put("method", "tools/list")
        }
        val response = registry.mcp(request)
        val tools = response?.get("result")?.jsonObject?.get("tools")?.jsonArray
        assertEquals(1, tools?.size)
        assertEquals("greet", tools?.get(0)?.jsonObject?.get("name")?.jsonPrimitive?.content)
    }

    @Test
    fun `mcp dispatches tools call`() = runBlocking {
        val server = ZeroMcp()
        server.tool("greet") {
            description = "Greet a person by name"
            input { "name" to "string" }
            route("POST", "/greet")
            execute { args, _ -> "hi ${args.getString("name")}" }
        }
        val registry = server.registry()
        val request = buildJsonObject {
            put("jsonrpc", "2.0")
            put("id", 1)
            put("method", "tools/call")
            putJsonObject("params") {
                put("name", "greet")
                putJsonObject("arguments") { put("name", "Ada") }
            }
        }
        val response = registry.mcp(request)
        val text = response?.get("result")?.jsonObject
            ?.get("content")?.jsonArray?.get(0)?.jsonObject?.get("text")?.jsonPrimitive?.content
        assertEquals("hi Ada", text)
    }

    @Test
    fun `empty when no routed tools`() = runBlocking {
        val server = ZeroMcp()
        server.tool("hidden") {
            description = "No route"
            execute { _, _ -> null }
        }
        val registry = server.registry()
        assertEquals(0, registry.routes.size)
    }

    @Test
    fun `openapi documents a non-GET path param as path, not body`() = runBlocking {
        val server = ZeroMcp()
        server.tool("updateItem") {
            description = "Update an item"
            input {
                "id" to "string"
                "name" to "string"
            }
            route("PUT", "/items/:id")
            execute { args, _ -> mapOf("id" to args.getString("id"), "name" to args.getString("name")) }
        }

        val putOp = server.registry().openapi["paths"]!!.jsonObject["/items/{id}"]!!.jsonObject["put"]!!.jsonObject

        val parameters = putOp["parameters"]?.jsonArray
        assertTrue(parameters != null && parameters.isNotEmpty(), "expected a non-empty parameters array")
        val idParam = parameters!!.map { it.jsonObject }.first { it["name"]!!.jsonPrimitive.content == "id" }
        assertEquals("path", idParam["in"]!!.jsonPrimitive.content)
        assertEquals(true, idParam["required"]!!.jsonPrimitive.boolean)

        val bodySchema = putOp["requestBody"]!!.jsonObject["content"]!!.jsonObject["application/json"]!!.jsonObject["schema"]!!.jsonObject
        val bodyProps = bodySchema["properties"]!!.jsonObject
        assertFalse(bodyProps.containsKey("id"), "path param 'id' must not be duplicated into the request body schema")
        assertTrue(bodyProps.containsKey("name"), "non-path field 'name' must still be documented in the request body schema")
    }

    @Test
    fun `mcp lists and calls remote tools`() = runBlocking {
        FakeUpstream().use { up ->
            val registry = ZeroMcp(ZeroMcpConfig(remote = listOf(RemoteServer("probeo", up.url)))).registry()
            assertEquals("probeo.list_pages", registry.mcp(rpc(1, "tools/list")).toolNames()[0])
            val called = registry.mcp(callRpc(2, "probeo.list_pages", buildJsonObject { put("domain", "example.com") }))
            assertEquals(FakeUpstream.PAGES_TEXT, called.firstText())
        }
    }

    @Test
    fun `local tool overrides remote in the registry`() = runBlocking {
        FakeUpstream().use { up ->
            val server = ZeroMcp(ZeroMcpConfig(remote = listOf(RemoteServer("probeo", up.url))))
            server.tool("probeo.list_pages") {
                description = "local"
                execute { _, _ -> "local override" }
            }
            lateinit var registry: Registry
            val err = captureStderr { runBlocking { registry = server.registry() } }
            assertTrue(err.contains("probeo.list_pages") && err.contains("overrides remote"), err)
            assertEquals("local override", registry.mcp(callRpc(1, "probeo.list_pages")).firstText())
        }
    }

    @Test
    fun `remote tools never appear in routes or openapi`() = runBlocking {
        FakeUpstream().use { up ->
            val registry = ZeroMcp(ZeroMcpConfig(remote = listOf(RemoteServer("probeo", up.url)))).registry()
            assertEquals(emptyList(), registry.routes)
            assertEquals(JsonObject(emptyMap()), registry.openapi["paths"])
        }
    }

    @Test
    fun `mcp tools call sees the runtime`() = runBlocking {
        val server = ZeroMcp()
        server.runtimeProvider = { "env-1" }
        server.tool("whoami") {
            description = "Returns the runtime"
            execute { _, ctx -> ctx.runtime }
        }
        val registry = server.registry()
        assertEquals("env-1", registry.mcp(callRpc(1, "whoami")).firstText())
    }
}
