package io.antidrift.zeromcp

import kotlinx.serialization.json.JsonObject

/** A JSON-RPC request handler: takes a parsed request object, returns a response or null for notifications. */
typealias McpHandler = suspend (request: JsonObject) -> JsonObject?

/**
 * A tool exposed as an HTTP route, as plain data — no routing or param
 * extraction is performed here. The caller's framework is responsible for
 * matching [method]/[path] and turning path/query/body data into the
 * `args` map passed to `tool.execute`.
 */
data class RouteDefinition(
    val name: String,
    val method: String,   // GET, POST, PUT, PATCH, DELETE — same convention as RouteConfig.method
    val path: String,     // e.g. "/:domain/leads" (colon-param syntax, same as RouteConfig.path)
    val tool: ToolDefinition
)

/**
 * Framework-neutral view over a [ZeroMcp] instance's registered tools.
 */
data class Registry(
    val routes: List<RouteDefinition>,
    val openapi: JsonObject,
    val mcp: McpHandler
)
