import com.google.gson.Gson;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import io.antidrift.zeromcp.*;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.Executors;

/**
 * Route conformance harness (test-only). ZeroMCP has no built-in HTTP server,
 * so this mounts {@code server.registry()} on a JDK HttpServer the way a user
 * would mount it in their own framework.
 */
public class RouteTest {
    private static final Gson GSON = new Gson();

    public static void main(String[] args) throws Exception {
        var server = new ZeroMcp();

        server.tool("greet", Tool.builder()
            .description("Greet a person by name")
            .input(Input.required("name", "string", "The person to greet"))
            .route("GET", "/greet/:name")
            .execute((a, ctx) -> "Hello, " + a.get("name") + "!")
            .build());

        server.tool("echo", Tool.builder()
            .description("Echo a message back")
            .input(Input.required("message", "string", "The message to echo"))
            .route("POST", "/echo")
            .execute((a, ctx) -> java.util.Map.of(
                "message", a.get("message"),
                "echoed", true
            ))
            .build());

        var registry = server.registry();
        var http = HttpServer.create(new InetSocketAddress(14256), 0);

        http.createContext("/", exchange -> {
            try {
                handle(registry, exchange);
            } catch (Exception e) {
                var resp = new JsonObject();
                resp.addProperty("ok", false);
                resp.addProperty("error", e.getMessage() != null ? e.getMessage() : "Internal error");
                send(exchange, 500, "application/json", GSON.toJson(resp));
            }
        });

        http.setExecutor(Executors.newCachedThreadPool());
        http.start();
        System.err.println("[route-test] listening on port 14256");
    }

    private static void handle(Registry registry, HttpExchange exchange) throws Exception {
        var method = exchange.getRequestMethod().toUpperCase();
        var path = exchange.getRequestURI().getPath();

        if (path.equals("/mcp") && method.equals("POST")) {
            var body = new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
            JsonObject request;
            try {
                request = JsonParser.parseString(body).getAsJsonObject();
            } catch (Exception e) {
                send(exchange, 400, "application/json", "{\"error\":\"Bad Request\"}");
                return;
            }
            var response = registry.mcp().handle(request);
            send(exchange, 200, "application/json", response != null ? GSON.toJson(response) : "{}");
            return;
        }

        if (path.equals("/openapi.json") && method.equals("GET")) {
            send(exchange, 200, "application/json", GSON.toJson(registry.openapi()));
            return;
        }

        if (path.equals("/docs") && method.equals("GET")) {
            var html = "<!DOCTYPE html>\n<html>\n<head>\n"
                + "  <title>ZeroMCP API</title>\n"
                + "  <meta charset=\"utf-8\"/>\n"
                + "  <link rel=\"stylesheet\" href=\"https://unpkg.com/swagger-ui-dist/swagger-ui.css\">\n"
                + "</head>\n<body>\n"
                + "<div id=\"swagger-ui\"></div>\n"
                + "<script src=\"https://unpkg.com/swagger-ui-dist/swagger-ui-bundle.js\"></script>\n"
                + "<script>SwaggerUIBundle({ url: '/openapi.json', dom_id: '#swagger-ui' })</script>\n"
                + "</body>\n</html>";
            send(exchange, 200, "text/html; charset=utf-8", html);
            return;
        }

        for (var route : registry.routes()) {
            if (!route.method().equals(method)) continue;
            var params = matchPath(route.path(), path);
            if (params == null) continue;

            var toolArgs = new LinkedHashMap<String, Object>(params);
            if (method.equals("GET")) {
                var query = exchange.getRequestURI().getRawQuery();
                if (query != null) toolArgs.putAll(parseQuery(query));
            } else {
                var body = new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
                if (!body.isBlank()) {
                    var parsed = JsonParser.parseString(body);
                    if (parsed.isJsonObject()) {
                        @SuppressWarnings("unchecked")
                        Map<String, Object> bodyMap = GSON.fromJson(parsed, Map.class);
                        toolArgs.putAll(bodyMap);
                    }
                }
            }

            var ctx = new Ctx(route.name(), route.tool().permissions());
            var result = route.tool().executor().execute(toolArgs, ctx);

            var resp = new JsonObject();
            resp.addProperty("ok", true);
            if (result instanceof String s) resp.addProperty("result", s);
            else resp.add("result", GSON.toJsonTree(result));
            send(exchange, 200, "application/json", GSON.toJson(resp));
            return;
        }

        send(exchange, 404, "application/json", "{\"ok\":false,\"error\":\"Not Found\"}");
    }

    /** Match a path against a route pattern with :param segments; null if no match. */
    private static Map<String, Object> matchPath(String pattern, String path) {
        var patternParts = pattern.split("/", -1);
        var pathParts = path.split("/", -1);
        if (patternParts.length != pathParts.length) return null;
        var params = new LinkedHashMap<String, Object>();
        for (int i = 0; i < patternParts.length; i++) {
            if (patternParts[i].startsWith(":")) {
                params.put(patternParts[i].substring(1), URLDecoder.decode(pathParts[i], StandardCharsets.UTF_8));
            } else if (!patternParts[i].equals(pathParts[i])) {
                return null;
            }
        }
        return params;
    }

    private static Map<String, Object> parseQuery(String query) {
        var map = new LinkedHashMap<String, Object>();
        for (var pair : query.split("&")) {
            if (pair.isEmpty()) continue;
            var idx = pair.indexOf('=');
            if (idx < 0) {
                map.put(URLDecoder.decode(pair, StandardCharsets.UTF_8), "");
            } else {
                map.put(URLDecoder.decode(pair.substring(0, idx), StandardCharsets.UTF_8),
                    URLDecoder.decode(pair.substring(idx + 1), StandardCharsets.UTF_8));
            }
        }
        return map;
    }

    private static void send(HttpExchange exchange, int status, String contentType, String body) throws IOException {
        var bytes = body.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().set("Content-Type", contentType);
        exchange.sendResponseHeaders(status, bytes.length);
        try (var os = exchange.getResponseBody()) {
            os.write(bytes);
        }
    }
}
