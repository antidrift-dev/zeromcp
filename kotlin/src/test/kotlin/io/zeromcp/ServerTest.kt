package io.zeromcp

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class ServerTest {

    @Test
    fun `tool registration works`() {
        val server = ZeroMcp()
        server.tool("greet") {
            description = "Greet someone"
            input { "name" to "string" }
            execute { args, _ -> "Hi, ${args.getString("name")}!" }
        }
        // If we get here without exception, registration succeeded
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
}
