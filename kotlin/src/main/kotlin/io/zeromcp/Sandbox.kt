package io.zeromcp

import java.net.URI

/**
 * Validates and logs elevated permissions for a tool.
 */
fun validatePermissions(name: String, permissions: Permissions) {
    val elevated = mutableListOf<String>()
    if (permissions.fs != FsPermission.None) elevated.add("fs: ${permissions.fs.name.lowercase()}")
    if (permissions.exec) elevated.add("exec")

    if (elevated.isNotEmpty()) {
        System.err.println("[zeromcp] $name requests elevated permissions: ${elevated.joinToString(" | ")}")
    }
}

/**
 * Checks whether a network request to the given hostname is allowed
 * by the tool's permissions.
 */
fun checkNetworkAccess(toolName: String, hostname: String, permissions: Permissions): Boolean {
    return when (val net = permissions.network) {
        is NetworkPermission.Unset, is NetworkPermission.All -> true
        is NetworkPermission.Denied -> {
            System.err.println("[zeromcp] $toolName: network access denied")
            false
        }
        is NetworkPermission.AllowList -> {
            if (isHostAllowed(hostname, net.hosts)) {
                true
            } else {
                System.err.println(
                    "[zeromcp] $toolName: network access denied for $hostname " +
                    "(allowed: ${net.hosts.joinToString(", ")})"
                )
                false
            }
        }
    }
}

private fun isHostAllowed(hostname: String, allowlist: List<String>): Boolean {
    return allowlist.any { pattern ->
        if (pattern.startsWith("*.")) {
            hostname.endsWith(pattern.substring(1)) || hostname == pattern.substring(2)
        } else {
            hostname == pattern
        }
    }
}

/**
 * Checks filesystem access permission.
 */
fun checkFsAccess(toolName: String, permissions: Permissions, write: Boolean = false): Boolean {
    return when (permissions.fs) {
        FsPermission.Full -> true
        FsPermission.Write -> true
        FsPermission.Read -> {
            if (write) {
                System.err.println("[zeromcp] $toolName: fs write access denied (read-only)")
                false
            } else true
        }
        FsPermission.None -> {
            System.err.println("[zeromcp] $toolName: fs access denied")
            false
        }
    }
}

/**
 * Checks exec permission.
 */
fun checkExecAccess(toolName: String, permissions: Permissions): Boolean {
    if (!permissions.exec) {
        System.err.println("[zeromcp] $toolName: exec access denied")
        return false
    }
    return true
}
