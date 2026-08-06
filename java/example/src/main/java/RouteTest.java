import io.antidrift.zeromcp.*;

public class RouteTest {
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

        server.serveHttp(14256);
    }
}
