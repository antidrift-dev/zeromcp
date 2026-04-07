import io.antidrift.zeromcp.*

/**
 * v0.2.0 conformance test — tools, resources, and prompts on stdio.
 *
 * Exercises every primitive the MCP spec requires:
 *   - tools/list, tools/call
 *   - resources/list, resources/read
 *   - prompts/list, prompts/get
 */
fun main() {
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

    // --- Resource: static status page ---
    server.resource("status") {
        uri = "zeromcp://status"
        description = "Server status"
        mimeType = "application/json"
        read {
            """{"status":"ok","version":"0.2.0"}"""
        }
    }

    // --- Resource: readme (plain text) ---
    server.resource("readme") {
        uri = "zeromcp://readme"
        description = "Project readme"
        read {
            "ZeroMcp — zero-config MCP servers in every language."
        }
    }

    // --- Resource template: user profile by id ---
    server.resourceTemplate("user-profile") {
        uriTemplate = "zeromcp://users/{userId}/profile"
        description = "User profile by ID"
        mimeType = "application/json"
        read { params ->
            val userId = params["userId"] ?: "unknown"
            """{"userId":"$userId","name":"User $userId","active":true}"""
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
