import ZeroMcp
import Foundation

let server = ZeroMcp()

// 1. Register "hello" tool
server.tool(
    "hello",
    description: "Say hello to someone",
    input: ["name": .simple(.string)]
) { args, ctx in
    let name = args["name"] as? String ?? "world"
    return "Hello, \(name)!"
}

// 2. Register a static resource
server.resource("greeting", ResourceDefinition(
    uri: "zeromcp://greeting",
    name: "greeting",
    description: "A friendly greeting message",
    mimeType: "text/plain",
    read: { "Hello from ZeroMcp resources!" }
))

// 3. Register a resource template
server.resourceTemplate("user-profile", ResourceTemplateDefinition(
    uriTemplate: "zeromcp://users/{userId}/profile",
    name: "user-profile",
    description: "User profile by ID",
    mimeType: "application/json",
    read: { params in
        let userId = params["userId"] ?? "unknown"
        return "{\"userId\":\"\(userId)\",\"name\":\"User \(userId)\"}"
    }
))

// 4. Register a prompt
server.prompt("greet", PromptDefinition(
    name: "greet",
    description: "Generate a greeting for a given name",
    arguments: [
        PromptArgument(name: "name", description: "Name to greet", required: true)
    ],
    render: { args in
        let name = args["name"] as? String ?? "friend"
        return [
            [
                "role": "user",
                "content": [
                    "type": "text",
                    "text": "Please greet \(name) warmly."
                ]
            ]
        ]
    }
))

// 5. Serve on stdio
await server.serve()
