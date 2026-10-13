package io.antidrift.zeromcp;

import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import com.sun.net.httpserver.HttpServer;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * Fake remote MCP server for tests: answers initialize, tools/list
 * (list_pages, get_page) and tools/call, and records what it saw.
 */
final class FakeUpstream implements AutoCloseable {
    final HttpServer server;
    final List<String> calledNames = new CopyOnWriteArrayList<>();
    final List<String> authHeaders = new CopyOnWriteArrayList<>();
    final List<String> methods = new CopyOnWriteArrayList<>();

    FakeUpstream() throws IOException {
        this(200);
    }

    FakeUpstream(int status) throws IOException {
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/mcp", exchange -> {
            var body = new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
            var auth = exchange.getRequestHeaders().getFirst("Authorization");
            authHeaders.add(auth == null ? "" : auth);

            String out;
            if (status != 200) {
                out = "{\"error\":\"nope\"}";
            } else {
                var req = JsonParser.parseString(body).getAsJsonObject();
                var method = req.get("method").getAsString();
                methods.add(method);
                var result = new JsonObject();
                switch (method) {
                    case "initialize" -> result.addProperty("protocolVersion", "2024-11-05");
                    case "tools/list" -> {
                        var tools = new JsonArray();
                        tools.add(tool("list_pages", "List pages", null));
                        tools.add(tool("get_page", "Get a page", "id"));
                        result.add("tools", tools);
                    }
                    case "tools/call" -> {
                        var params = req.getAsJsonObject("params");
                        var name = params.get("name").getAsString();
                        calledNames.add(name);
                        var content = new JsonArray();
                        var item = new JsonObject();
                        item.addProperty("type", "text");
                        item.addProperty("text", "upstream:" + name + ":" + params.get("arguments"));
                        content.add(item);
                        result.add("content", content);
                    }
                    default -> { }
                }
                var resp = new JsonObject();
                resp.addProperty("jsonrpc", "2.0");
                resp.add("id", req.get("id"));
                resp.add("result", result);
                out = resp.toString();
            }

            var bytes = out.getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().set("Content-Type", "application/json");
            exchange.sendResponseHeaders(status, bytes.length);
            try (var os = exchange.getResponseBody()) { os.write(bytes); }
        });
        server.start();
    }

    String url() {
        return "http://127.0.0.1:" + server.getAddress().getPort() + "/mcp";
    }

    private static JsonObject tool(String name, String description, String requiredProp) {
        var t = new JsonObject();
        t.addProperty("name", name);
        t.addProperty("description", description);
        var schema = new JsonObject();
        schema.addProperty("type", "object");
        var props = new JsonObject();
        var required = new JsonArray();
        if (requiredProp != null) {
            var p = new JsonObject();
            p.addProperty("type", "string");
            props.add(requiredProp, p);
            required.add(requiredProp);
        }
        schema.add("properties", props);
        schema.add("required", required);
        t.add("inputSchema", schema);
        return t;
    }

    static JsonObject request(String method, JsonObject params) {
        var req = new JsonObject();
        req.addProperty("jsonrpc", "2.0");
        req.addProperty("id", 1);
        req.addProperty("method", method);
        if (params != null) req.add("params", params);
        return req;
    }

    static JsonObject callParams(String name, JsonObject args) {
        var params = new JsonObject();
        params.addProperty("name", name);
        params.add("arguments", args != null ? args : new JsonObject());
        return params;
    }

    static List<String> toolNames(JsonObject response) {
        var names = new java.util.ArrayList<String>();
        for (var t : response.getAsJsonObject("result").getAsJsonArray("tools")) {
            names.add(t.getAsJsonObject().get("name").getAsString());
        }
        return names;
    }

    static String text(JsonObject response) {
        return response.getAsJsonObject("result").getAsJsonArray("content")
            .get(0).getAsJsonObject().get("text").getAsString();
    }

    @Override
    public void close() {
        server.stop(0);
    }
}
