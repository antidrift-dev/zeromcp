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

// 2. Register a static JSON resource
server.resource("data.json", ResourceDefinition(
    uri: "resource:///data.json",
    name: "data.json",
    description: "A static JSON data file",
    mimeType: "application/json",
    read: { "{\"key\": \"value\"}" }
))

// 3. Register a dynamic resource
server.resource("dynamic", ResourceDefinition(
    uri: "resource:///dynamic",
    name: "dynamic",
    description: "A dynamic resource",
    mimeType: "text/plain",
    read: { "This is dynamic content generated at runtime." }
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
