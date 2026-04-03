package io.zeromcp;

/**
 * Context passed to tool execution.
 */
public record Ctx(String toolName, Permissions permissions) {
    public Ctx(String toolName) {
        this(toolName, Permissions.of());
    }
}
