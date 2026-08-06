import ZeroMcp
import Foundation

let server = ZeroMcp()

server.tool(
    "greet",
    description: "Greet a person by name",
    input: ["name": .simple(.string)],
    route: RouteDefinition(method: "GET", path: "/greet/:name")
) { args, ctx in
    let name = args["name"] as? String ?? "world"
    return "Hello, \(name)!"
}

server.tool(
    "echo",
    description: "Echo a message back",
    input: ["message": .simple(.string)],
    route: RouteDefinition(method: "POST", path: "/echo")
) { args, ctx in
    return ["message": args["message"] as Any, "echoed": true] as [String: Any]
}

await server.serveHttp(port: 14258)
