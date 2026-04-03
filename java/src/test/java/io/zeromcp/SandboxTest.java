package io.zeromcp;

import io.zeromcp.Permissions.FsPermission;
import io.zeromcp.Permissions.NetworkPermission;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class SandboxTest {

    @Test
    void unsetNetworkPermissionAllowsAll() {
        var perms = new Permissions(NetworkPermission.unset(), FsPermission.NONE, false);
        assertTrue(Sandbox.checkNetworkAccess("test", "example.com", perms));
    }

    @Test
    void allNetworkPermissionAllowsAll() {
        var perms = new Permissions(NetworkPermission.all(), FsPermission.NONE, false);
        assertTrue(Sandbox.checkNetworkAccess("test", "example.com", perms));
    }

    @Test
    void deniedNetworkPermissionBlocksAll() {
        var perms = new Permissions(NetworkPermission.denied(), FsPermission.NONE, false);
        assertFalse(Sandbox.checkNetworkAccess("test", "example.com", perms));
    }

    @Test
    void allowlistPermitsListedHosts() {
        var perms = new Permissions(
            NetworkPermission.allowList("api.example.com"), FsPermission.NONE, false);
        assertTrue(Sandbox.checkNetworkAccess("test", "api.example.com", perms));
    }

    @Test
    void allowlistBlocksUnlistedHosts() {
        var perms = new Permissions(
            NetworkPermission.allowList("api.example.com"), FsPermission.NONE, false);
        assertFalse(Sandbox.checkNetworkAccess("test", "evil.com", perms));
    }

    @Test
    void wildcardAllowlistMatchesSubdomains() {
        var perms = new Permissions(
            NetworkPermission.allowList("*.example.com"), FsPermission.NONE, false);
        assertTrue(Sandbox.checkNetworkAccess("test", "api.example.com", perms));
        assertTrue(Sandbox.checkNetworkAccess("test", "example.com", perms));
        assertFalse(Sandbox.checkNetworkAccess("test", "other.com", perms));
    }

    @Test
    void fsNoneBlocksAccess() {
        var perms = new Permissions(NetworkPermission.unset(), FsPermission.NONE, false);
        assertFalse(Sandbox.checkFsAccess("test", perms, false));
    }

    @Test
    void fsReadAllowsReadButBlocksWrite() {
        var perms = new Permissions(NetworkPermission.unset(), FsPermission.READ, false);
        assertTrue(Sandbox.checkFsAccess("test", perms, false));
        assertFalse(Sandbox.checkFsAccess("test", perms, true));
    }

    @Test
    void fsWriteAllowsBoth() {
        var perms = new Permissions(NetworkPermission.unset(), FsPermission.WRITE, false);
        assertTrue(Sandbox.checkFsAccess("test", perms, false));
        assertTrue(Sandbox.checkFsAccess("test", perms, true));
    }

    @Test
    void execDeniedByDefault() {
        var perms = Permissions.of();
        assertFalse(Sandbox.checkExecAccess("test", perms));
    }

    @Test
    void execAllowedWhenSet() {
        var perms = new Permissions(NetworkPermission.unset(), FsPermission.NONE, true);
        assertTrue(Sandbox.checkExecAccess("test", perms));
    }
}
