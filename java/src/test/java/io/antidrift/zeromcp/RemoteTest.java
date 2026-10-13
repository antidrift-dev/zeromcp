package io.antidrift.zeromcp;

import com.google.gson.JsonObject;
import org.junit.jupiter.api.Test;

import java.util.List;

import static io.antidrift.zeromcp.FakeUpstream.*;
import static org.junit.jupiter.api.Assertions.*;

class RemoteTest {

    private static Config testConfig() {
        return Config.load("/nonexistent");
    }

    @Test
    void toolsListIncludesNamespacedRemoteTools() throws Exception {
        try (var up = new FakeUpstream()) {
            var server = new ZeroMcp(testConfig()).remote(new RemoteServer("probeo", up.url()));
            var names = toolNames(server.handleRequest(request("tools/list", null)));
            assertEquals(List.of("probeo.list_pages", "probeo.get_page"), names);
            assertEquals(List.of("initialize", "tools/list"), up.methods);
        }
    }

    @Test
    void toolsAllowlistFiltersRemoteTools() throws Exception {
        try (var up = new FakeUpstream()) {
            var server = new ZeroMcp(testConfig())
                .remote(new RemoteServer("probeo", up.url(), null, List.of("list_pages")));
            var names = toolNames(server.handleRequest(request("tools/list", null)));
            assertEquals(List.of("probeo.list_pages"), names);
        }
    }

    @Test
    void remoteSchemaRequiredFieldsAreValidated() throws Exception {
        try (var up = new FakeUpstream()) {
            var server = new ZeroMcp(testConfig()).remote(new RemoteServer("probeo", up.url()));
            var list = server.handleRequest(request("tools/list", null));
            var getPage = list.getAsJsonObject("result").getAsJsonArray("tools").get(1).getAsJsonObject();
            assertEquals("id", getPage.getAsJsonObject("inputSchema").getAsJsonArray("required").get(0).getAsString());

            var res = server.handleRequest(request("tools/call", callParams("probeo.get_page", null)));
            assertTrue(res.getAsJsonObject("result").get("isError").getAsBoolean());
            assertTrue(text(res).contains("Missing required field: id"));
        }
    }

    @Test
    void toolsCallForwardsBareNameAndReturnsUpstreamText() throws Exception {
        try (var up = new FakeUpstream()) {
            var server = new ZeroMcp(testConfig()).remote(new RemoteServer("probeo", up.url()));
            var args = new JsonObject();
            args.addProperty("q", "x");
            var res = server.handleRequest(request("tools/call", callParams("probeo.list_pages", args)));
            assertEquals("upstream:list_pages:{\"q\":\"x\"}", text(res));
            assertEquals(List.of("list_pages"), up.calledNames);
            assertTrue(up.authHeaders.stream().allMatch(String::isEmpty), "no auth header without auth");
        }
    }

    @Test
    void bearerAuthIsSentLiteral() throws Exception {
        try (var up = new FakeUpstream()) {
            var server = new ZeroMcp(testConfig())
                .remote(new RemoteServer("probeo", up.url(), "secret-token", null));
            server.handleRequest(request("tools/call", callParams("probeo.list_pages", null)));
            assertEquals(3, up.authHeaders.size());
            assertTrue(up.authHeaders.stream().allMatch("Bearer secret-token"::equals));
        }
    }

    @Test
    void bearerAuthResolvesEnvForm() throws Exception {
        var home = System.getenv("HOME");
        assertNotNull(home);
        try (var up = new FakeUpstream()) {
            var server = new ZeroMcp(testConfig())
                .remote(new RemoteServer("probeo", up.url(), "env:HOME", null));
            server.handleRequest(request("tools/list", null));
            assertTrue(up.authHeaders.stream().allMatch(("Bearer " + home)::equals));
        }
    }

    @Test
    void localToolOverridesRemote() throws Exception {
        try (var up = new FakeUpstream()) {
            var server = new ZeroMcp(testConfig()).remote(new RemoteServer("probeo", up.url()));
            server.tool("probeo.list_pages", Tool.builder()
                .description("local")
                .execute((a, ctx) -> "local wins")
                .build());
            var names = toolNames(server.handleRequest(request("tools/list", null)));
            assertEquals(List.of("probeo.list_pages", "probeo.get_page"), names, "local keeps remote position");
            var res = server.handleRequest(request("tools/call", callParams("probeo.list_pages", null)));
            assertEquals("local wins", text(res));
            assertTrue(up.calledNames.isEmpty());
        }
    }

    @Test
    void badServersAreSkippedAndGoodOnesLoad() throws Exception {
        try (var bad = new FakeUpstream(500); var good = new FakeUpstream()) {
            var server = new ZeroMcp(testConfig()).remote(
                new RemoteServer("ftp", "ftp://example.com/mcp"),
                new RemoteServer("broken", bad.url()),
                new RemoteServer("probeo", good.url(), null, List.of("get_page")));
            var names = toolNames(server.handleRequest(request("tools/list", null)));
            assertEquals(List.of("probeo.get_page"), names);
        }
    }

    @Test
    void remotesConnectOnlyOnce() throws Exception {
        try (var up = new FakeUpstream()) {
            var server = new ZeroMcp(testConfig()).remote(new RemoteServer("probeo", up.url()));
            server.handleRequest(request("tools/list", null));
            server.handleRequest(request("tools/list", null));
            server.registry();
            assertEquals(List.of("initialize", "tools/list"), up.methods);
        }
    }

    @Test
    void remotesFromConfigFile() throws Exception {
        try (var up = new FakeUpstream()) {
            var dir = java.nio.file.Files.createTempDirectory("zeromcp-remote");
            java.nio.file.Files.writeString(dir.resolve("zeromcp.config.json"),
                "{\"remote\":[{\"name\":\"probeo\",\"url\":\"" + up.url() + "\",\"tools\":[\"list_pages\"]}]}");
            var server = new ZeroMcp(Config.load(dir.toString()));
            var names = toolNames(server.handleRequest(request("tools/list", null)));
            assertEquals(List.of("probeo.list_pages"), names);
        }
    }
}
