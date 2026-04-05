import ZeroMcp
import Foundation

let server = ZeroMcp()

server.tool(
    "hello",
    description: "Fast tool",
    input: ["name": .simple(.string)]
) { args, ctx in
    let name = args["name"] as? String ?? "world"
    return "Hello, \(name)!"
}

server.tool(
    "slow",
    description: "Tool that takes 3 seconds",
    input: [:],
    permissions: Permissions(executeTimeout: 2.0)
) { args, ctx in
    Thread.sleep(forTimeInterval: 3.0)
    return ["status": "ok"] as [String: Any]
}

await server.serve()
