import io.antidrift.zeromcp.*

fun main() {
    val server = ZeroMcp()

    server.tool("greet") {
        description = "Greet a person by name"
        input {
            "name" to "string"
        }
        route("GET", "/greet/:name")
        execute { args, _ ->
            "Hello, ${args.getString("name")}!"
        }
    }

    server.tool("echo") {
        description = "Echo a message back"
        input {
            "message" to "string"
        }
        route("POST", "/echo")
        execute { args, _ ->
            mapOf(
                "message" to args.getString("message"),
                "echoed" to true
            )
        }
    }

    server.serveHttp(14257)
}
