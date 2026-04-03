package io.zeromcp

import kotlin.test.Test
import kotlin.test.assertTrue
import kotlin.test.assertFalse

class SandboxTest {

    @Test
    fun `unset network permission allows all`() {
        val perms = Permissions(network = NetworkPermission.Unset)
        assertTrue(checkNetworkAccess("test", "example.com", perms))
    }

    @Test
    fun `all network permission allows all`() {
        val perms = Permissions(network = NetworkPermission.All)
        assertTrue(checkNetworkAccess("test", "example.com", perms))
    }

    @Test
    fun `denied network permission blocks all`() {
        val perms = Permissions(network = NetworkPermission.Denied)
        assertFalse(checkNetworkAccess("test", "example.com", perms))
    }

    @Test
    fun `allowlist permits listed hosts`() {
        val perms = Permissions(network = NetworkPermission.AllowList(listOf("api.example.com")))
        assertTrue(checkNetworkAccess("test", "api.example.com", perms))
    }

    @Test
    fun `allowlist blocks unlisted hosts`() {
        val perms = Permissions(network = NetworkPermission.AllowList(listOf("api.example.com")))
        assertFalse(checkNetworkAccess("test", "evil.com", perms))
    }

    @Test
    fun `wildcard allowlist matches subdomains`() {
        val perms = Permissions(network = NetworkPermission.AllowList(listOf("*.example.com")))
        assertTrue(checkNetworkAccess("test", "api.example.com", perms))
        assertTrue(checkNetworkAccess("test", "example.com", perms))
        assertFalse(checkNetworkAccess("test", "other.com", perms))
    }

    @Test
    fun `fs none blocks access`() {
        val perms = Permissions(fs = FsPermission.None)
        assertFalse(checkFsAccess("test", perms))
    }

    @Test
    fun `fs read allows read but blocks write`() {
        val perms = Permissions(fs = FsPermission.Read)
        assertTrue(checkFsAccess("test", perms, write = false))
        assertFalse(checkFsAccess("test", perms, write = true))
    }

    @Test
    fun `fs write allows both`() {
        val perms = Permissions(fs = FsPermission.Write)
        assertTrue(checkFsAccess("test", perms, write = false))
        assertTrue(checkFsAccess("test", perms, write = true))
    }

    @Test
    fun `exec denied by default`() {
        val perms = Permissions()
        assertFalse(checkExecAccess("test", perms))
    }

    @Test
    fun `exec allowed when set`() {
        val perms = Permissions(exec = true)
        assertTrue(checkExecAccess("test", perms))
    }
}
