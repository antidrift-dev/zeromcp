import XCTest
@testable import ZeroMcp

final class RegistryTests: XCTestCase {
    private func routedTool(method: String = "GET", path: String = "/greet/:name") -> ToolDefinition {
        ToolDefinition(
            description: "Greet someone",
            input: ["name": .simple(.string)],
            route: RouteDefinition(method: method, path: path)
        ) { args, _ in
            "hi \(args["name"] as! String)"
        }
    }

    private func unroutedTool() -> ToolDefinition {
        ToolDefinition(description: "No route") { _, _ in
            ""
        }
    }

    func testRoutesOnlyIncludesRoutedTools() async {
        let registry = await createRegistry([
            "greet": routedTool(),
            "hidden": unroutedTool(),
        ])
        XCTAssertEqual(registry.routes.count, 1)
        XCTAssertEqual(registry.routes[0].name, "greet")
        XCTAssertEqual(registry.routes[0].method, "GET")
        XCTAssertEqual(registry.routes[0].path, "/greet/:name")
    }

    func testRoutesAreSortedByName() async {
        let registry = await createRegistry([
            "charlie": routedTool(path: "/charlie"),
            "alpha": routedTool(path: "/alpha"),
            "bravo": routedTool(path: "/bravo"),
        ])
        XCTAssertEqual(registry.routes.map { $0.name }, ["alpha", "bravo", "charlie"])
    }

    func testOpenApiMatchesRoutedTools() async {
        let registry = await createRegistry(["greet": routedTool()])
        let paths = registry.openapi["paths"] as? [String: Any]
        XCTAssertNotNil(paths?["/greet/{name}"])
    }

    func testRouteToolInvokedDirectlyProducesExpectedResult() async throws {
        let registry = await createRegistry(["greet": routedTool()])
        let route = registry.routes[0]
        let ctx = ToolContext(toolName: route.name, permissions: route.tool.permissions)
        let result = try await route.tool.execute(["name": "Ada"], ctx)
        XCTAssertEqual(result as? String, "hi Ada")
    }

    func testMcpDispatchesToolsList() async {
        let registry = await createRegistry(["greet": routedTool()])
        let response = await registry.mcp([
            "jsonrpc": "2.0", "id": 1, "method": "tools/list",
        ])
        let tools = (response?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 1)
        XCTAssertEqual(tools?.first?["name"] as? String, "greet")
    }

    func testMcpDispatchesToolsCall() async {
        let registry = await createRegistry(["greet": routedTool(method: "POST", path: "/greet")])
        let response = await registry.mcp([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "greet", "arguments": ["name": "Ada"]],
        ])
        let content = (response?["result"] as? [String: Any])?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["text"] as? String, "hi Ada")
    }

    func testEmptyWhenNoRoutedTools() async {
        let registry = await createRegistry(["hidden": unroutedTool()])
        XCTAssertEqual(registry.routes.count, 0)
    }

    func testRegistryOptionsDefaultConfigDoesNotLoadFromDisk() async {
        // Should not throw / hang trying to read ./zeromcp.config.json; just build cleanly.
        let registry = await createRegistry(["greet": routedTool()], options: RegistryOptions())
        XCTAssertEqual(registry.routes.count, 1)
    }

    // MARK: - Remote

    private func toolNames(_ registry: Registry) async -> [String] {
        let response = await registry.mcp(["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        let tools = (response?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        return tools.compactMap { $0["name"] as? String }
    }

    func testRemoteToolsMergedIntoMcp() async {
        let up = FakeUpstream()
        defer { up.stop() }
        let registry = await createRegistry(
            ["greet": routedTool()],
            options: RegistryOptions(config: ZeroMcpConfig(remote: [RemoteServer(name: "up", url: up.url)]))
        )
        let names = await toolNames(registry)
        XCTAssertEqual(names, ["greet", "up.get_page", "up.list_pages"])

        let response = await registry.mcp([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "up.get_page", "arguments": ["url": "u1"]],
        ])
        let content = (response?["result"] as? [String: Any])?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["text"] as? String, "page:u1")
    }

    func testLocalToolOverridesRemoteInRegistry() async {
        let up = FakeUpstream()
        defer { up.stop() }
        var registry: Registry?
        let log = await captureStderr {
            registry = await createRegistry(
                ["up.get_page": unroutedTool()],
                options: RegistryOptions(config: ZeroMcpConfig(remote: [RemoteServer(name: "up", url: up.url)]))
            )
        }
        XCTAssertTrue(log.contains("[zeromcp] Local tool \"up.get_page\" overrides remote"), log)
        let response = await registry!.mcp([
            "jsonrpc": "2.0", "id": 2, "method": "tools/call",
            "params": ["name": "up.get_page", "arguments": ["url": "u1"]],
        ])
        let content = (response?["result"] as? [String: Any])?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["text"] as? String, "")
    }

    func testRemoteToolsAbsentFromRoutesAndOpenApi() async {
        let up = FakeUpstream()
        defer { up.stop() }
        let registry = await createRegistry(
            ["greet": routedTool()],
            options: RegistryOptions(config: ZeroMcpConfig(remote: [RemoteServer(name: "up", url: up.url)]))
        )
        XCTAssertEqual(registry.routes.map { $0.name }, ["greet"])
        let paths = registry.openapi["paths"] as? [String: Any]
        XCTAssertEqual(paths?.keys.sorted(), ["/greet/{name}"])
    }

    // MARK: - Runtime context (Node's getEnv)

    func testGetRuntimeReachesCtxRuntimeThroughMcp() async {
        let tool = ToolDefinition(description: "env") { _, ctx in
            (ctx.runtime as? [String: String])?["TENANT"] ?? "none"
        }
        let registry = await createRegistry(
            ["whoami": tool],
            options: RegistryOptions(getRuntime: { ["TENANT": "acme"] })
        )
        let response = await registry.mcp([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "whoami", "arguments": [:] as [String: Any]],
        ])
        let content = (response?["result"] as? [String: Any])?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["text"] as? String, "acme")
    }
}
