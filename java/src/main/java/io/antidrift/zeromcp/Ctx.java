package io.antidrift.zeromcp;

/**
 * Context passed to tool execution.
 *
 * @param runtime value from the supplier set with {@link ZeroMcp#runtime}, or null
 */
public record Ctx(String toolName, Permissions permissions, Object runtime) {
    public Ctx(String toolName, Permissions permissions) {
        this(toolName, permissions, null);
    }

    public Ctx(String toolName) {
        this(toolName, Permissions.of(), null);
    }

    /** The runtime value cast to {@code type}. */
    public <R> R runtime(Class<R> type) {
        return type.cast(runtime);
    }
}
