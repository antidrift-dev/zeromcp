package io.antidrift.zeromcp;

import com.google.gson.Gson;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Connects to remote MCP servers over HTTP and exposes their tools as local
 * {@link Tool}s. Ported from nodejs/src/remote.ts.
 */
final class RemoteManager {

    private static final Gson GSON = new Gson();
    private final HttpClient client = HttpClient.newHttpClient();

    /** Returns tools keyed {@code <server>.<tool>}, in server then upstream order. */
    Map<String, Tool> connect(List<RemoteServer> servers) {
        var allTools = new LinkedHashMap<String, Tool>();
        for (var server : servers) {
            try {
                var tools = connectOne(server);
                for (var entry : tools.entrySet()) {
                    var namespacedName = server.name() + "." + entry.getKey();
                    allTools.put(namespacedName, entry.getValue());
                    System.err.println("[mcp] Remote tool: " + namespacedName);
                }
            } catch (Exception e) {
                System.err.println("[mcp] Failed to connect to " + server.name() + ": " + e.getMessage());
            }
        }
        return allTools;
    }

    private Map<String, Tool> connectOne(RemoteServer server) throws Exception {
        var url = server.url();
        if (url == null || !(url.startsWith("http://") || url.startsWith("https://"))) {
            throw new IllegalArgumentException("Remote server \"" + server.name()
                + "\" must have an HTTP/HTTPS URL, got: " + url);
        }
        return connectHttp(server);
    }

    private Map<String, Tool> connectHttp(RemoteServer server) throws Exception {
        var tools = new LinkedHashMap<String, Tool>();
        var auth = Config.resolveAuth(server.auth());

        httpRpc(server.url(), rpc(1, "initialize", new JsonObject()), auth);
        var listRes = httpRpc(server.url(), rpc(2, "tools/list", new JsonObject()), auth);

        var remoteTools = new ArrayList<JsonObject>();
        var result = objectAt(listRes, "result");
        if (result != null && result.has("tools") && result.get("tools").isJsonArray()) {
            for (var t : result.getAsJsonArray("tools")) {
                if (!t.isJsonObject()) continue;
                var obj = t.getAsJsonObject();
                var toolName = stringAt(obj, "name");
                if (server.tools() != null && !server.tools().contains(toolName)) continue;
                remoteTools.add(obj);
            }
        }

        for (var rt : remoteTools) {
            var upstreamName = stringAt(rt, "name");
            var inputs = schemaToInput(objectAt(rt, "inputSchema"));
            var url = server.url();
            ToolExecutor executor = (args, ctx) -> {
                var params = new JsonObject();
                params.addProperty("name", upstreamName);
                params.add("arguments", GSON.toJsonTree(args));
                var callRes = httpRpc(url, rpc(System.currentTimeMillis(), "tools/call", params), auth);
                var callResult = callRes != null && callRes.has("result") ? callRes.get("result") : null;
                if (callResult != null && callResult.isJsonObject()) {
                    var content = callResult.getAsJsonObject().get("content");
                    if (content != null && content.isJsonArray() && content.getAsJsonArray().size() > 0) {
                        var first = content.getAsJsonArray().get(0);
                        if (first.isJsonObject()) {
                            var text = first.getAsJsonObject().get("text");
                            if (text != null && text.isJsonPrimitive() && !text.getAsString().isEmpty()) {
                                return text.getAsString();
                            }
                        }
                    }
                }
                return callResult;
            };
            tools.put(upstreamName, new Tool(stringAt(rt, "description"), inputs, Permissions.of(), executor, null));
        }

        System.err.println("[mcp] Connected to " + server.name() + " (HTTP): " + tools.size() + " tool(s)");
        return tools;
    }

    private JsonObject httpRpc(String url, JsonObject body, String auth) throws Exception {
        var builder = HttpRequest.newBuilder(URI.create(url))
            .header("Content-Type", "application/json")
            .POST(HttpRequest.BodyPublishers.ofString(GSON.toJson(body), StandardCharsets.UTF_8));
        if (auth != null && !auth.isEmpty()) builder.header("Authorization", "Bearer " + auth);

        var res = client.send(builder.build(), HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
        if (res.statusCode() < 200 || res.statusCode() > 299) {
            throw new RuntimeException("HTTP " + res.statusCode());
        }
        var parsed = JsonParser.parseString(res.body());
        return parsed.isJsonObject() ? parsed.getAsJsonObject() : null;
    }

    private static JsonObject rpc(long id, String method, JsonObject params) {
        var req = new JsonObject();
        req.addProperty("jsonrpc", "2.0");
        req.addProperty("id", id);
        req.addProperty("method", method);
        req.add("params", params);
        return req;
    }

    private static List<Input> schemaToInput(JsonObject schema) {
        var inputs = new ArrayList<Input>();
        if (schema == null) return inputs;
        var properties = objectAt(schema, "properties");
        if (properties == null) return inputs;

        var required = new HashSet<String>();
        if (schema.has("required") && schema.get("required").isJsonArray()) {
            for (var r : schema.getAsJsonArray("required")) {
                if (r.isJsonPrimitive()) required.add(r.getAsString());
            }
        }

        for (var entry : properties.entrySet()) {
            var key = entry.getKey();
            var prop = entry.getValue().isJsonObject() ? entry.getValue().getAsJsonObject() : new JsonObject();
            var type = stringAt(prop, "type");
            if (type == null || type.isEmpty()) type = "string";
            var description = stringAt(prop, "description");
            if (description != null && description.isEmpty()) description = null;
            inputs.add(new Input(key, SimpleType.fromString(type), description, !required.contains(key)));
        }
        return inputs;
    }

    private static JsonObject objectAt(JsonObject obj, String key) {
        if (obj == null) return null;
        JsonElement el = obj.get(key);
        return el != null && el.isJsonObject() ? el.getAsJsonObject() : null;
    }

    private static String stringAt(JsonObject obj, String key) {
        if (obj == null) return null;
        JsonElement el = obj.get(key);
        return el != null && el.isJsonPrimitive() ? el.getAsString() : null;
    }
}
