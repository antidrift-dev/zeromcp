package io.zeromcp;

import org.junit.jupiter.api.Test;

import java.util.Map;

import static org.junit.jupiter.api.Assertions.*;

class ServerTest {

    @Test
    void toolRegistrationWorks() {
        var server = new ZeroMcp();
        server.tool("greet", Tool.builder()
            .description("Greet someone")
            .input(Input.required("name", "string"))
            .execute((args, ctx) -> "Hi, " + args.get("name") + "!")
            .build());
        // If we get here without exception, registration succeeded
        assertTrue(true);
    }

    @Test
    void toolBuilderCreatesCorrectDefinition() {
        var tool = Tool.builder()
            .description("A test tool")
            .input(
                Input.required("x", "number"),
                Input.optional("y", "number", "Optional Y value")
            )
            .execute((args, ctx) -> args.get("x"))
            .build();

        assertEquals("A test tool", tool.description());
        assertEquals(2, tool.inputs().size());
        assertFalse(tool.inputs().get(0).optional());
        assertTrue(tool.inputs().get(1).optional());
    }

    @Test
    void toolExecutionReturnsCorrectResult() throws Exception {
        var tool = Tool.builder()
            .description("Add numbers")
            .input(
                Input.required("a", "number"),
                Input.required("b", "number")
            )
            .execute((args, ctx) -> {
                var a = ((Number) args.get("a")).doubleValue();
                var b = ((Number) args.get("b")).doubleValue();
                return a + b;
            })
            .build();

        var result = tool.executor().execute(Map.of("a", 3.0, "b", 4.0), new Ctx("adder"));
        assertEquals(7.0, result);
    }

    @Test
    void permissionsArePreserved() {
        var perms = new Permissions(
            Permissions.NetworkPermission.allowList("api.example.com"),
            Permissions.FsPermission.READ,
            false
        );
        var tool = Tool.builder()
            .description("Net tool")
            .permissions(perms)
            .execute((args, ctx) -> "ok")
            .build();

        assertEquals(perms, tool.permissions());
        assertInstanceOf(Permissions.NetworkPermission.AllowList.class, tool.permissions().network());
    }
}
