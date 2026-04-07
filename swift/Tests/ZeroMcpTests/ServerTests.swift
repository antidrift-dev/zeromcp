import XCTest
@testable import ZeroMcp

final class ServerTests: XCTestCase {
    // Helper to build a server with a simple tool
    private func makeServer() -> ZeroMcp {
        let server = ZeroMcp(config: ZeroMcpConfig())
        server.tool(
            "greet",
            description: "Greet a user",
            input: ["name": .simple(.string)]
        ) { args, _ in
            "Hello, \(args["name"] as! String)!"
        }
        return server
    }

    private func jsonrpc(_ method: String, id: Any? = 1, params: [String: Any] = [:]) -> [String: Any] {
        var req: [String: Any] = ["jsonrpc": "2.0", "method": method, "params": params]
        if let id = id { req["id"] = id }
        return req
    }

    // MARK: - Initialize

    func testInitializeReturnsCapabilities() async {
        let server = makeServer()
        let resp = await server.handleRequest(jsonrpc("initialize", params: [
            "protocolVersion": "2024-11-05",
            "capabilities": [:],
            "clientInfo": ["name": "test", "version": "1.0"]
        ]))
        let result = resp?["result"] as? [String: Any]
        XCTAssertNotNil(result)
        XCTAssertEqual(result?["protocolVersion"] as? String, "2024-11-05")

        let serverInfo = result?["serverInfo"] as? [String: Any]
        XCTAssertEqual(serverInfo?["name"] as? String, "zeromcp")

        let caps = result?["capabilities"] as? [String: Any]
        XCTAssertNotNil(caps?["tools"])
    }

    func testInitializeIncludesResourceCapWhenResourcesRegistered() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        server.resource("readme", ResourceDefinition(
            uri: "file:///readme.md", name: "README"
        ) { "content" })
        let resp = await server.handleRequest(jsonrpc("initialize"))
        let caps = (resp?["result"] as? [String: Any])?["capabilities"] as? [String: Any]
        XCTAssertNotNil(caps?["resources"])
    }

    func testInitializeIncludesPromptCapWhenPromptsRegistered() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        server.prompt("test", PromptDefinition(name: "test") { _ in
            [["role": "user", "content": ["type": "text", "text": "hi"]]]
        })
        let resp = await server.handleRequest(jsonrpc("initialize"))
        let caps = (resp?["result"] as? [String: Any])?["capabilities"] as? [String: Any]
        XCTAssertNotNil(caps?["prompts"])
    }

    func testInitializeIconInServerInfo() async {
        let server = makeServer()
        server.icon = "https://example.com/icon.png"
        let resp = await server.handleRequest(jsonrpc("initialize"))
        let serverInfo = (resp?["result"] as? [String: Any])?["serverInfo"] as? [String: Any]
        XCTAssertEqual(serverInfo?["icon"] as? String, "https://example.com/icon.png")
    }

    // MARK: - Ping

    func testPing() async {
        let server = makeServer()
        let resp = await server.handleRequest(jsonrpc("ping"))
        XCTAssertNotNil(resp?["result"])
        XCTAssertEqual(resp?["id"] as? Int, 1)
    }

    // MARK: - Tools list

    func testToolsList() async {
        let server = makeServer()
        let resp = await server.handleRequest(jsonrpc("tools/list"))
        let result = resp?["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 1)
        XCTAssertEqual(tools?[0]["name"] as? String, "greet")
        XCTAssertEqual(tools?[0]["description"] as? String, "Greet a user")

        let inputSchema = tools?[0]["inputSchema"] as? [String: Any]
        XCTAssertEqual(inputSchema?["type"] as? String, "object")
        let props = inputSchema?["properties"] as? [String: Any]
        XCTAssertNotNil(props?["name"])
    }

    func testToolsListMultipleToolsSorted() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        server.tool("zeta", description: "Z tool", input: [:]) { _, _ in "z" }
        server.tool("alpha", description: "A tool", input: [:]) { _, _ in "a" }
        server.tool("mid", description: "M tool", input: [:]) { _, _ in "m" }

        let resp = await server.handleRequest(jsonrpc("tools/list"))
        let tools = ((resp?["result"] as? [String: Any])?["tools"] as? [[String: Any]])!
        let names = tools.map { $0["name"] as! String }
        XCTAssertEqual(names, ["alpha", "mid", "zeta"])
    }

    // MARK: - Tools call

    func testToolsCallSuccess() async {
        let server = makeServer()
        let resp = await server.handleRequest(jsonrpc("tools/call", params: [
            "name": "greet",
            "arguments": ["name": "World"]
        ]))
        let result = resp?["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]]
        XCTAssertEqual(content?[0]["text"] as? String, "Hello, World!")
        XCTAssertNil(result?["isError"])
    }

    func testToolsCallUnknownTool() async {
        let server = makeServer()
        let resp = await server.handleRequest(jsonrpc("tools/call", params: [
            "name": "nonexistent",
            "arguments": [:]
        ]))
        let result = resp?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)
        let content = result?["content"] as? [[String: Any]]
        XCTAssertTrue((content?[0]["text"] as? String)?.contains("Unknown tool") ?? false)
    }

    func testToolsCallValidationError() async {
        let server = makeServer()
        // "name" is required but missing
        let resp = await server.handleRequest(jsonrpc("tools/call", params: [
            "name": "greet",
            "arguments": [:] as [String: Any]
        ]))
        let result = resp?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)
        let content = result?["content"] as? [[String: Any]]
        XCTAssertTrue((content?[0]["text"] as? String)?.contains("Validation errors") ?? false)
    }

    func testToolsCallReturnsDict() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        server.tool("data", description: "Return dict", input: [:]) { _, _ in
            ["key": "value"]
        }
        let resp = await server.handleRequest(jsonrpc("tools/call", params: [
            "name": "data", "arguments": [:]
        ]))
        let content = ((resp?["result"] as? [String: Any])?["content"] as? [[String: Any]])
        let text = content?[0]["text"] as? String ?? ""
        // The dict gets JSON-serialized
        XCTAssertTrue(text.contains("key"))
        XCTAssertTrue(text.contains("value"))
    }

    func testToolsCallHandlesError() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        server.tool("fail", description: "Always fails", input: [:]) { _, _ in
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "boom"])
        }
        let resp = await server.handleRequest(jsonrpc("tools/call", params: [
            "name": "fail", "arguments": [:]
        ]))
        let result = resp?["result"] as? [String: Any]
        XCTAssertEqual(result?["isError"] as? Bool, true)
        let content = result?["content"] as? [[String: Any]]
        XCTAssertTrue((content?[0]["text"] as? String)?.contains("boom") ?? false)
    }

    // MARK: - Method not found

    func testUnknownMethod() async {
        let server = makeServer()
        let resp = await server.handleRequest(jsonrpc("unknown/method"))
        let error = resp?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32601)
        XCTAssertTrue((error?["message"] as? String)?.contains("Method not found") ?? false)
    }

    // MARK: - Notifications (no id) return nil

    func testNotificationReturnsNil() async {
        let server = makeServer()
        let resp = await server.handleRequest([
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": [:] as [String: Any]
        ])
        XCTAssertNil(resp)
    }

    // MARK: - Resources

    func testResourceRegistrationAndList() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        server.resource("readme", ResourceDefinition(
            uri: "file:///readme.md",
            name: "README",
            description: "The readme",
            mimeType: "text/markdown"
        ) { "# Hello" })
        server.resource("config", ResourceDefinition(
            uri: "file:///config.json",
            name: "Config",
            mimeType: "application/json"
        ) { "{}" })

        let resp = await server.handleRequest(jsonrpc("resources/list"))
        let result = resp?["result"] as? [String: Any]
        let resources = result?["resources"] as? [[String: Any]]
        XCTAssertEqual(resources?.count, 2)

        // Sorted by key
        let names = resources?.map { $0["name"] as! String }
        XCTAssertEqual(names, ["Config", "README"])

        // Check fields
        let readme = resources?.first { ($0["name"] as? String) == "README" }
        XCTAssertEqual(readme?["uri"] as? String, "file:///readme.md")
        XCTAssertEqual(readme?["mimeType"] as? String, "text/markdown")
        XCTAssertEqual(readme?["description"] as? String, "The readme")
    }

    func testResourceRead() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        server.resource("readme", ResourceDefinition(
            uri: "file:///readme.md",
            name: "README"
        ) { "# Hello World" })

        let resp = await server.handleRequest(jsonrpc("resources/read", params: [
            "uri": "file:///readme.md"
        ]))
        let result = resp?["result"] as? [String: Any]
        let contents = result?["contents"] as? [[String: Any]]
        XCTAssertEqual(contents?.count, 1)
        XCTAssertEqual(contents?[0]["text"] as? String, "# Hello World")
        XCTAssertEqual(contents?[0]["uri"] as? String, "file:///readme.md")
    }

    func testResourceReadNotFound() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        let resp = await server.handleRequest(jsonrpc("resources/read", params: [
            "uri": "file:///nope"
        ]))
        let error = resp?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32002)
        XCTAssertTrue((error?["message"] as? String)?.contains("Resource not found") ?? false)
    }

    func testResourceReadError() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        server.resource("bad", ResourceDefinition(
            uri: "file:///bad",
            name: "Bad"
        ) {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "read failed"])
        })
        let resp = await server.handleRequest(jsonrpc("resources/read", params: [
            "uri": "file:///bad"
        ]))
        let error = resp?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32603)
    }

    func testResourceSubscribe() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        let resp = await server.handleRequest(jsonrpc("resources/subscribe", params: [
            "uri": "file:///readme.md"
        ]))
        XCTAssertNotNil(resp?["result"])
    }

    func testResourceIconIncludedWhenSet() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        server.icon = "https://example.com/icon.png"
        server.resource("readme", ResourceDefinition(
            uri: "file:///readme.md", name: "README"
        ) { "content" })

        let resp = await server.handleRequest(jsonrpc("resources/list"))
        let resources = ((resp?["result"] as? [String: Any])?["resources"] as? [[String: Any]])!
        XCTAssertNotNil(resources[0]["icons"])
    }

    // MARK: - Resource Templates

    func testResourceTemplatesList() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        server.resourceTemplate("user", ResourceTemplateDefinition(
            uriTemplate: "user://{id}/profile",
            name: "User Profile",
            description: "A user profile",
            mimeType: "application/json"
        ) { params in
            "{\"id\": \"\(params["id"] ?? "")\"}"
        })

        let resp = await server.handleRequest(jsonrpc("resources/templates/list"))
        let result = resp?["result"] as? [String: Any]
        let templates = result?["resourceTemplates"] as? [[String: Any]]
        XCTAssertEqual(templates?.count, 1)
        XCTAssertEqual(templates?[0]["uriTemplate"] as? String, "user://{id}/profile")
        XCTAssertEqual(templates?[0]["name"] as? String, "User Profile")
        XCTAssertEqual(templates?[0]["description"] as? String, "A user profile")
        XCTAssertEqual(templates?[0]["mimeType"] as? String, "application/json")
    }

    // MARK: - Template URI matching (via resources/read)

    func testTemplateMatchingSingleParam() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        server.resourceTemplate("user", ResourceTemplateDefinition(
            uriTemplate: "user://{id}/profile",
            name: "User Profile"
        ) { params in
            "user=\(params["id"] ?? "?")"
        })

        let resp = await server.handleRequest(jsonrpc("resources/read", params: [
            "uri": "user://42/profile"
        ]))
        let contents = ((resp?["result"] as? [String: Any])?["contents"] as? [[String: Any]])!
        XCTAssertEqual(contents[0]["text"] as? String, "user=42")
    }

    func testTemplateMatchingMultipleParams() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        server.resourceTemplate("repo", ResourceTemplateDefinition(
            uriTemplate: "repo://{owner}/{name}",
            name: "Repo"
        ) { params in
            "\(params["owner"] ?? "")/\(params["name"] ?? "")"
        })

        let resp = await server.handleRequest(jsonrpc("resources/read", params: [
            "uri": "repo://antidrift/zeromcp"
        ]))
        let contents = ((resp?["result"] as? [String: Any])?["contents"] as? [[String: Any]])!
        XCTAssertEqual(contents[0]["text"] as? String, "antidrift/zeromcp")
    }

    func testTemplateNoMatch() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        server.resourceTemplate("user", ResourceTemplateDefinition(
            uriTemplate: "user://{id}/profile",
            name: "User Profile"
        ) { _ in "should not reach" })

        let resp = await server.handleRequest(jsonrpc("resources/read", params: [
            "uri": "other://foo/bar"
        ]))
        let error = resp?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32002)
    }

    func testTemplateReadError() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        server.resourceTemplate("user", ResourceTemplateDefinition(
            uriTemplate: "user://{id}",
            name: "User"
        ) { _ in
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "template read failed"])
        })

        let resp = await server.handleRequest(jsonrpc("resources/read", params: [
            "uri": "user://42"
        ]))
        let error = resp?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32603)
    }

    // MARK: - Prompts

    func testPromptRegistrationAndList() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        server.prompt("greet", PromptDefinition(
            name: "greet",
            description: "Greeting prompt",
            arguments: [
                PromptArgument(name: "name", description: "User name", required: true),
                PromptArgument(name: "style", description: "Greeting style", required: false),
            ]
        ) { args in
            [["role": "user", "content": ["type": "text", "text": "Hello \(args["name"] ?? "")"]]]
        })

        let resp = await server.handleRequest(jsonrpc("prompts/list"))
        let result = resp?["result"] as? [String: Any]
        let prompts = result?["prompts"] as? [[String: Any]]
        XCTAssertEqual(prompts?.count, 1)
        XCTAssertEqual(prompts?[0]["name"] as? String, "greet")
        XCTAssertEqual(prompts?[0]["description"] as? String, "Greeting prompt")

        let args = prompts?[0]["arguments"] as? [[String: Any]]
        XCTAssertEqual(args?.count, 2)
        let nameArg = args?.first { ($0["name"] as? String) == "name" }
        XCTAssertEqual(nameArg?["required"] as? Bool, true)
        XCTAssertEqual(nameArg?["description"] as? String, "User name")
    }

    func testPromptGet() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        server.prompt("greet", PromptDefinition(
            name: "greet"
        ) { args in
            [["role": "user", "content": ["type": "text", "text": "Hello \(args["name"] ?? "World")"]]]
        })

        let resp = await server.handleRequest(jsonrpc("prompts/get", params: [
            "name": "greet",
            "arguments": ["name": "Alice"]
        ]))
        let result = resp?["result"] as? [String: Any]
        let messages = result?["messages"] as? [[String: Any]]
        XCTAssertEqual(messages?.count, 1)
        XCTAssertEqual(messages?[0]["role"] as? String, "user")
    }

    func testPromptGetNotFound() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        let resp = await server.handleRequest(jsonrpc("prompts/get", params: [
            "name": "nonexistent"
        ]))
        let error = resp?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32002)
    }

    func testPromptGetError() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        server.prompt("bad", PromptDefinition(name: "bad") { _ in
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "render failed"])
        })
        let resp = await server.handleRequest(jsonrpc("prompts/get", params: [
            "name": "bad"
        ]))
        let error = resp?["error"] as? [String: Any]
        XCTAssertEqual(error?["code"] as? Int, -32603)
    }

    func testMultiplePromptsSorted() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        server.prompt("zulu", PromptDefinition(name: "zulu") { _ in [] })
        server.prompt("alpha", PromptDefinition(name: "alpha") { _ in [] })

        let resp = await server.handleRequest(jsonrpc("prompts/list"))
        let prompts = ((resp?["result"] as? [String: Any])?["prompts"] as? [[String: Any]])!
        let names = prompts.map { $0["name"] as! String }
        XCTAssertEqual(names, ["alpha", "zulu"])
    }

    // MARK: - Pagination

    func testPaginationDisabledByDefault() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        for i in 0..<5 {
            server.tool("tool\(i)", description: "Tool \(i)", input: [:]) { _, _ in "" }
        }

        let resp = await server.handleRequest(jsonrpc("tools/list"))
        let result = resp?["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 5)
        XCTAssertNil(result?["nextCursor"])
    }

    func testPaginationFirstPage() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        server.pageSize = 2
        for i in 0..<5 {
            server.tool("tool\(i)", description: "Tool \(i)", input: [:]) { _, _ in "" }
        }

        let resp = await server.handleRequest(jsonrpc("tools/list"))
        let result = resp?["result"] as? [String: Any]
        let tools = result?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 2)
        XCTAssertNotNil(result?["nextCursor"])
    }

    func testPaginationSecondPage() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        server.pageSize = 2
        for i in 0..<5 {
            server.tool("tool\(i)", description: "Tool \(i)", input: [:]) { _, _ in "" }
        }

        // Get first page to obtain cursor
        let resp1 = await server.handleRequest(jsonrpc("tools/list"))
        let result1 = resp1?["result"] as? [String: Any]
        let cursor = result1?["nextCursor"] as! String

        // Get second page
        let resp2 = await server.handleRequest(jsonrpc("tools/list", params: ["cursor": cursor]))
        let result2 = resp2?["result"] as? [String: Any]
        let tools2 = result2?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools2?.count, 2)
        XCTAssertNotNil(result2?["nextCursor"])
    }

    func testPaginationLastPage() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        server.pageSize = 3
        for i in 0..<5 {
            server.tool("tool\(i)", description: "Tool \(i)", input: [:]) { _, _ in "" }
        }

        // First page: 3 items
        let resp1 = await server.handleRequest(jsonrpc("tools/list"))
        let cursor = (resp1?["result"] as? [String: Any])?["nextCursor"] as! String

        // Second page: 2 items, no next cursor
        let resp2 = await server.handleRequest(jsonrpc("tools/list", params: ["cursor": cursor]))
        let result2 = resp2?["result"] as? [String: Any]
        let tools2 = result2?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools2?.count, 2)
        XCTAssertNil(result2?["nextCursor"])
    }

    func testPaginationOnResources() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        server.pageSize = 1
        server.resource("a", ResourceDefinition(uri: "file:///a", name: "A") { "a" })
        server.resource("b", ResourceDefinition(uri: "file:///b", name: "B") { "b" })

        let resp = await server.handleRequest(jsonrpc("resources/list"))
        let result = resp?["result"] as? [String: Any]
        let resources = result?["resources"] as? [[String: Any]]
        XCTAssertEqual(resources?.count, 1)
        XCTAssertNotNil(result?["nextCursor"])
    }

    func testPaginationOnPrompts() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        server.pageSize = 1
        server.prompt("a", PromptDefinition(name: "a") { _ in [] })
        server.prompt("b", PromptDefinition(name: "b") { _ in [] })

        let resp = await server.handleRequest(jsonrpc("prompts/list"))
        let result = resp?["result"] as? [String: Any]
        let prompts = result?["prompts"] as? [[String: Any]]
        XCTAssertEqual(prompts?.count, 1)
        XCTAssertNotNil(result?["nextCursor"])
    }

    func testPaginationOnTemplates() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        server.pageSize = 1
        server.resourceTemplate("a", ResourceTemplateDefinition(
            uriTemplate: "a://{id}", name: "A") { _ in "a" })
        server.resourceTemplate("b", ResourceTemplateDefinition(
            uriTemplate: "b://{id}", name: "B") { _ in "b" })

        let resp = await server.handleRequest(jsonrpc("resources/templates/list"))
        let result = resp?["result"] as? [String: Any]
        let templates = result?["resourceTemplates"] as? [[String: Any]]
        XCTAssertEqual(templates?.count, 1)
        XCTAssertNotNil(result?["nextCursor"])
    }

    // MARK: - Logging

    func testLoggingSetLevel() async {
        let server = makeServer()
        let resp = await server.handleRequest(jsonrpc("logging/setLevel", params: [
            "level": "debug"
        ]))
        XCTAssertNotNil(resp?["result"])
    }

    // MARK: - Completion

    func testCompletionComplete() async {
        let server = makeServer()
        let resp = await server.handleRequest(jsonrpc("completion/complete", params: [:]))
        let result = resp?["result"] as? [String: Any]
        let completion = result?["completion"] as? [String: Any]
        XCTAssertNotNil(completion?["values"])
    }

    // MARK: - Response ID propagation

    func testResponseContainsRequestId() async {
        let server = makeServer()
        let resp = await server.handleRequest(jsonrpc("ping", id: 42))
        XCTAssertEqual(resp?["id"] as? Int, 42)
        XCTAssertEqual(resp?["jsonrpc"] as? String, "2.0")
    }

    func testResponseStringId() async {
        let server = makeServer()
        let resp = await server.handleRequest([
            "jsonrpc": "2.0",
            "id": "abc-123",
            "method": "ping",
            "params": [:] as [String: Any]
        ])
        XCTAssertEqual(resp?["id"] as? String, "abc-123")
    }

    // MARK: - Tool builder style registration

    func testToolBuilderStyle() async {
        let server = ZeroMcp(config: ZeroMcpConfig())
        server.tool("echo", {
            ToolBuilder(description: "Echo", input: ["msg": .simple(.string)])
        }) { args, _ in
            args["msg"] as? String ?? ""
        }

        let resp = await server.handleRequest(jsonrpc("tools/list"))
        let tools = ((resp?["result"] as? [String: Any])?["tools"] as? [[String: Any]])!
        XCTAssertEqual(tools.count, 1)
        XCTAssertEqual(tools[0]["name"] as? String, "echo")
    }
}
