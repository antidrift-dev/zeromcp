package io.antidrift.zeromcp;

import com.google.gson.*;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.Supplier;

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
 * server.resource("settings", ResourceDef.builder()
 *     .uri("config://app/settings")
 *     .description("Application settings")
 *     .mimeType("application/json")
 *     .read(() -> "{\"theme\":\"dark\"}")
 *     .build());
 * server.prompt("summarize", PromptDef.builder()
 *     .description("Summarize a topic")
 *     .argument(PromptArgument.required("topic", "The topic"))
 *     .render(args -> List.of(new PromptMessage("user", "Summarize: " + args.get("topic"))))
 *     .build());
 * server.serve();
 * </pre>
 */
public class ZeroMcp {

    private final Config config;
    private final Map<String, NamedTool> tools = new LinkedHashMap<>();
    private final Map<String, NamedResource> resources = new LinkedHashMap<>();
    private final Map<String, NamedPrompt> prompts = new LinkedHashMap<>();
    private final Set<String> subscriptions = ConcurrentHashMap.newKeySet();
    private final Gson gson = new Gson();

    private int pageSize = 0;
    private String logLevel = "info";
    private String icon = null;
    private boolean iconSet = false;
    private final List<RemoteServer> remotes = new ArrayList<>();
    private Supplier<?> runtimeSupplier = null;
    private volatile boolean started = false;

    public ZeroMcp() {
        this(Config.load());
    }

    public ZeroMcp(Config config) {
        this.config = config;
        this.pageSize = config.pageSize();
        this.remotes.addAll(config.remote());
    }

    // ---- Builder-style setters ----

    /**
     * Set the page size for paginated list responses. 0 = no pagination (default).
     */
    public ZeroMcp pageSize(int pageSize) {
        this.pageSize = pageSize;
        return this;
    }

    /**
     * Set the server icon URI (included in list entries).
     */
    public ZeroMcp icon(String icon) {
        this.icon = icon;
        this.iconSet = true;
        return this;
    }

    /**
     * Federate tools from remote MCP servers, namespaced as {@code <name>.<tool>}.
     * Appends to the servers listed under {@code remote} in zeromcp.config.json.
     * Remotes connect once, on the first {@link #serve}, {@link #handleRequest}
     * or {@link #registry} call. A local tool with the same name overrides the remote one.
     */
    public ZeroMcp remote(RemoteServer... servers) {
        Collections.addAll(remotes, servers);
        return this;
    }

    /**
     * Set a supplier whose value is passed to every local tool execution as
     * {@link Ctx#runtime()}. Called once per tool call. Remote tools do not get it.
     */
    public ZeroMcp runtime(Supplier<?> getRuntime) {
        this.runtimeSupplier = getRuntime;
        return this;
    }

    // ---- Registration ----

    /**
     * Register a tool. Computes and caches the JSON schema at registration time.
     */
    public void tool(String name, Tool tool) {
        Sandbox.validatePermissions(name, tool.permissions());
        var schema = Schema.toJsonSchema(tool.inputs());
        tools.put(name, new NamedTool(name, tool, schema, false));
    }

    /**
     * Build a framework-neutral registry snapshot of the currently-registered,
     * route-annotated tools plus a JSON-RPC dispatcher, for mounting in your
     * own HTTP server. Call this after all {@link #tool} registrations are done,
     * same as {@link #serve}. Connects remote servers first (blocking); remote
     * tools are served by {@code mcp()} but have no routes or OpenAPI entries.
     */
    public Registry registry() {
        connectRemotesOnce();
        return new Registry(routeDefinitions(), buildOpenApiSpec(), this::handleRequest);
    }

    /**
     * One-time startup: connect remote servers, merge their tools ahead of local
     * ones (local overrides remote), and resolve the config icon.
     */
    private void connectRemotesOnce() {
        if (started) return;
        synchronized (this) {
            if (started) return;

            if (!remotes.isEmpty()) {
                var remoteTools = new RemoteManager().connect(remotes);
                var merged = new LinkedHashMap<String, NamedTool>();
                for (var entry : remoteTools.entrySet()) {
                    var tool = entry.getValue();
                    merged.put(entry.getKey(),
                        new NamedTool(entry.getKey(), tool, Schema.toJsonSchema(tool.inputs()), true));
                }
                for (var entry : tools.entrySet()) {
                    if (merged.containsKey(entry.getKey())) {
                        System.err.println("[zeromcp] Local tool \"" + entry.getKey() + "\" overrides remote");
                    }
                    merged.put(entry.getKey(), entry.getValue());
                }
                tools.clear();
                tools.putAll(merged);
            }

            if (!iconSet && config.icon() != null) {
                icon = Config.resolveIcon(config.icon());
            }

            started = true;
        }
    }

    private List<RouteDefinition> routeDefinitions() {
        var routes = new ArrayList<RouteDefinition>();
        for (var namedTool : tools.values()) {
            var route = namedTool.tool().route();
            if (route == null) continue;
            routes.add(new RouteDefinition(namedTool.name(), route.method(), route.path(), namedTool.tool()));
        }
        return List.copyOf(routes);
    }

    /**
     * Register a static resource.
     */
    public void resource(String name, ResourceDef resource) {
        resources.put(name, new NamedResource(name, resource));
    }

    /**
     * Register a prompt.
     */
    public void prompt(String name, PromptDef prompt) {
        prompts.put(name, new NamedPrompt(name, prompt));
    }

    /**
     * Build an OpenAPI 3.0 spec from all tools that have a route field.
     */
    private JsonObject buildOpenApiSpec() {
        var spec = new JsonObject();
        spec.addProperty("openapi", "3.0.0");

        var info = new JsonObject();
        info.addProperty("title", config.title());
        info.addProperty("version", "0.5.0");
        spec.add("info", info);

        var paths = new JsonObject();
        for (var entry : tools.entrySet()) {
            var toolName = entry.getKey();
            var namedTool = entry.getValue();
            var route = namedTool.tool().route();
            if (route == null) continue;

            // Extract :param names from the path pattern
            var pathParamNames = new ArrayList<String>();
            for (var segment : route.path().split("/", -1)) {
                if (segment.startsWith(":")) pathParamNames.add(segment.substring(1));
            }

            // Convert :param to {param} for OpenAPI path format
            var openApiPath = route.path().replaceAll(":([^/]+)", "{$1}");

            var operation = new JsonObject();
            operation.addProperty("operationId", toolName);
            var desc = namedTool.tool().description();
            if (desc != null && !desc.isEmpty()) operation.addProperty("description", desc);

            var isGet = "GET".equals(route.method());
            if (isGet) {
                var parameters = new JsonArray();
                for (var input : namedTool.tool().inputs()) {
                    var param = new JsonObject();
                    param.addProperty("name", input.name());
                    param.addProperty("in", pathParamNames.contains(input.name()) ? "path" : "query");
                    param.addProperty("required", !input.optional());
                    var paramSchema = new JsonObject();
                    paramSchema.addProperty("type", input.type().jsonType());
                    if (input.description() != null) paramSchema.addProperty("description", input.description());
                    param.add("schema", paramSchema);
                    parameters.add(param);
                }
                operation.add("parameters", parameters);
            } else {
                if (!pathParamNames.isEmpty()) {
                    var parameters = new JsonArray();
                    for (var pathParamName : pathParamNames) {
                        var param = new JsonObject();
                        param.addProperty("name", pathParamName);
                        param.addProperty("in", "path");
                        param.addProperty("required", true);
                        var paramSchema = new JsonObject();
                        paramSchema.addProperty("type", "string");
                        param.add("schema", paramSchema);
                        parameters.add(param);
                    }
                    operation.add("parameters", parameters);
                }

                var bodySchema = new JsonObject();
                bodySchema.addProperty("type", "object");
                var properties = new JsonObject();
                var required = new JsonArray();
                for (var input : namedTool.tool().inputs()) {
                    if (pathParamNames.contains(input.name())) continue;
                    var prop = new JsonObject();
                    prop.addProperty("type", input.type().jsonType());
                    if (input.description() != null) prop.addProperty("description", input.description());
                    properties.add(input.name(), prop);
                    if (!input.optional()) required.add(input.name());
                }
                bodySchema.add("properties", properties);
                bodySchema.add("required", required);

                var requestBody = new JsonObject();
                var content = new JsonObject();
                var mediaType = new JsonObject();
                mediaType.add("schema", bodySchema);
                content.add("application/json", mediaType);
                requestBody.add("content", content);
                operation.add("requestBody", requestBody);
            }

            var responses = new JsonObject();
            var r200 = new JsonObject();
            r200.addProperty("description", "Success");
            responses.add("200", r200);
            var r500 = new JsonObject();
            r500.addProperty("description", "Error");
            responses.add("500", r500);
            operation.add("responses", responses);

            var pathItem = new JsonObject();
            pathItem.add(route.method().toLowerCase(), operation);
            paths.add(openApiPath, pathItem);
        }

        spec.add("paths", paths);
        return spec;
    }

    /**
     * Start the stdio JSON-RPC server. Blocks until stdin closes.
     */
    public void serve() {
        var transport = config.transport();
        if (transport != null && !"stdio".equals(transport)) {
            throw new IllegalStateException("[zeromcp] transport \"" + transport + "\" is not supported: "
                + "ZeroMCP no longer ships an HTTP server. Mount ZeroMcp.registry() "
                + "(or handleRequest(JsonObject)) in your own HTTP server.");
        }
        connectRemotesOnce();

        System.err.println("[zeromcp] " + tools.size() + " tool(s), "
                + resources.size() + " resource(s), "
                + prompts.size() + " prompt(s) registered");
        System.err.println("[zeromcp] stdio transport ready");

        var reader = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
        var writer = new java.io.PrintWriter(new java.io.OutputStreamWriter(System.out, StandardCharsets.UTF_8), true);

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

    /**
     * Process a single JSON-RPC request and return a response.
     * Returns null for notifications that require no response.
     */
    public JsonObject handleRequest(JsonObject request) {
        connectRemotesOnce();
        var id = request.get("id");
        var method = request.has("method") ? request.get("method").getAsString() : "";
        var params = request.has("params") ? request.getAsJsonObject("params") : null;

        // Notifications (no id)
        if (id == null) {
            handleNotification(method, params);
            return null;
        }

        return switch (method) {
            case "initialize" -> buildResponse(id, initializeResult(params));
            case "ping" -> buildResponse(id, new JsonObject());

            // Tools
            case "tools/list" -> buildResponse(id, toolListResult(params));
            case "tools/call" -> buildResponse(id, callTool(params));

            // Resources
            case "resources/list" -> buildResponse(id, resourceListResult(params));
            case "resources/read" -> handleResourceRead(id, params);
            case "resources/subscribe" -> buildResponse(id, resourceSubscribe(params));
            case "resources/templates/list" -> buildResponse(id, resourceTemplatesListResult(params));

            // Prompts
            case "prompts/list" -> buildResponse(id, promptListResult(params));
            case "prompts/get" -> handlePromptGet(id, params);

            // Passthrough
            case "logging/setLevel" -> buildResponse(id, loggingSetLevel(params));
            case "completion/complete" -> buildResponse(id, completionComplete(params));

            default -> {
                yield buildErrorResponse(id, -32601, "Method not found: " + method);
            }
        };
    }

    // ---- Notifications ----

    private void handleNotification(String method, JsonObject params) {
        // notifications/initialized, notifications/roots/list_changed -- no-op for now
    }

    // ---- Initialize ----

    private JsonObject initializeResult(JsonObject params) {
        // Store client capabilities if provided
        if (params != null && params.has("capabilities")) {
            // Available for future use
        }

        var result = new JsonObject();
        result.addProperty("protocolVersion", "2024-11-05");

        var capabilities = new JsonObject();

        var toolsCap = new JsonObject();
        toolsCap.addProperty("listChanged", true);
        capabilities.add("tools", toolsCap);

        if (!resources.isEmpty()) {
            var resCap = new JsonObject();
            resCap.addProperty("subscribe", true);
            resCap.addProperty("listChanged", true);
            capabilities.add("resources", resCap);
        }

        if (!prompts.isEmpty()) {
            var promptsCap = new JsonObject();
            promptsCap.addProperty("listChanged", true);
            capabilities.add("prompts", promptsCap);
        }

        capabilities.add("logging", new JsonObject());

        result.add("capabilities", capabilities);

        var serverInfo = new JsonObject();
        serverInfo.addProperty("name", config.name());
        serverInfo.addProperty("version", config.version());
        result.add("serverInfo", serverInfo);

        return result;
    }

    // ---- Tools ----

    private JsonObject toolListResult(JsonObject params) {
        var cursor = params != null && params.has("cursor") ? params.get("cursor").getAsString() : null;

        var list = new ArrayList<JsonObject>();
        for (var entry : tools.entrySet()) {
            var obj = new JsonObject();
            obj.addProperty("name", entry.getKey());
            obj.addProperty("description", entry.getValue().tool().description());
            obj.add("inputSchema", entry.getValue().inputSchema());
            if (icon != null) {
                var icons = new JsonArray();
                var iconObj = new JsonObject();
                iconObj.addProperty("uri", icon);
                icons.add(iconObj);
                obj.add("icons", icons);
            }
            list.add(obj);
        }

        return paginatedResult("tools", list, cursor);
    }

    private JsonObject callTool(JsonObject params) {
        if (params == null) {
            return buildToolResult("No parameters provided", true);
        }

        var name = params.has("name") ? params.get("name").getAsString() : "";
        JsonObject argsJson;
        if (params.has("arguments") && params.get("arguments").isJsonObject()) {
            argsJson = params.getAsJsonObject("arguments");
        } else {
            argsJson = new JsonObject();
        }

        var namedTool = tools.get(name);
        if (namedTool == null) {
            return buildToolResult("Unknown tool: " + name, true);
        }

        var tool = namedTool.tool();
        var argsMap = jsonObjectToMap(argsJson);

        var errors = Schema.validate(argsMap, namedTool.inputSchema());
        if (!errors.isEmpty()) {
            return buildToolResult("Validation errors:\n" + String.join("\n", errors), true);
        }

        try {
            var runtime = !namedTool.remote() && runtimeSupplier != null ? runtimeSupplier.get() : null;
            var ctx = new Ctx(name, tool.permissions(), runtime);

            long timeoutMs = tool.permissions().executeTimeout() > 0
                ? tool.permissions().executeTimeout()
                : config.executeTimeout();

            var future = CompletableFuture.supplyAsync(() -> {
                try {
                    return tool.executor().execute(argsMap, ctx);
                } catch (Exception ex) {
                    throw new CompletionException(ex);
                }
            });

            Object result;
            try {
                result = future.get(timeoutMs, TimeUnit.MILLISECONDS);
            } catch (TimeoutException te) {
                future.cancel(true);
                return buildToolResult("Tool \"" + name + "\" timed out after " + timeoutMs + "ms", true);
            }

            var text = result instanceof String s ? s
                : result == null ? "null"
                : gson.toJson(result);
            return buildToolResult(text, false);
        } catch (Exception e) {
            var cause = e instanceof ExecutionException ? e.getCause() : e;
            return buildToolResult("Error: " + (cause != null ? cause.getMessage() : e.getMessage()), true);
        }
    }

    // ---- Resources ----

    private JsonObject resourceListResult(JsonObject params) {
        var cursor = params != null && params.has("cursor") ? params.get("cursor").getAsString() : null;

        var list = new ArrayList<JsonObject>();
        for (var entry : resources.entrySet()) {
            var res = entry.getValue().resource();
            var obj = new JsonObject();
            obj.addProperty("uri", res.uri());
            obj.addProperty("name", entry.getKey());
            obj.addProperty("description", res.description());
            obj.addProperty("mimeType", res.mimeType());
            if (icon != null) {
                var icons = new JsonArray();
                var iconObj = new JsonObject();
                iconObj.addProperty("uri", icon);
                icons.add(iconObj);
                obj.add("icons", icons);
            }
            list.add(obj);
        }

        return paginatedResult("resources", list, cursor);
    }

    private JsonObject handleResourceRead(JsonElement id, JsonObject params) {
        var uri = params != null && params.has("uri") ? params.get("uri").getAsString() : "";

        for (var entry : resources.entrySet()) {
            var res = entry.getValue().resource();
            if (res.uri().equals(uri)) {
                try {
                    var text = res.reader().read();
                    var result = new JsonObject();
                    var contents = new JsonArray();
                    var item = new JsonObject();
                    item.addProperty("uri", uri);
                    item.addProperty("mimeType", res.mimeType());
                    item.addProperty("text", text);
                    contents.add(item);
                    result.add("contents", contents);
                    return buildResponse(id, result);
                } catch (Exception e) {
                    return buildErrorResponse(id, -32603, "Error reading resource: " + e.getMessage());
                }
            }
        }

        return buildErrorResponse(id, -32002, "Resource not found: " + uri);
    }

    private JsonObject resourceSubscribe(JsonObject params) {
        if (params != null && params.has("uri")) {
            subscriptions.add(params.get("uri").getAsString());
        }
        return new JsonObject();
    }

    private JsonObject resourceTemplatesListResult(JsonObject params) {
        var cursor = params != null && params.has("cursor") ? params.get("cursor").getAsString() : null;
        // No template support yet in code-registration mode, but return empty paginated list
        return paginatedResult("resourceTemplates", new ArrayList<>(), cursor);
    }

    // ---- Prompts ----

    private JsonObject promptListResult(JsonObject params) {
        var cursor = params != null && params.has("cursor") ? params.get("cursor").getAsString() : null;

        var list = new ArrayList<JsonObject>();
        for (var entry : prompts.entrySet()) {
            var prompt = entry.getValue().prompt();
            var obj = new JsonObject();
            obj.addProperty("name", entry.getKey());
            if (prompt.description() != null && !prompt.description().isEmpty()) {
                obj.addProperty("description", prompt.description());
            }
            if (!prompt.arguments().isEmpty()) {
                var argsArray = new JsonArray();
                for (var arg : prompt.arguments()) {
                    var argObj = new JsonObject();
                    argObj.addProperty("name", arg.name());
                    if (arg.description() != null && !arg.description().isEmpty()) {
                        argObj.addProperty("description", arg.description());
                    }
                    argObj.addProperty("required", arg.required());
                    argsArray.add(argObj);
                }
                obj.add("arguments", argsArray);
            }
            if (icon != null) {
                var icons = new JsonArray();
                var iconObj = new JsonObject();
                iconObj.addProperty("uri", icon);
                icons.add(iconObj);
                obj.add("icons", icons);
            }
            list.add(obj);
        }

        return paginatedResult("prompts", list, cursor);
    }

    private JsonObject handlePromptGet(JsonElement id, JsonObject params) {
        var name = params != null && params.has("name") ? params.get("name").getAsString() : "";
        var argsJson = params != null && params.has("arguments") && params.get("arguments").isJsonObject()
            ? params.getAsJsonObject("arguments")
            : new JsonObject();

        var namedPrompt = prompts.get(name);
        if (namedPrompt == null) {
            return buildErrorResponse(id, -32002, "Prompt not found: " + name);
        }

        try {
            var messages = namedPrompt.prompt().renderer().render(jsonObjectToMap(argsJson));

            var result = new JsonObject();
            var messagesArray = new JsonArray();
            for (var msg : messages) {
                var msgObj = new JsonObject();
                msgObj.addProperty("role", msg.role());
                var content = new JsonObject();
                content.addProperty("type", "text");
                content.addProperty("text", msg.text());
                msgObj.add("content", content);
                messagesArray.add(msgObj);
            }
            result.add("messages", messagesArray);
            return buildResponse(id, result);
        } catch (Exception e) {
            return buildErrorResponse(id, -32603, "Error rendering prompt: " + e.getMessage());
        }
    }

    // ---- Passthrough methods ----

    private JsonObject loggingSetLevel(JsonObject params) {
        if (params != null && params.has("level")) {
            logLevel = params.get("level").getAsString();
        }
        return new JsonObject();
    }

    private JsonObject completionComplete(JsonObject params) {
        var result = new JsonObject();
        var completion = new JsonObject();
        completion.add("values", new JsonArray());
        result.add("completion", completion);
        return result;
    }

    // ---- Pagination ----

    private JsonObject paginatedResult(String key, List<JsonObject> items, String cursor) {
        if (pageSize <= 0) {
            var result = new JsonObject();
            var array = new JsonArray();
            items.forEach(array::add);
            result.add(key, array);
            return result;
        }

        int offset = cursor != null ? decodeCursor(cursor) : 0;
        int end = Math.min(offset + pageSize, items.size());
        boolean hasMore = end < items.size();

        var result = new JsonObject();
        var array = new JsonArray();
        for (int i = offset; i < end; i++) {
            array.add(items.get(i));
        }
        result.add(key, array);

        if (hasMore) {
            result.addProperty("nextCursor", encodeCursor(end));
        }

        return result;
    }

    private static String encodeCursor(int offset) {
        return Base64.getEncoder().encodeToString(String.valueOf(offset).getBytes(StandardCharsets.UTF_8));
    }

    private static int decodeCursor(String cursor) {
        try {
            var decoded = new String(Base64.getDecoder().decode(cursor), StandardCharsets.UTF_8);
            int offset = Integer.parseInt(decoded);
            return offset < 0 ? 0 : offset;
        } catch (Exception e) {
            return 0;
        }
    }

    // ---- Response builders ----

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

    // ---- JSON utilities ----

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

    // ---- Inner records ----

    private record NamedTool(String name, Tool tool, JsonObject inputSchema, boolean remote) {}
    private record NamedResource(String name, ResourceDef resource) {}
    private record NamedPrompt(String name, PromptDef prompt) {}
}
