package io.antidrift.zeromcp

import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.*
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class RemoteTest {

    private fun serverFor(vararg remotes: RemoteServer) = ZeroMcp(ZeroMcpConfig(remote = remotes.toList()))

    @Test
    fun `tools list shows namespaced remote tools`() = runBlocking {
        FakeUpstream().use { up ->
            val server = serverFor(RemoteServer("probeo", up.url))
            server.connectRemotes()
            val names = server.handleRequest(rpc(1, "tools/list")).toolNames()
            assertEquals(listOf("probeo.list_pages", "probeo.get_page"), names)
        }
    }

    @Test
    fun `tools call returns upstream content text`() = runBlocking {
        FakeUpstream().use { up ->
            val server = serverFor(RemoteServer("probeo", up.url))
            server.connectRemotes()
            val res = server.handleRequest(callRpc(2, "probeo.list_pages", buildJsonObject { put("domain", "example.com") }))
            assertEquals(FakeUpstream.PAGES_TEXT, res.firstText())
            assertEquals(buildJsonObject { put("domain", "example.com") }, up.callArgs.single())
            assertEquals("tools/call", up.methods.last())
        }
    }

    @Test
    fun `allowlist keeps only listed upstream tools`() = runBlocking {
        FakeUpstream().use { up ->
            val server = serverFor(RemoteServer("probeo", up.url, tools = listOf("list_pages")))
            server.connectRemotes()
            assertEquals(listOf("probeo.list_pages"), server.handleRequest(rpc(1, "tools/list")).toolNames())
        }
    }

    @Test
    fun `local tool overrides remote tool with the same name`() = runBlocking {
        FakeUpstream().use { up ->
            val server = serverFor(RemoteServer("probeo", up.url))
            server.tool("probeo.list_pages") {
                description = "local"
                execute { _, _ -> "local override" }
            }
            val err = captureStderr { runBlocking { server.connectRemotes() } }
            assertTrue(err.contains("Local tool \"probeo.list_pages\" overrides remote"), err)
            // Remote slot order is kept, local definition wins.
            assertEquals(listOf("probeo.list_pages", "probeo.get_page"), server.handleRequest(rpc(1, "tools/list")).toolNames())
            assertEquals("local override", server.handleRequest(callRpc(2, "probeo.list_pages")).firstText())
            assertTrue(up.methods.none { it == "tools/call" })
        }
    }

    @Test
    fun `local tool registered after connect also overrides remote`() = runBlocking {
        FakeUpstream().use { up ->
            val server = serverFor(RemoteServer("probeo", up.url))
            server.connectRemotes()
            val err = captureStderr {
                server.tool("probeo.get_page") {
                    description = "local"
                    execute { _, _ -> "local page" }
                }
            }
            assertTrue(err.contains("overrides remote"), err)
            assertEquals("local page", server.handleRequest(callRpc(2, "probeo.get_page")).firstText())
        }
    }

    @Test
    fun `bad url and non-2xx upstream are skipped while a good server connects`() = runBlocking {
        FakeUpstream(status = 500).use { bad ->
            FakeUpstream().use { good ->
                val server = serverFor(
                    RemoteServer("ftp", "ftp://example.com"),
                    RemoteServer("broken", bad.url),
                    RemoteServer("probeo", good.url, tools = listOf("list_pages"))
                )
                val err = captureStderr { runBlocking { server.connectRemotes() } }
                assertTrue(err.contains("[mcp] Failed to connect to ftp: Remote server \"ftp\" must have an HTTP/HTTPS URL, got: ftp://example.com"), err)
                assertTrue(err.contains("[mcp] Failed to connect to broken: HTTP 500"), err)
                assertTrue(err.contains("[mcp] Connected to probeo (HTTP): 1 tool(s)"), err)
                assertEquals(listOf("probeo.list_pages"), server.handleRequest(rpc(1, "tools/list")).toolNames())
            }
        }
    }

    @Test
    fun `bearer auth is sent, including the env form`() = runBlocking {
        FakeUpstream().use { up ->
            val server = serverFor(RemoteServer("probeo", up.url, auth = "secret-token"))
            server.connectRemotes()
            server.handleRequest(callRpc(1, "probeo.list_pages", buildJsonObject { put("domain", "x") }))
            assertTrue(up.authHeaders.isNotEmpty())
            assertTrue(up.authHeaders.all { it == "Bearer secret-token" }, up.authHeaders.toString())
        }
        val home = System.getenv("HOME")!!
        FakeUpstream().use { up ->
            val server = serverFor(RemoteServer("probeo", up.url, auth = "env:HOME"))
            server.connectRemotes()
            assertTrue(up.authHeaders.all { it == "Bearer $home" }, up.authHeaders.toString())
        }
        FakeUpstream().use { up ->
            serverFor(RemoteServer("probeo", up.url)).connectRemotes()
            assertTrue(up.authHeaders.all { it == null }, up.authHeaders.toString())
        }
    }

    @Test
    fun `connectRemotes is idempotent`() = runBlocking {
        FakeUpstream().use { up ->
            val server = serverFor(RemoteServer("probeo", up.url))
            server.connectRemotes()
            server.connectRemotes()
            assertEquals(1, up.methods.count { it == "tools/list" })
            assertEquals(2, server.handleRequest(rpc(1, "tools/list")).toolNames().size)
        }
    }

    @Test
    fun `remote tools never receive the runtime provider`() = runBlocking {
        FakeUpstream().use { up ->
            var calls = 0
            val server = serverFor(RemoteServer("probeo", up.url))
            server.runtimeProvider = { calls++; "rt" }
            server.connectRemotes()
            server.handleRequest(callRpc(1, "probeo.list_pages", buildJsonObject { put("domain", "x") }))
            assertEquals(0, calls)
        }
    }

    @Test
    fun `remote tools have no route`() = runBlocking {
        FakeUpstream().use { up ->
            val registry = serverFor(RemoteServer("probeo", up.url)).registry()
            assertFalse(registry.routes.any { it.name.startsWith("probeo.") })
        }
    }
}
