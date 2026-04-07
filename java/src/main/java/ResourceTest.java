import io.antidrift.zeromcp.*;

import java.time.Instant;
import java.util.List;

/**
 * v0.2.0 conformance test — tools, resources, and prompts on stdio.
 */
public class ResourceTest {

    public static void main(String[] args) {
        var server = new ZeroMcp();

        // 1. Tool: hello
        server.tool("hello", Tool.builder()
            .description("Say hello")
            .input(Input.required("name", "string", "Name to greet"))
            .execute((a, ctx) -> "Hello, " + a.get("name") + "!")
            .build());

        // 2a. Resource: data.json (static JSON blob)
        server.resource("data.json", ResourceDef.builder()
            .uri("file:///data.json")
            .description("Sample JSON data")
            .mimeType("application/json")
            .read(() -> "{\"id\":1,\"active\":true}")
            .build());

        // 2b. Resource: dynamic (returns current timestamp)
        server.resource("dynamic", ResourceDef.builder()
            .uri("custom://dynamic")
            .description("Dynamic resource that returns the current time")
            .mimeType("text/plain")
            .read(() -> "now=" + Instant.now())
            .build());

        // 2c. Resource: readme.md
        server.resource("readme.md", ResourceDef.builder()
            .uri("file:///readme.md")
            .description("Project readme")
            .mimeType("text/markdown")
            .read(() -> "# ZeroMcp\nZero-config MCP for Java.")
            .build());

        // 3. Prompt: greet
        server.prompt("greet", PromptDef.builder()
            .description("Generate a greeting")
            .argument(PromptArgument.required("name", "Name of the person to greet"))
            .render(a -> List.of(
                new PromptMessage("user", "Please greet " + a.get("name") + " warmly.")
            ))
            .build());

        // 4. Serve on stdio
        server.serve();
    }
}
