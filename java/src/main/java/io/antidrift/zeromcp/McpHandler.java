package io.antidrift.zeromcp;

import com.google.gson.JsonObject;

/** A JSON-RPC request handler. Returns null for notifications that require no response. */
@FunctionalInterface
public interface McpHandler {
    JsonObject handle(JsonObject request);
}
