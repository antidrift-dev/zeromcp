package io.zeromcp;

import io.zeromcp.Permissions.FsPermission;
import io.zeromcp.Permissions.NetworkPermission;

import java.util.List;

/**
 * Permission checking for tool sandbox.
 */
public final class Sandbox {

    private Sandbox() {}

    /**
     * Validates and logs elevated permissions for a tool.
     */
    public static void validatePermissions(String name, Permissions permissions) {
        var elevated = new java.util.ArrayList<String>();
        if (permissions.fs() != FsPermission.NONE) {
            elevated.add("fs: " + permissions.fs().name().toLowerCase());
        }
        if (permissions.exec()) {
            elevated.add("exec");
        }
        if (!elevated.isEmpty()) {
            System.err.println("[zeromcp] " + name +
                " requests elevated permissions: " + String.join(" | ", elevated));
        }
    }

    /**
     * Checks whether a network request to the given hostname is allowed.
     */
    public static boolean checkNetworkAccess(String toolName, String hostname, Permissions permissions) {
        var net = permissions.network();

        if (net instanceof NetworkPermission.Unset || net instanceof NetworkPermission.All) {
            return true;
        }

        if (net instanceof NetworkPermission.Denied) {
            System.err.println("[zeromcp] " + toolName + ": network access denied");
            return false;
        }

        if (net instanceof NetworkPermission.AllowList allowList) {
            if (isHostAllowed(hostname, allowList.hosts())) {
                return true;
            }
            System.err.println("[zeromcp] " + toolName +
                ": network access denied for " + hostname +
                " (allowed: " + String.join(", ", allowList.hosts()) + ")");
            return false;
        }

        return true;
    }

    /**
     * Checks filesystem access permission.
     */
    public static boolean checkFsAccess(String toolName, Permissions permissions, boolean write) {
        return switch (permissions.fs()) {
            case FULL, WRITE -> true;
            case READ -> {
                if (write) {
                    System.err.println("[zeromcp] " + toolName + ": fs write access denied (read-only)");
                    yield false;
                }
                yield true;
            }
            case NONE -> {
                System.err.println("[zeromcp] " + toolName + ": fs access denied");
                yield false;
            }
        };
    }

    /**
     * Checks exec permission.
     */
    public static boolean checkExecAccess(String toolName, Permissions permissions) {
        if (!permissions.exec()) {
            System.err.println("[zeromcp] " + toolName + ": exec access denied");
            return false;
        }
        return true;
    }

    private static boolean isHostAllowed(String hostname, List<String> allowlist) {
        return allowlist.stream().anyMatch(pattern -> {
            if (pattern.startsWith("*.")) {
                return hostname.endsWith(pattern.substring(1)) ||
                       hostname.equals(pattern.substring(2));
            }
            return hostname.equals(pattern);
        });
    }
}
