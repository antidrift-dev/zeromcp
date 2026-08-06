package io.antidrift.zeromcp;

import com.google.gson.JsonObject;
import java.util.List;

/**
 * Framework-neutral handle onto a ZeroMcp instance's route-annotated tools
 * and JSON-RPC dispatch, for embedding into a caller-owned HTTP framework
 * instead of using {@link ZeroMcp#serveHttp}.
 */
public record Registry(List<RouteDefinition> routes, JsonObject openapi, McpHandler mcp) {}
