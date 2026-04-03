package io.zeromcp;

import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class ConfigTest {

    @Test
    void defaultConfigHasSensibleValues() {
        var config = Config.load("/nonexistent/path");
        assertEquals("stdio", config.transport());
        assertEquals(4242, config.port());
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
}
