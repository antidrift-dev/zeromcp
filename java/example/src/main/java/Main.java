import io.zeromcp.*;

public class Main {
    public static void main(String[] args) {
        var server = new ZeroMcp();

        server.tool("hello", Tool.builder()
            .description("Say hello to someone")
            .input(Input.required("name", "string", "The person's name"))
            .execute((a, ctx) -> "Hello, " + a.get("name") + "!")
            .build());

        server.tool("add", Tool.builder()
            .description("Add two numbers together")
            .input(
                Input.required("a", "number"),
                Input.required("b", "number")
            )
            .execute((a, ctx) -> {
                var x = ((Number) a.get("a")).doubleValue();
                var y = ((Number) a.get("b")).doubleValue();
                return java.util.Map.of("sum", x + y);
            })
            .build());

        server.tool("fetch_url", Tool.builder()
            .description("Fetch a URL (with permission)")
            .input(Input.required("url", "string", "The URL to fetch"))
            .permissions(new Permissions(
                Permissions.NetworkPermission.allowList("api.example.com", "*.github.com"),
                Permissions.FsPermission.NONE,
                false
            ))
            .execute((a, ctx) -> {
                var url = (String) a.get("url");
                var host = java.net.URI.create(url).getHost();
                if (!Sandbox.checkNetworkAccess(ctx.toolName(), host, ctx.permissions())) {
                    return "Network access denied for " + host;
                }
                return "Would fetch: " + url;
            })
            .build());

        server.serve();
    }
}
