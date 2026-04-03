import ZeroMcp
import Foundation

let server = ZeroMcp()

server.tool(
    "hello",
    description: "Say hello to someone",
    input: ["name": .simple(.string)]
) { args, ctx in
    "Hello, \(args["name"] as? String ?? "world")!"
}

server.tool(
    "add",
    description: "Add two numbers together",
    input: [
        "a": .simple(.number),
        "b": .simple(.number)
    ]
) { args, ctx in
    let a = args["a"] as? Double ?? 0
    let b = args["b"] as? Double ?? 0
    return ["sum": a + b] as [String: Any]
}

await server.serve()
