package io.antidrift.zeromcp;

import com.google.gson.*;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

/**
 * Comprehensive tests for ZeroMcp server dispatch, pagination, resources,
 * prompts, template URIs, logging, initialize capabilities, and icon support.
 */
class ZeroMcpTest {

    // ---- Helpers ----

    private static Config testConfig() {
        return Config.load("/nonexistent"); // returns defaults
    }

    private static ZeroMcp serverWithTools() {
        var server = new ZeroMcp(testConfig());
        server.tool("echo", Tool.builder()
            .description("Echo input")
            .input(Input.required("msg", "string"))
            .execute((args, ctx) -> args.get("msg"))
            .build());
        server.tool("add", Tool.builder()
            .description("Add two numbers")
            .input(Input.required("a", "number"), Input.required("b", "number"))
            .execute((args, ctx) -> {
                var a = ((Number) args.get("a")).doubleValue();
                var b = ((Number) args.get("b")).doubleValue();
                return a + b;
            })
            .build());
        return server;
    }

    private static ZeroMcp serverWithResources() {
        var server = new ZeroMcp(testConfig());
        server.resource("settings", ResourceDef.builder()
            .uri("config://app/settings")
            .description("Application settings")
            .mimeType("application/json")
            .read(() -> "{\"theme\":\"dark\"}")
            .build());
        server.resource("readme", ResourceDef.builder()
            .uri("file://readme.txt")
            .description("README file")
            .mimeType("text/plain")
            .read(() -> "Hello World")
            .build());
        return server;
    }

    private static ZeroMcp serverWithPrompts() {
        var server = new ZeroMcp(testConfig());
        server.prompt("summarize", PromptDef.builder()
            .description("Summarize a topic")
            .argument(PromptArgument.required("topic", "The topic"))
            .render(args -> List.of(new PromptMessage("user", "Summarize: " + args.get("topic"))))
            .build());
        server.prompt("translate", PromptDef.builder()
            .description("Translate text")
            .argument(PromptArgument.required("text", "Text to translate"))
            .argument(PromptArgument.optional("lang", "Target language"))
            .render(args -> {
                var lang = args.getOrDefault("lang", "French");
                return List.of(
                    new PromptMessage("user", "Translate to " + lang + ": " + args.get("text")),
                    new PromptMessage("assistant", "Sure, translating...")
                );
            })
            .build());
        return server;
    }

    private static JsonObject makeRequest(String method, JsonElement id, JsonObject params) {
        var req = new JsonObject();
        req.addProperty("jsonrpc", "2.0");
        if (id != null) req.add("id", id);
        req.addProperty("method", method);
        if (params != null) req.add("params", params);
        return req;
    }

    private static JsonObject makeRequest(String method, int id) {
        return makeRequest(method, new JsonPrimitive(id), null);
    }

    private static JsonObject makeRequest(String method, int id, JsonObject params) {
        return makeRequest(method, new JsonPrimitive(id), params);
    }

    // ===================================================================
    // 1. Pagination: encode/decode cursor, paginate with various sizes
    // ===================================================================

    @Test
    void paginationDisabledReturnsAllTools() {
        var server = serverWithTools();
        var resp = server.handleRequest(makeRequest("tools/list", 1));
        var tools = resp.getAsJsonObject("result").getAsJsonArray("tools");
        assertEquals(2, tools.size());
        assertFalse(resp.getAsJsonObject("result").has("nextCursor"));
    }

    @Test
    void paginationPageSizeOneReturnsFirstPage() {
        var server = serverWithTools();
        server.pageSize(1);
        var resp = server.handleRequest(makeRequest("tools/list", 1));
        var result = resp.getAsJsonObject("result");
        var tools = result.getAsJsonArray("tools");
        assertEquals(1, tools.size());
        assertEquals("echo", tools.get(0).getAsJsonObject().get("name").getAsString());
        assertTrue(result.has("nextCursor"));
    }

    @Test
    void paginationSecondPageReturnsRemainingItems() {
        var server = serverWithTools();
        server.pageSize(1);

        // Get first page to obtain cursor
        var resp1 = server.handleRequest(makeRequest("tools/list", 1));
        var cursor = resp1.getAsJsonObject("result").get("nextCursor").getAsString();

        // Get second page using cursor
        var params = new JsonObject();
        params.addProperty("cursor", cursor);
        var resp2 = server.handleRequest(makeRequest("tools/list", 2, params));
        var result2 = resp2.getAsJsonObject("result");
        var tools = result2.getAsJsonArray("tools");
        assertEquals(1, tools.size());
        assertEquals("add", tools.get(0).getAsJsonObject().get("name").getAsString());
        assertFalse(result2.has("nextCursor"));
    }

    @Test
    void paginationLargerThanItemCountReturnsAll() {
        var server = serverWithTools();
        server.pageSize(100);
        var resp = server.handleRequest(makeRequest("tools/list", 1));
        var result = resp.getAsJsonObject("result");
        assertEquals(2, result.getAsJsonArray("tools").size());
        assertFalse(result.has("nextCursor"));
    }

    @Test
    void paginationInvalidCursorDefaultsToZero() {
        var server = serverWithTools();
        server.pageSize(1);

        var params = new JsonObject();
        params.addProperty("cursor", "not-valid-base64!!!");
        var resp = server.handleRequest(makeRequest("tools/list", 1, params));
        var tools = resp.getAsJsonObject("result").getAsJsonArray("tools");
        // Should fallback to offset 0
        assertEquals(1, tools.size());
        assertEquals("echo", tools.get(0).getAsJsonObject().get("name").getAsString());
    }

    @Test
    void paginationWorksForResources() {
        var server = serverWithResources();
        server.pageSize(1);
        var resp = server.handleRequest(makeRequest("resources/list", 1));
        var result = resp.getAsJsonObject("result");
        assertEquals(1, result.getAsJsonArray("resources").size());
        assertTrue(result.has("nextCursor"));
    }

    @Test
    void paginationWorksForPrompts() {
        var server = serverWithPrompts();
        server.pageSize(1);
        var resp = server.handleRequest(makeRequest("prompts/list", 1));
        var result = resp.getAsJsonObject("result");
        assertEquals(1, result.getAsJsonArray("prompts").size());
        assertTrue(result.has("nextCursor"));
    }

    @Test
    void paginationCursorRoundTrips() {
        // Verify that paginating through all pages yields all items
        var server = serverWithTools();
        // Add a third tool
        server.tool("noop", Tool.builder()
            .description("No-op")
            .execute((args, ctx) -> "ok")
            .build());
        server.pageSize(2);

        var resp1 = server.handleRequest(makeRequest("tools/list", 1));
        var result1 = resp1.getAsJsonObject("result");
        assertEquals(2, result1.getAsJsonArray("tools").size());
        assertTrue(result1.has("nextCursor"));

        var params = new JsonObject();
        params.addProperty("cursor", result1.get("nextCursor").getAsString());
        var resp2 = server.handleRequest(makeRequest("tools/list", 2, params));
        var result2 = resp2.getAsJsonObject("result");
        assertEquals(1, result2.getAsJsonArray("tools").size());
        assertFalse(result2.has("nextCursor"));
    }

    // ===================================================================
    // 2. Resource registration and list
    // ===================================================================

    @Test
    void resourceListReturnsAllResources() {
        var server = serverWithResources();
        var resp = server.handleRequest(makeRequest("resources/list", 1));
        var resources = resp.getAsJsonObject("result").getAsJsonArray("resources");
        assertEquals(2, resources.size());

        var first = resources.get(0).getAsJsonObject();
        assertEquals("config://app/settings", first.get("uri").getAsString());
        assertEquals("settings", first.get("name").getAsString());
        assertEquals("Application settings", first.get("description").getAsString());
        assertEquals("application/json", first.get("mimeType").getAsString());
    }

    @Test
    void resourceListEmptyServerReturnsEmptyArray() {
        var server = new ZeroMcp(testConfig());
        var resp = server.handleRequest(makeRequest("resources/list", 1));
        var resources = resp.getAsJsonObject("result").getAsJsonArray("resources");
        assertEquals(0, resources.size());
    }

    @Test
    void resourceRegistrationPreservesOrder() {
        var server = serverWithResources();
        var resp = server.handleRequest(makeRequest("resources/list", 1));
        var resources = resp.getAsJsonObject("result").getAsJsonArray("resources");
        assertEquals("settings", resources.get(0).getAsJsonObject().get("name").getAsString());
        assertEquals("readme", resources.get(1).getAsJsonObject().get("name").getAsString());
    }

    // ===================================================================
    // 3. Prompt registration, list, and get
    // ===================================================================

    @Test
    void promptListReturnsAllPrompts() {
        var server = serverWithPrompts();
        var resp = server.handleRequest(makeRequest("prompts/list", 1));
        var prompts = resp.getAsJsonObject("result").getAsJsonArray("prompts");
        assertEquals(2, prompts.size());
    }

    @Test
    void promptListIncludesArguments() {
        var server = serverWithPrompts();
        var resp = server.handleRequest(makeRequest("prompts/list", 1));
        var prompts = resp.getAsJsonObject("result").getAsJsonArray("prompts");

        // Find the "translate" prompt which has both required and optional args
        JsonObject translatePrompt = null;
        for (var p : prompts) {
            if (p.getAsJsonObject().get("name").getAsString().equals("translate")) {
                translatePrompt = p.getAsJsonObject();
                break;
            }
        }
        assertNotNull(translatePrompt);
        var args = translatePrompt.getAsJsonArray("arguments");
        assertEquals(2, args.size());

        var textArg = args.get(0).getAsJsonObject();
        assertEquals("text", textArg.get("name").getAsString());
        assertTrue(textArg.get("required").getAsBoolean());

        var langArg = args.get(1).getAsJsonObject();
        assertEquals("lang", langArg.get("name").getAsString());
        assertFalse(langArg.get("required").getAsBoolean());
    }

    @Test
    void promptListIncludesDescription() {
        var server = serverWithPrompts();
        var resp = server.handleRequest(makeRequest("prompts/list", 1));
        var prompts = resp.getAsJsonObject("result").getAsJsonArray("prompts");
        var first = prompts.get(0).getAsJsonObject();
        assertEquals("Summarize a topic", first.get("description").getAsString());
    }

    @Test
    void promptListEmptyServerReturnsEmptyArray() {
        var server = new ZeroMcp(testConfig());
        var resp = server.handleRequest(makeRequest("prompts/list", 1));
        var prompts = resp.getAsJsonObject("result").getAsJsonArray("prompts");
        assertEquals(0, prompts.size());
    }

    // ===================================================================
    // 4. Template URI matching (resources/templates/list)
    // ===================================================================

    @Test
    void resourceTemplatesListReturnsEmptyArray() {
        var server = serverWithResources();
        var resp = server.handleRequest(makeRequest("resources/templates/list", 1));
        var templates = resp.getAsJsonObject("result").getAsJsonArray("resourceTemplates");
        assertEquals(0, templates.size());
    }

    @Test
    void resourceTemplatesListWithPaginationReturnsEmptyArray() {
        var server = serverWithResources();
        server.pageSize(5);
        var resp = server.handleRequest(makeRequest("resources/templates/list", 1));
        var templates = resp.getAsJsonObject("result").getAsJsonArray("resourceTemplates");
        assertEquals(0, templates.size());
        assertFalse(resp.getAsJsonObject("result").has("nextCursor"));
    }

    // ===================================================================
    // 5. Server dispatch
    // ===================================================================

    // --- resources/read ---

    @Test
    void resourceReadReturnsContent() {
        var server = serverWithResources();
        var params = new JsonObject();
        params.addProperty("uri", "config://app/settings");
        var resp = server.handleRequest(makeRequest("resources/read", 1, params));
        var result = resp.getAsJsonObject("result");
        var contents = result.getAsJsonArray("contents");
        assertEquals(1, contents.size());
        var item = contents.get(0).getAsJsonObject();
        assertEquals("config://app/settings", item.get("uri").getAsString());
        assertEquals("application/json", item.get("mimeType").getAsString());
        assertEquals("{\"theme\":\"dark\"}", item.get("text").getAsString());
    }

    @Test
    void resourceReadSecondResource() {
        var server = serverWithResources();
        var params = new JsonObject();
        params.addProperty("uri", "file://readme.txt");
        var resp = server.handleRequest(makeRequest("resources/read", 1, params));
        var text = resp.getAsJsonObject("result")
            .getAsJsonArray("contents").get(0).getAsJsonObject()
            .get("text").getAsString();
        assertEquals("Hello World", text);
    }

    @Test
    void resourceReadNotFoundReturnsError() {
        var server = serverWithResources();
        var params = new JsonObject();
        params.addProperty("uri", "config://nonexistent");
        var resp = server.handleRequest(makeRequest("resources/read", 1, params));
        assertTrue(resp.has("error"));
        assertEquals(-32002, resp.getAsJsonObject("error").get("code").getAsInt());
        assertTrue(resp.getAsJsonObject("error").get("message").getAsString().contains("Resource not found"));
    }

    @Test
    void resourceReadExceptionReturnsError() {
        var server = new ZeroMcp(testConfig());
        server.resource("broken", ResourceDef.builder()
            .uri("config://broken")
            .description("Broken resource")
            .read(() -> { throw new RuntimeException("read failed"); })
            .build());
        var params = new JsonObject();
        params.addProperty("uri", "config://broken");
        var resp = server.handleRequest(makeRequest("resources/read", 1, params));
        assertTrue(resp.has("error"));
        assertEquals(-32603, resp.getAsJsonObject("error").get("code").getAsInt());
        assertTrue(resp.getAsJsonObject("error").get("message").getAsString().contains("read failed"));
    }

    // --- prompts/get ---

    @Test
    void promptGetRendersMessages() {
        var server = serverWithPrompts();
        var params = new JsonObject();
        params.addProperty("name", "summarize");
        var argsObj = new JsonObject();
        argsObj.addProperty("topic", "quantum computing");
        params.add("arguments", argsObj);

        var resp = server.handleRequest(makeRequest("prompts/get", 1, params));
        var result = resp.getAsJsonObject("result");
        var messages = result.getAsJsonArray("messages");
        assertEquals(1, messages.size());

        var msg = messages.get(0).getAsJsonObject();
        assertEquals("user", msg.get("role").getAsString());
        var content = msg.getAsJsonObject("content");
        assertEquals("text", content.get("type").getAsString());
        assertEquals("Summarize: quantum computing", content.get("text").getAsString());
    }

    @Test
    void promptGetWithMultipleMessages() {
        var server = serverWithPrompts();
        var params = new JsonObject();
        params.addProperty("name", "translate");
        var argsObj = new JsonObject();
        argsObj.addProperty("text", "Hello");
        argsObj.addProperty("lang", "Spanish");
        params.add("arguments", argsObj);

        var resp = server.handleRequest(makeRequest("prompts/get", 1, params));
        var messages = resp.getAsJsonObject("result").getAsJsonArray("messages");
        assertEquals(2, messages.size());
        assertEquals("user", messages.get(0).getAsJsonObject().get("role").getAsString());
        assertEquals("assistant", messages.get(1).getAsJsonObject().get("role").getAsString());

        var userText = messages.get(0).getAsJsonObject()
            .getAsJsonObject("content").get("text").getAsString();
        assertEquals("Translate to Spanish: Hello", userText);
    }

    @Test
    void promptGetWithOptionalArgOmitted() {
        var server = serverWithPrompts();
        var params = new JsonObject();
        params.addProperty("name", "translate");
        var argsObj = new JsonObject();
        argsObj.addProperty("text", "Hello");
        // lang omitted -- should default to "French"
        params.add("arguments", argsObj);

        var resp = server.handleRequest(makeRequest("prompts/get", 1, params));
        var userText = resp.getAsJsonObject("result").getAsJsonArray("messages")
            .get(0).getAsJsonObject().getAsJsonObject("content").get("text").getAsString();
        assertEquals("Translate to French: Hello", userText);
    }

    @Test
    void promptGetNotFoundReturnsError() {
        var server = serverWithPrompts();
        var params = new JsonObject();
        params.addProperty("name", "nonexistent");
        var resp = server.handleRequest(makeRequest("prompts/get", 1, params));
        assertTrue(resp.has("error"));
        assertEquals(-32002, resp.getAsJsonObject("error").get("code").getAsInt());
    }

    @Test
    void promptGetRenderExceptionReturnsError() {
        var server = new ZeroMcp(testConfig());
        server.prompt("bad", PromptDef.builder()
            .description("Broken prompt")
            .render(args -> { throw new RuntimeException("render boom"); })
            .build());
        var params = new JsonObject();
        params.addProperty("name", "bad");
        var resp = server.handleRequest(makeRequest("prompts/get", 1, params));
        assertTrue(resp.has("error"));
        assertEquals(-32603, resp.getAsJsonObject("error").get("code").getAsInt());
        assertTrue(resp.getAsJsonObject("error").get("message").getAsString().contains("render boom"));
    }

    // --- logging/setLevel ---

    @Test
    void loggingSetLevelReturnsEmptyResult() {
        var server = new ZeroMcp(testConfig());
        var params = new JsonObject();
        params.addProperty("level", "debug");
        var resp = server.handleRequest(makeRequest("logging/setLevel", 1, params));
        assertNotNull(resp.getAsJsonObject("result"));
        assertEquals("2.0", resp.get("jsonrpc").getAsString());
    }

    @Test
    void loggingSetLevelWithoutParamsStillSucceeds() {
        var server = new ZeroMcp(testConfig());
        var resp = server.handleRequest(makeRequest("logging/setLevel", 1));
        assertNotNull(resp.getAsJsonObject("result"));
    }

    // --- initialize capabilities ---

    @Test
    void initializeReturnsProtocolVersionAndServerInfo() {
        var server = new ZeroMcp(testConfig());
        var resp = server.handleRequest(makeRequest("initialize", 1));
        var result = resp.getAsJsonObject("result");
        assertEquals("2024-11-05", result.get("protocolVersion").getAsString());

        var serverInfo = result.getAsJsonObject("serverInfo");
        assertEquals("zeromcp", serverInfo.get("name").getAsString());
        assertEquals("0.1.0", serverInfo.get("version").getAsString());
    }

    @Test
    void initializeIncludesToolsCapability() {
        var server = serverWithTools();
        var resp = server.handleRequest(makeRequest("initialize", 1));
        var capabilities = resp.getAsJsonObject("result").getAsJsonObject("capabilities");
        assertTrue(capabilities.has("tools"));
        assertTrue(capabilities.getAsJsonObject("tools").get("listChanged").getAsBoolean());
    }

    @Test
    void initializeIncludesResourcesCapabilityWhenResourcesRegistered() {
        var server = serverWithResources();
        var resp = server.handleRequest(makeRequest("initialize", 1));
        var capabilities = resp.getAsJsonObject("result").getAsJsonObject("capabilities");
        assertTrue(capabilities.has("resources"));
        assertTrue(capabilities.getAsJsonObject("resources").get("subscribe").getAsBoolean());
        assertTrue(capabilities.getAsJsonObject("resources").get("listChanged").getAsBoolean());
    }

    @Test
    void initializeExcludesResourcesCapabilityWhenNoResources() {
        var server = serverWithTools();
        var resp = server.handleRequest(makeRequest("initialize", 1));
        var capabilities = resp.getAsJsonObject("result").getAsJsonObject("capabilities");
        assertFalse(capabilities.has("resources"));
    }

    @Test
    void initializeIncludesPromptsCapabilityWhenPromptsRegistered() {
        var server = serverWithPrompts();
        var resp = server.handleRequest(makeRequest("initialize", 1));
        var capabilities = resp.getAsJsonObject("result").getAsJsonObject("capabilities");
        assertTrue(capabilities.has("prompts"));
        assertTrue(capabilities.getAsJsonObject("prompts").get("listChanged").getAsBoolean());
    }

    @Test
    void initializeExcludesPromptsCapabilityWhenNoPrompts() {
        var server = serverWithTools();
        var resp = server.handleRequest(makeRequest("initialize", 1));
        var capabilities = resp.getAsJsonObject("result").getAsJsonObject("capabilities");
        assertFalse(capabilities.has("prompts"));
    }

    @Test
    void initializeAlwaysIncludesLoggingCapability() {
        var server = new ZeroMcp(testConfig());
        var resp = server.handleRequest(makeRequest("initialize", 1));
        var capabilities = resp.getAsJsonObject("result").getAsJsonObject("capabilities");
        assertTrue(capabilities.has("logging"));
    }

    @Test
    void initializeWithClientCapabilities() {
        var server = serverWithTools();
        var params = new JsonObject();
        var clientCaps = new JsonObject();
        clientCaps.add("roots", new JsonObject());
        params.add("capabilities", clientCaps);
        // Should not throw
        var resp = server.handleRequest(makeRequest("initialize", 1, params));
        assertNotNull(resp.getAsJsonObject("result"));
    }

    // --- ping ---

    @Test
    void pingReturnsEmptyResult() {
        var server = new ZeroMcp(testConfig());
        var resp = server.handleRequest(makeRequest("ping", 1));
        assertNotNull(resp.getAsJsonObject("result"));
    }

    // --- method not found ---

    @Test
    void unknownMethodReturnsError() {
        var server = new ZeroMcp(testConfig());
        var resp = server.handleRequest(makeRequest("unknown/method", 1));
        assertTrue(resp.has("error"));
        assertEquals(-32601, resp.getAsJsonObject("error").get("code").getAsInt());
    }

    // --- notifications (no id) ---

    @Test
    void notificationReturnsNull() {
        var server = new ZeroMcp(testConfig());
        var req = new JsonObject();
        req.addProperty("jsonrpc", "2.0");
        req.addProperty("method", "notifications/initialized");
        // No id field
        var resp = server.handleRequest(req);
        assertNull(resp);
    }

    // --- tools/call ---

    @Test
    void toolCallReturnsResult() {
        var server = serverWithTools();
        var params = new JsonObject();
        params.addProperty("name", "echo");
        var argsObj = new JsonObject();
        argsObj.addProperty("msg", "hello");
        params.add("arguments", argsObj);

        var resp = server.handleRequest(makeRequest("tools/call", 1, params));
        var result = resp.getAsJsonObject("result");
        var text = result.getAsJsonArray("content").get(0).getAsJsonObject().get("text").getAsString();
        assertEquals("hello", text);
        assertFalse(result.has("isError"));
    }

    @Test
    void toolCallUnknownToolReturnsError() {
        var server = serverWithTools();
        var params = new JsonObject();
        params.addProperty("name", "nonexistent");
        var resp = server.handleRequest(makeRequest("tools/call", 1, params));
        var result = resp.getAsJsonObject("result");
        assertTrue(result.get("isError").getAsBoolean());
        assertTrue(result.getAsJsonArray("content").get(0).getAsJsonObject()
            .get("text").getAsString().contains("Unknown tool"));
    }

    @Test
    void toolCallValidationErrorReturnsIsError() {
        var server = serverWithTools();
        var params = new JsonObject();
        params.addProperty("name", "echo");
        // Missing required "msg" argument
        params.add("arguments", new JsonObject());
        var resp = server.handleRequest(makeRequest("tools/call", 1, params));
        var result = resp.getAsJsonObject("result");
        assertTrue(result.get("isError").getAsBoolean());
        assertTrue(result.getAsJsonArray("content").get(0).getAsJsonObject()
            .get("text").getAsString().contains("Validation errors"));
    }

    @Test
    void toolCallWithNoParamsReturnsError() {
        var server = serverWithTools();
        var resp = server.handleRequest(makeRequest("tools/call", 1));
        var result = resp.getAsJsonObject("result");
        assertTrue(result.get("isError").getAsBoolean());
    }

    // --- resources/subscribe ---

    @Test
    void resourceSubscribeReturnsEmptyResult() {
        var server = serverWithResources();
        var params = new JsonObject();
        params.addProperty("uri", "config://app/settings");
        var resp = server.handleRequest(makeRequest("resources/subscribe", 1, params));
        assertNotNull(resp.getAsJsonObject("result"));
    }

    // --- completion/complete ---

    @Test
    void completionCompleteReturnsEmptyValues() {
        var server = new ZeroMcp(testConfig());
        var resp = server.handleRequest(makeRequest("completion/complete", 1));
        var completion = resp.getAsJsonObject("result").getAsJsonObject("completion");
        assertEquals(0, completion.getAsJsonArray("values").size());
    }

    // ===================================================================
    // 6. Icon support
    // ===================================================================

    @Test
    void iconAppearsInToolList() {
        var server = serverWithTools();
        server.icon("https://example.com/icon.png");
        var resp = server.handleRequest(makeRequest("tools/list", 1));
        var tools = resp.getAsJsonObject("result").getAsJsonArray("tools");
        for (var t : tools) {
            var icons = t.getAsJsonObject().getAsJsonArray("icons");
            assertNotNull(icons);
            assertEquals(1, icons.size());
            assertEquals("https://example.com/icon.png",
                icons.get(0).getAsJsonObject().get("uri").getAsString());
        }
    }

    @Test
    void iconAppearsInResourceList() {
        var server = serverWithResources();
        server.icon("https://example.com/icon.png");
        var resp = server.handleRequest(makeRequest("resources/list", 1));
        var resources = resp.getAsJsonObject("result").getAsJsonArray("resources");
        for (var r : resources) {
            var icons = r.getAsJsonObject().getAsJsonArray("icons");
            assertNotNull(icons);
            assertEquals("https://example.com/icon.png",
                icons.get(0).getAsJsonObject().get("uri").getAsString());
        }
    }

    @Test
    void iconAppearsInPromptList() {
        var server = serverWithPrompts();
        server.icon("https://example.com/icon.png");
        var resp = server.handleRequest(makeRequest("prompts/list", 1));
        var prompts = resp.getAsJsonObject("result").getAsJsonArray("prompts");
        for (var p : prompts) {
            var icons = p.getAsJsonObject().getAsJsonArray("icons");
            assertNotNull(icons);
            assertEquals("https://example.com/icon.png",
                icons.get(0).getAsJsonObject().get("uri").getAsString());
        }
    }

    @Test
    void noIconMeansNoIconsField() {
        var server = serverWithTools();
        // no icon set
        var resp = server.handleRequest(makeRequest("tools/list", 1));
        var tools = resp.getAsJsonObject("result").getAsJsonArray("tools");
        for (var t : tools) {
            assertFalse(t.getAsJsonObject().has("icons"));
        }
    }

    // ===================================================================
    // Response structure
    // ===================================================================

    @Test
    void responseIncludesJsonRpcAndId() {
        var server = new ZeroMcp(testConfig());
        var resp = server.handleRequest(makeRequest("ping", 42));
        assertEquals("2.0", resp.get("jsonrpc").getAsString());
        assertEquals(42, resp.get("id").getAsInt());
    }

    @Test
    void errorResponseIncludesJsonRpcAndId() {
        var server = new ZeroMcp(testConfig());
        var resp = server.handleRequest(makeRequest("unknown/method", 99));
        assertEquals("2.0", resp.get("jsonrpc").getAsString());
        assertEquals(99, resp.get("id").getAsInt());
        assertTrue(resp.has("error"));
    }
}
