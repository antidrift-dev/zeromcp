package io.zeromcp;

import java.util.Map;

/**
 * Functional interface for tool execution.
 */
@FunctionalInterface
public interface ToolExecutor {
    Object execute(Map<String, Object> args, Ctx ctx) throws Exception;
}
