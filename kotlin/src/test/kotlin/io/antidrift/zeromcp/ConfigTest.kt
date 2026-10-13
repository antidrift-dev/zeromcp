package io.antidrift.zeromcp

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertFailsWith
import kotlin.test.assertTrue
import java.io.File
import java.nio.file.Files

class ConfigTest {

    @Test
    fun `default config has sensible values`() {
        val config = ZeroMcpConfig()
        assertEquals("stdio", config.transport)
        assertEquals(false, config.logging)
        assertEquals("_", config.separator)
        assertEquals("zeromcp", config.name)
    }

    @Test
    fun `loadConfig returns defaults for missing file`() {
        val config = loadConfig("/nonexistent/path")
        assertEquals("stdio", config.transport)
    }

    @Test
    fun `resolveAuth returns raw string for non-env`() {
        assertEquals("my-token", resolveAuth("my-token"))
    }

    @Test
    fun `resolveAuth reads from environment`() {
        // env:NONEXISTENT should return null
        assertNull(resolveAuth("env:ZEROMCP_TEST_NONEXISTENT_VAR"))
    }

    @Test
    fun `resolveAuth returns null for null input`() {
        assertNull(resolveAuth(null))
    }

    private fun configDir(content: String): String {
        val dir = Files.createTempDirectory("zeromcp-config").toFile()
        dir.deleteOnExit()
        File(dir, "zeromcp.config.json").writeText(content)
        return dir.path
    }

    @Test
    fun `loadConfig rejects an http transport string`() {
        val e = assertFailsWith<IllegalStateException> { loadConfig(configDir("""{"transport":"http"}""")) }
        assertTrue(e.message!!.contains("registry()"), e.message)
        assertTrue(e.message!!.startsWith("transport \"http\" is not supported"), e.message)
    }

    @Test
    fun `loadConfig rejects an http transport array`() {
        val e = assertFailsWith<IllegalStateException> {
            loadConfig(configDir("""{"transport":[{"type":"stdio"},{"type":"http","port":1}]}"""))
        }
        assertTrue(e.message!!.contains("registry()"), e.message)
    }

    @Test
    fun `loadConfig accepts stdio transport forms`() {
        assertEquals("stdio", loadConfig(configDir("""{"transport":"stdio"}""")).transport)
        assertEquals("stdio", loadConfig(configDir("""{"transport":[{"type":"stdio"}],"name":"x"}""")).let { assertEquals("x", it.name); it.transport })
    }

    @Test
    fun `ZeroMcp rejects an http transport built in code`() {
        val e = assertFailsWith<IllegalStateException> { ZeroMcp(ZeroMcpConfig(transport = "http")) }
        assertTrue(e.message!!.contains("ZeroMcp.registry()"), e.message)
    }

    @Test
    fun `loadConfig still parses an old config carrying port`() {
        assertEquals("old", loadConfig(configDir("""{"port":4242,"name":"old"}""")).name)
    }

    @Test
    fun `loadConfig reads icon, page_size and remote`() {
        val config = loadConfig(configDir(
            """{"icon":"data:image/png;base64,AA==","page_size":5,"remote":[{"name":"probeo","url":"http://x","auth":"env:T","tools":["a"]}]}"""
        ))
        assertEquals("data:image/png;base64,AA==", config.icon)
        assertEquals(5, config.page_size)
        assertEquals(listOf(RemoteServer("probeo", "http://x", "env:T", listOf("a"))), config.remote)
    }

    @Test
    fun `resolveIcon passes data URIs through`() {
        assertEquals("data:image/png;base64,AA==", resolveIcon("data:image/png;base64,AA=="))
        assertNull(resolveIcon(null))
    }

    @Test
    fun `resolveIcon reads a file into a data URI by extension`() {
        val f = File.createTempFile("icon", ".svg")
        f.deleteOnExit()
        f.writeText("<svg/>")
        val b64 = java.util.Base64.getEncoder().encodeToString("<svg/>".toByteArray())
        assertEquals("data:image/svg+xml;base64,$b64", resolveIcon(f.path))
    }

    @Test
    fun `resolveIcon returns null for a missing file`() {
        assertNull(resolveIcon("/nonexistent/icon.png"))
    }
}
