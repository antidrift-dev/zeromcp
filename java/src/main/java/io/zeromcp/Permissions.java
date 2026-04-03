package io.zeromcp;

import java.util.List;

/**
 * Permission declarations for a tool.
 */
public record Permissions(
    NetworkPermission network,
    FsPermission fs,
    boolean exec
) {
    public Permissions() {
        this(NetworkPermission.unset(), FsPermission.NONE, false);
    }

    public static Permissions of() {
        return new Permissions();
    }

    public sealed interface NetworkPermission {
        record Unset() implements NetworkPermission {}
        record All() implements NetworkPermission {}
        record Denied() implements NetworkPermission {}
        record AllowList(List<String> hosts) implements NetworkPermission {}

        static NetworkPermission unset() { return new Unset(); }
        static NetworkPermission all() { return new All(); }
        static NetworkPermission denied() { return new Denied(); }
        static NetworkPermission allowList(String... hosts) {
            return new AllowList(List.of(hosts));
        }
    }

    public enum FsPermission {
        NONE, READ, WRITE, FULL
    }
}
