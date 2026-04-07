import io.antidrift.zeromcp.*

/**
 * v0.2.0 conformance test — tools, resources, and prompts on stdio.
 *
 * Exercises every primitive the MCP spec requires:
 *   - tools/list, tools/call
 *   - resources/list, resources/read
 *   - prompts/list, prompts/get
 */
fun resourceTestMain() {
    val server = ZeroMcp()

    // --- Tool: hello ---
    server.tool("hello") {
        description = "Say hello to someone"
        input {
            required("name", "string", "Name to greet")
        }
        execute { args, _ ->
            val name = args.getString("name") ?: "world"
            "Hello, $name!"
        }
    }

    // --- Resource: static JSON data ---
    server.resource("data.json") {
        uri = "resource:///data.json"
        description = "Static JSON data"
        mimeType = "application/json"
        read {
            """{"key":"value","items":[1,2,3]}"""
        }
    }

    // --- Resource: dynamic content ---
    server.resource("dynamic") {
        uri = "resource:///dynamic"
        description = "Dynamic content"
        read {
            "This is dynamic content generated at runtime"
        }
    }

    // --- Prompt: greet ---
    server.prompt("greet") {
        description = "Generate a greeting message"
        arguments {
            required("name", "Name of the person to greet")
            optional("tone", "formal or casual")
        }
        render { args ->
            val name = args.getString("name") ?: "friend"
            val tone = args.getString("tone") ?: "casual"
            val greeting = if (tone == "formal") {
                "Dear $name, I hope this message finds you well."
            } else {
                "Hey $name! How's it going?"
            }
            listOf(
                PromptMessage(
                    role = "user",
                    content = PromptContent(text = greeting)
                )
            )
        }
    }

    server.serve()
}
