package io.antidrift.zeromcp;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Base64;
import java.util.List;

import static org.junit.jupiter.api.Assertions.*;

class ConfigTest {

    @Test
    void defaultConfigHasSensibleValues() {
        var config = Config.load("/nonexistent/path");
        assertEquals("stdio", config.transport());
        assertFalse(config.logging());
        assertEquals("_", config.separator());
        assertEquals("zeromcp", config.name());
    }

    @Test
    void resolveAuthReturnsRawStringForNonEnv() {
        assertEquals("my-token", Config.resolveAuth("my-token"));
    }

    @Test
    void resolveAuthReadsFromEnvironment() {
        assertNull(Config.resolveAuth("env:ZEROMCP_TEST_NONEXISTENT_VAR"));
    }

    @Test
    void resolveAuthReturnsNullForNullInput() {
        assertNull(Config.resolveAuth(null));
    }

    @Test
    void remotePageSizeAndIconParse(@TempDir Path dir) throws Exception {
        Files.writeString(dir.resolve("zeromcp.config.json"), """
            {
              "page_size": 3,
              "icon": "data:image/png;base64,AAAA",
              "remote": [
                {"name": "probeo", "url": "https://example.com/mcp", "auth": "env:TOKEN", "tools": ["list_pages"]},
                {"name": "other", "url": "http://localhost:9000/mcp"}
              ]
            }
            """);
        var config = Config.load(dir.toString());
        assertEquals(3, config.pageSize());
        assertEquals("data:image/png;base64,AAAA", config.icon());
        assertEquals(2, config.remote().size());
        assertEquals(new RemoteServer("probeo", "https://example.com/mcp", "env:TOKEN", List.of("list_pages")),
            config.remote().get(0));
        assertEquals(new RemoteServer("other", "http://localhost:9000/mcp"), config.remote().get(1));
    }

    @Test
    void defaultsForNewKeys() {
        var config = Config.load("/nonexistent/path");
        assertEquals(0, config.pageSize());
        assertNull(config.icon());
        assertEquals(List.of(), config.remote());
    }

    @Test
    void resolveIconPassesDataUriThrough() {
        assertEquals("data:image/png;base64,AAAA", Config.resolveIcon("data:image/png;base64,AAAA"));
        assertNull(Config.resolveIcon(null));
    }

    @Test
    void resolveIconReadsSvgFile(@TempDir Path dir) throws Exception {
        var file = dir.resolve("logo.svg");
        Files.writeString(file, "<svg/>");
        var expected = "data:image/svg+xml;base64," + Base64.getEncoder().encodeToString("<svg/>".getBytes());
        assertEquals(expected, Config.resolveIcon(file.toString()));
    }

    @Test
    void resolveIconUnknownExtensionDefaultsToPng(@TempDir Path dir) throws Exception {
        var file = dir.resolve("logo.bin");
        Files.write(file, new byte[] {1, 2, 3});
        assertEquals("data:image/png;base64,AQID", Config.resolveIcon(file.toString()));
    }

    @Test
    void resolveIconMissingFileReturnsNull() {
        assertNull(Config.resolveIcon("/nonexistent/icon.png"));
    }

    @Test
    void httpTransportFailsAtStartupNamingRegistry(@TempDir Path dir) throws Exception {
        Files.writeString(dir.resolve("zeromcp.config.json"), "{\"transport\":\"http\"}");
        var server = new ZeroMcp(Config.load(dir.toString()));
        var ex = assertThrows(IllegalStateException.class, server::serve);
        assertTrue(ex.getMessage().contains("registry()"), ex.getMessage());
    }
}
