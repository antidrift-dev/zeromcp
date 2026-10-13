package io.antidrift.zeromcp;

import com.google.gson.JsonObject;
import java.util.List;

/**
 * Framework-neutral handle onto a ZeroMcp instance's route-annotated tools
 * and JSON-RPC dispatch, for mounting in your own HTTP server.
 */
public record Registry(List<RouteDefinition> routes, JsonObject openapi, McpHandler mcp) {}
