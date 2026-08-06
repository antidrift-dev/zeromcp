package io.antidrift.zeromcp;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class RegistryTest {

    private static Config testConfig() {
        return Config.load("/nonexistent"); // returns defaults
    }

    private static Tool routedTool(String method, String path) {
        return Tool.builder()
            .description("Greet someone")
            .input(Input.required("name", "string"))
            .route(method, path)
            .execute((args, ctx) -> "hi " + args.get("name"))
            .build();
    }

    private static Tool unroutedTool() {
        return Tool.builder()
            .description("No route")
            .execute((args, ctx) -> null)
            .build();
    }

    @Test
    void routesOnlyIncludesRoutedTools() {
        var server = new ZeroMcp(testConfig());
        server.tool("greet", routedTool("GET", "/greet/:name"));
        server.tool("hidden", unroutedTool());

        var registry = server.registry();
        assertEquals(1, registry.routes().size());
        assertEquals("greet", registry.routes().get(0).name());
        assertEquals("GET", registry.routes().get(0).method());
        assertEquals("/greet/:name", registry.routes().get(0).path());
    }

    @Test
    void routesPreserveInsertionOrder() {
        var server = new ZeroMcp(testConfig());
        server.tool("charlie", routedTool("GET", "/charlie"));
        server.tool("alpha", routedTool("GET", "/alpha"));
        server.tool("bravo", routedTool("GET", "/bravo"));

        var registry = server.registry();
        assertEquals(3, registry.routes().size());
        assertEquals("charlie", registry.routes().get(0).name());
        assertEquals("alpha", registry.routes().get(1).name());
        assertEquals("bravo", registry.routes().get(2).name());
    }

    @Test
    void openapiMatchesRoutedTools() {
        var server = new ZeroMcp(testConfig());
        server.tool("greet", routedTool("GET", "/greet/:name"));

        var registry = server.registry();
        var paths = registry.openapi().getAsJsonObject("paths");
        assertTrue(paths.has("/greet/{name}"));
    }

    @Test
    void routeToolInvokedDirectlyProducesExpectedResult() throws Exception {
        var server = new ZeroMcp(testConfig());
        server.tool("greet", routedTool("GET", "/greet/:name"));

        var registry = server.registry();
        var route = registry.routes().get(0);
        var ctx = new Ctx(route.name(), route.tool().permissions());
        var result = route.tool().executor().execute(java.util.Map.of("name", "Ada"), ctx);
        assertEquals("hi Ada", result);
    }

    @Test
    void mcpDispatchesToolsList() {
        var server = new ZeroMcp(testConfig());
        server.tool("greet", routedTool("GET", "/greet/:name"));

        var registry = server.registry();
        var request = new com.google.gson.JsonObject();
        request.addProperty("jsonrpc", "2.0");
        request.addProperty("id", 1);
        request.addProperty("method", "tools/list");

        var response = registry.mcp().handle(request);
        var tools = response.getAsJsonObject("result").getAsJsonArray("tools");
        assertEquals(1, tools.size());
        assertEquals("greet", tools.get(0).getAsJsonObject().get("name").getAsString());
    }

    @Test
    void mcpDispatchesToolsCall() {
        var server = new ZeroMcp(testConfig());
        server.tool("greet", routedTool("POST", "/greet"));

        var registry = server.registry();
        var params = new com.google.gson.JsonObject();
        params.addProperty("name", "greet");
        var args = new com.google.gson.JsonObject();
        args.addProperty("name", "Ada");
        params.add("arguments", args);

        var request = new com.google.gson.JsonObject();
        request.addProperty("jsonrpc", "2.0");
        request.addProperty("id", 1);
        request.addProperty("method", "tools/call");
        request.add("params", params);

        var response = registry.mcp().handle(request);
        var content = response.getAsJsonObject("result").getAsJsonArray("content");
        assertEquals("hi Ada", content.get(0).getAsJsonObject().get("text").getAsString());
    }

    @Test
    void emptyWhenNoRoutedTools() {
        var server = new ZeroMcp(testConfig());
        server.tool("hidden", unroutedTool());

        var registry = server.registry();
        assertEquals(0, registry.routes().size());
    }
}
