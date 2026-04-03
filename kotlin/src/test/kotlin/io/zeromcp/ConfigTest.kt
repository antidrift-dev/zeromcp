package io.zeromcp

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class ConfigTest {

    @Test
    fun `default config has sensible values`() {
        val config = ZeroMcpConfig()
        assertEquals("stdio", config.transport)
        assertEquals(4242, config.port)
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
}
