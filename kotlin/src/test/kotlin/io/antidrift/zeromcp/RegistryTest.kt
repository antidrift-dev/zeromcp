package io.antidrift.zeromcp

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import kotlin.test.Test
import kotlin.test.assertEquals
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
    fun `routes only includes routed tools`() {
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
    fun `routes preserve insertion order`() {
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
    fun `openapi matches routed tools`() {
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
    fun `empty when no routed tools`() {
        val server = ZeroMcp()
        server.tool("hidden") {
            description = "No route"
            execute { _, _ -> null }
        }
        val registry = server.registry()
        assertEquals(0, registry.routes.size)
    }
}
