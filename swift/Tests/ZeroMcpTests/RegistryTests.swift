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

    func testRoutesOnlyIncludesRoutedTools() {
        let registry = createRegistry([
            "greet": routedTool(),
            "hidden": unroutedTool(),
        ])
        XCTAssertEqual(registry.routes.count, 1)
        XCTAssertEqual(registry.routes[0].name, "greet")
        XCTAssertEqual(registry.routes[0].method, "GET")
        XCTAssertEqual(registry.routes[0].path, "/greet/:name")
    }

    func testRoutesAreSortedByName() {
        let registry = createRegistry([
            "charlie": routedTool(path: "/charlie"),
            "alpha": routedTool(path: "/alpha"),
            "bravo": routedTool(path: "/bravo"),
        ])
        XCTAssertEqual(registry.routes.map { $0.name }, ["alpha", "bravo", "charlie"])
    }

    func testOpenApiMatchesRoutedTools() {
        let registry = createRegistry(["greet": routedTool()])
        let paths = registry.openapi["paths"] as? [String: Any]
        XCTAssertNotNil(paths?["/greet/{name}"])
    }

    func testRouteToolInvokedDirectlyProducesExpectedResult() async throws {
        let registry = createRegistry(["greet": routedTool()])
        let route = registry.routes[0]
        let ctx = ToolContext(toolName: route.name, permissions: route.tool.permissions)
        let result = try await route.tool.execute(["name": "Ada"], ctx)
        XCTAssertEqual(result as? String, "hi Ada")
    }

    func testMcpDispatchesToolsList() async {
        let registry = createRegistry(["greet": routedTool()])
        let response = await registry.mcp([
            "jsonrpc": "2.0", "id": 1, "method": "tools/list",
        ])
        let tools = (response?["result"] as? [String: Any])?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 1)
        XCTAssertEqual(tools?.first?["name"] as? String, "greet")
    }

    func testMcpDispatchesToolsCall() async {
        let registry = createRegistry(["greet": routedTool(method: "POST", path: "/greet")])
        let response = await registry.mcp([
            "jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": ["name": "greet", "arguments": ["name": "Ada"]],
        ])
        let content = (response?["result"] as? [String: Any])?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["text"] as? String, "hi Ada")
    }

    func testEmptyWhenNoRoutedTools() {
        let registry = createRegistry(["hidden": unroutedTool()])
        XCTAssertEqual(registry.routes.count, 0)
    }

    func testRegistryOptionsDefaultConfigDoesNotLoadFromDisk() {
        // Should not throw / hang trying to read ./zeromcp.config.json; just build cleanly.
        let registry = createRegistry(["greet": routedTool()], options: RegistryOptions())
        XCTAssertEqual(registry.routes.count, 1)
    }
}
