package io.zeromcp;

import com.google.gson.*;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.util.*;

/**
 * ZeroMcp -- zero-config MCP runtime for Java.
 *
 * <pre>
 * var server = new ZeroMcp();
 * server.tool("hello", Tool.builder()
 *     .description("Say hello")
 *     .input(Input.required("name", "string"))
 *     .execute((args, ctx) -> "Hello, " + args.get("name") + "!")
 *     .build());
 * server.serve();
 * </pre>
 */
public class ZeroMcp {

    private final Config config;
    private final Map<String, NamedTool> tools = new LinkedHashMap<>();
    private final Gson gson = new Gson();

    public ZeroMcp() {
        this(Config.load());
    }

    public ZeroMcp(Config config) {
        this.config = config;
    }

    /**
     * Register a tool.
     */
    public void tool(String name, Tool tool) {
        Sandbox.validatePermissions(name, tool.permissions());
        tools.put(name, new NamedTool(name, tool));
    }

    /**
     * Start the stdio JSON-RPC server. Blocks until stdin closes.
     */
    public void serve() {
        System.err.println("[zeromcp] " + tools.size() + " tool(s) registered");
        System.err.println("[zeromcp] stdio transport ready");

        var reader = new java.io.BufferedReader(new java.io.InputStreamReader(System.in, java.nio.charset.StandardCharsets.UTF_8));
        var writer = new java.io.PrintWriter(new java.io.OutputStreamWriter(System.out, java.nio.charset.StandardCharsets.UTF_8), true);

        reader.lines().forEach(line -> {
            if (line.isBlank()) return;

            JsonObject request;
            try {
                request = JsonParser.parseString(line).getAsJsonObject();
            } catch (Exception e) {
                return;
            }

            var response = handleRequest(request);
            if (response != null) {
                writer.println(gson.toJson(response));
                writer.flush();
            }
        });
    }

    private JsonObject handleRequest(JsonObject request) {
        var id = request.get("id");
        var method = request.has("method") ? request.get("method").getAsString() : "";
        var params = request.has("params") ? request.getAsJsonObject("params") : null;

        if (id == null && "notifications/initialized".equals(method)) {
            return null;
        }

        return switch (method) {
            case "initialize" -> buildResponse(id, initializeResult());
            case "tools/list" -> buildResponse(id, toolListResult());
            case "tools/call" -> buildResponse(id, callTool(params));
            case "ping" -> buildResponse(id, new JsonObject());
            default -> {
                if (id == null) yield null;
                yield buildErrorResponse(id, -32601, "Method not found: " + method);
            }
        };
    }

    private JsonObject initializeResult() {
        var result = new JsonObject();
        result.addProperty("protocolVersion", "2024-11-05");

        var capabilities = new JsonObject();
        var toolsCap = new JsonObject();
        toolsCap.addProperty("listChanged", true);
        capabilities.add("tools", toolsCap);
        result.add("capabilities", capabilities);

        var serverInfo = new JsonObject();
        serverInfo.addProperty("name", config.name());
        serverInfo.addProperty("version", config.version());
        result.add("serverInfo", serverInfo);

        return result;
    }

    private JsonObject toolListResult() {
        var result = new JsonObject();
        var toolsArray = new JsonArray();

        for (var entry : tools.entrySet()) {
            var obj = new JsonObject();
            obj.addProperty("name", entry.getKey());
            obj.addProperty("description", entry.getValue().tool().description());
            obj.add("inputSchema", Schema.toJsonSchema(entry.getValue().tool().inputs()));
            toolsArray.add(obj);
        }

        result.add("tools", toolsArray);
        return result;
    }

    private JsonObject callTool(JsonObject params) {
        if (params == null) {
            return buildToolResult("No parameters provided", true);
        }

        var name = params.has("name") ? params.get("name").getAsString() : "";
        var argsJson = params.has("arguments") ? params.getAsJsonObject("arguments") : new JsonObject();

        var namedTool = tools.get(name);
        if (namedTool == null) {
            return buildToolResult("Unknown tool: " + name, true);
        }

        var tool = namedTool.tool();
        var argsMap = jsonObjectToMap(argsJson);

        var schema = Schema.toJsonSchema(tool.inputs());
        var errors = Schema.validate(argsMap, schema);
        if (!errors.isEmpty()) {
            return buildToolResult("Validation errors:\n" + String.join("\n", errors), true);
        }

        try {
            var ctx = new Ctx(name, tool.permissions());
            var result = tool.executor().execute(argsMap, ctx);
            var text = result instanceof String s ? s
                : result == null ? "null"
                : gson.toJson(result);
            return buildToolResult(text, false);
        } catch (Exception e) {
            return buildToolResult("Error: " + e.getMessage(), true);
        }
    }

    private JsonObject buildToolResult(String text, boolean isError) {
        var result = new JsonObject();
        var content = new JsonArray();
        var item = new JsonObject();
        item.addProperty("type", "text");
        item.addProperty("text", text);
        content.add(item);
        result.add("content", content);
        if (isError) result.addProperty("isError", true);
        return result;
    }

    private JsonObject buildResponse(JsonElement id, JsonObject result) {
        var response = new JsonObject();
        response.addProperty("jsonrpc", "2.0");
        if (id != null) response.add("id", id);
        response.add("result", result);
        return response;
    }

    private JsonObject buildErrorResponse(JsonElement id, int code, String message) {
        var response = new JsonObject();
        response.addProperty("jsonrpc", "2.0");
        if (id != null) response.add("id", id);
        var error = new JsonObject();
        error.addProperty("code", code);
        error.addProperty("message", message);
        response.add("error", error);
        return response;
    }

    private static Map<String, Object> jsonObjectToMap(JsonObject obj) {
        var map = new LinkedHashMap<String, Object>();
        for (var entry : obj.entrySet()) {
            map.put(entry.getKey(), jsonElementToObject(entry.getValue()));
        }
        return map;
    }

    private static Object jsonElementToObject(JsonElement element) {
        if (element == null || element.isJsonNull()) return null;
        if (element.isJsonPrimitive()) {
            var p = element.getAsJsonPrimitive();
            if (p.isString()) return p.getAsString();
            if (p.isBoolean()) return p.getAsBoolean();
            if (p.isNumber()) {
                var d = p.getAsDouble();
                if (d == (long) d) return (long) d;
                return d;
            }
        }
        if (element.isJsonArray()) {
            var list = new ArrayList<>();
            for (var e : element.getAsJsonArray()) list.add(jsonElementToObject(e));
            return list;
        }
        if (element.isJsonObject()) return jsonObjectToMap(element.getAsJsonObject());
        return element.toString();
    }

    private record NamedTool(String name, Tool tool) {}
}
