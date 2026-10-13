import XCTest
@testable import ZeroMcp

final class RemoteTests: XCTestCase {
    private var upstreams: [FakeUpstream] = []

    override func tearDown() {
        upstreams.forEach { $0.stop() }
        upstreams = []
        super.tearDown()
    }

    private func upstream(requiredToken: String? = nil, status: Int? = nil) -> FakeUpstream {
        let up = FakeUpstream(requiredToken: requiredToken, status: status)
        upstreams.append(up)
        return up
    }

    private func rpc(_ method: String, id: Int = 1, params: [String: Any] = [:]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
    }

    private func toolNames(_ server: ZeroMcp) async -> [String] {
        let resp = await server.handleRequest(rpc("tools/list"))
        let tools = (resp?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
        return tools.compactMap { $0["name"] as? String }
    }

    private func callText(_ server: ZeroMcp, _ name: String, _ args: [String: Any]) async -> (String?, Bool) {
        let resp = await server.handleRequest(rpc("tools/call", params: ["name": name, "arguments": args]))
        let result = resp?["result"] as? [String: Any]
        let text = (result?["content"] as? [[String: Any]])?.first?["text"] as? String
        return (text, result?["isError"] as? Bool ?? false)
    }

    private func server(_ remote: [RemoteServer]) -> ZeroMcp {
        ZeroMcp(config: ZeroMcpConfig(remote: remote))
    }

    // MARK: - §1 federation

    func testToolsListShowsNamespacedRemoteTools() async {
        let up = upstream()
        let s = server([RemoteServer(name: "up", url: up.url)])
        await s.prepare()
        let names = await toolNames(s)
        XCTAssertEqual(names, ["up.get_page", "up.list_pages"])
    }

    func testToolsCallReturnsUpstreamText() async {
        let up = upstream()
        let s = server([RemoteServer(name: "up", url: up.url)])
        await s.prepare()
        let (text, isError) = await callText(s, "up.get_page", ["url": "https://x.test"])
        XCTAssertFalse(isError)
        XCTAssertEqual(text, "page:https://x.test")
        XCTAssertEqual(up.requests.last?.method, "tools/call")
    }

    func testRemoteToolValidatesInputFromRemoteSchema() async {
        let up = upstream()
        let s = server([RemoteServer(name: "up", url: up.url)])
        await s.prepare()
        let (text, isError) = await callText(s, "up.get_page", [:])
        XCTAssertTrue(isError)
        XCTAssertTrue(text?.contains("Missing required field: url") ?? false)
    }

    func testLocalToolOverridesRemoteAndLogs() async {
        let up = upstream()
        let s = server([RemoteServer(name: "up", url: up.url)])
        s.tool("up.list_pages", description: "local") { _, _ in "local result" }
        let log = await captureStderr { await s.prepare() }
        XCTAssertTrue(log.contains("[zeromcp] Local tool \"up.list_pages\" overrides remote"), log)
        let (text, _) = await callText(s, "up.list_pages", ["domain": "a"])
        XCTAssertEqual(text, "local result")
        XCTAssertFalse(s.remoteToolNames.contains("up.list_pages"))
        XCTAssertTrue(s.remoteToolNames.contains("up.get_page"))
    }

    func testBadServersAreSkippedAndGoodOneConnects() async {
        let up = upstream()
        let s = server([
            RemoteServer(name: "ws", url: "ws://127.0.0.1:1/mcp"),
            RemoteServer(name: "down", url: "http://127.0.0.1:\(unusedPort())/mcp"),
            RemoteServer(name: "up", url: up.url),
        ])
        let log = await captureStderr { await s.prepare() }
        XCTAssertTrue(log.contains("[mcp] Failed to connect to ws: Remote server \"ws\" must have an HTTP/HTTPS URL, got: ws://127.0.0.1:1/mcp"), log)
        XCTAssertTrue(log.contains("[mcp] Failed to connect to down: "), log)
        XCTAssertTrue(log.contains("[mcp] Remote tool: up.list_pages"), log)
        XCTAssertTrue(log.contains("[mcp] Connected to up (HTTP): 2 tool(s)"), log)
        let names = await toolNames(s)
        XCTAssertEqual(names, ["up.get_page", "up.list_pages"])
    }

    func testNon2xxIsAConnectFailure() async {
        let up = upstream(status: 500)
        let s = server([RemoteServer(name: "up", url: up.url)])
        let log = await captureStderr { await s.prepare() }
        XCTAssertTrue(log.contains("[mcp] Failed to connect to up: HTTP 500"), log)
        let names = await toolNames(s)
        XCTAssertEqual(names, [])
    }

    func testBearerHeaderIsSent() async {
        let up = upstream(requiredToken: "secret")
        let s = server([RemoteServer(name: "up", url: up.url, auth: "secret")])
        await s.prepare()
        let names = await toolNames(s)
        XCTAssertEqual(names.count, 2)
        XCTAssertEqual(up.requests.first?.auth, "Bearer secret")
    }

    func testBearerFromEnv() async {
        setenv("ZEROMCP_TEST_REMOTE_TOKEN", "envsecret", 1)
        defer { unsetenv("ZEROMCP_TEST_REMOTE_TOKEN") }
        let up = upstream(requiredToken: "envsecret")
        let s = server([RemoteServer(name: "up", url: up.url, auth: "env:ZEROMCP_TEST_REMOTE_TOKEN")])
        await s.prepare()
        let names = await toolNames(s)
        XCTAssertEqual(names.count, 2)
    }

    func testMissingAuthGetsZeroTools() async {
        let up = upstream(requiredToken: "secret")
        let s = server([RemoteServer(name: "up", url: up.url)])
        let log = await captureStderr { await s.prepare() }
        XCTAssertTrue(log.contains("[mcp] Failed to connect to up: HTTP 401"), log)
        let names = await toolNames(s)
        XCTAssertEqual(names, [])
        XCTAssertNil(up.requests.first?.auth)
    }

    func testRemoteToolsHaveNoRoute() async {
        let up = upstream()
        let s = server([RemoteServer(name: "up", url: up.url)])
        await s.prepare()
        XCTAssertNil(s.tools["up.list_pages"]?.route)
    }

    // MARK: - schemaToInput

    func testSchemaToInputSimpleVsExtended() {
        let input = schemaToInput([
            "type": "object",
            "properties": [
                "a": ["type": "string"],
                "b": ["type": "number", "description": "B"],
                "c": ["type": "boolean"],
                "d": [:] as [String: Any],
                "e": ["type": "integer"],
            ],
            "required": ["a", "b", "d", "e"],
        ])
        guard case .simple(.string) = input["a"]! else { return XCTFail("a") }
        guard case .extended(.number, "B", false) = input["b"]! else { return XCTFail("b") }
        guard case .extended(.boolean, nil, true) = input["c"]! else { return XCTFail("c") }
        guard case .simple(.string) = input["d"]! else { return XCTFail("d: missing type → string") }
        guard case .simple(.string) = input["e"]! else { return XCTFail("e: unknown type → string") }
    }

    func testSchemaToInputNoProperties() {
        XCTAssertTrue(schemaToInput(nil).isEmpty)
        XCTAssertTrue(schemaToInput(["type": "object"]).isEmpty)
    }

    // MARK: - resolveAuth

    func testResolveAuth() async {
        setenv("ZEROMCP_TEST_AUTH", "tok", 1)
        defer { unsetenv("ZEROMCP_TEST_AUTH") }
        XCTAssertEqual(resolveAuth("env:ZEROMCP_TEST_AUTH"), "tok")
        XCTAssertEqual(resolveAuth("literal"), "literal")
        XCTAssertNil(resolveAuth(nil))

        unsetenv("ZEROMCP_TEST_AUTH_MISSING")
        var value: String? = "sentinel"
        let log = await captureStderr { value = resolveAuth("env:ZEROMCP_TEST_AUTH_MISSING") }
        XCTAssertNil(value)
        XCTAssertTrue(log.contains("[zeromcp] Warning: environment variable ZEROMCP_TEST_AUTH_MISSING not set"), log)
    }

    // MARK: - §2 allowlist

    func testAllowlistKeepsOnlyListedTools() async {
        let up = upstream()
        let s = server([RemoteServer(name: "up", url: up.url, tools: ["list_pages"])])
        await s.prepare()
        let names = await toolNames(s)
        XCTAssertEqual(names, ["up.list_pages"])
    }

    func testAllowlistOmittedKeepsAll() async {
        let up = upstream()
        let s = server([RemoteServer(name: "up", url: up.url, tools: nil)])
        await s.prepare()
        let names = await toolNames(s)
        XCTAssertEqual(names, ["up.get_page", "up.list_pages"])
    }

    func testRemoteDecodesFromConfigJson() throws {
        let json = #"{"remote":[{"name":"up","url":"http://h/mcp","auth":"env:X","tools":["a"]}]}"#
        let config = try JSONDecoder().decode(ZeroMcpConfig.self, from: Data(json.utf8))
        XCTAssertEqual(config.remote?.first?.name, "up")
        XCTAssertEqual(config.remote?.first?.url, "http://h/mcp")
        XCTAssertEqual(config.remote?.first?.auth, "env:X")
        XCTAssertEqual(config.remote?.first?.tools, ["a"])
    }

    // MARK: - §3 handleRequest + prepare

    func testHandleRequestAfterPrepareMirrorsNodeHandlerRemote() async {
        let up = upstream()
        let s = server([RemoteServer(name: "probeo", url: up.url, tools: ["list_pages"])])
        await s.prepare()
        let names = await toolNames(s)
        XCTAssertEqual(names, ["probeo.list_pages"])
        let (text, isError) = await callText(s, "probeo.list_pages", ["domain": "example.com"])
        XCTAssertFalse(isError)
        let parsed = text.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) } as? [String: Any]
        XCTAssertEqual((parsed?["args"] as? [String: Any])?["domain"] as? String, "example.com")
        let (missing, missingIsError) = await callText(s, "probeo.get_page", ["url": "x"])
        XCTAssertTrue(missingIsError)
        XCTAssertEqual(missing, "Unknown tool: probeo.get_page")
    }

    func testPrepareIsIdempotent() async {
        let up = upstream()
        let s = server([RemoteServer(name: "up", url: up.url)])
        await s.prepare()
        await s.prepare()
        let names = await toolNames(s)
        XCTAssertEqual(names, ["up.get_page", "up.list_pages"])
        XCTAssertEqual(up.requests.filter { $0.method == "tools/list" }.count, 1)
        XCTAssertEqual(up.requests.filter { $0.method == "initialize" }.count, 1)
    }

    func testHandleRequestDoesNotConnectLazily() async {
        let up = upstream()
        let s = server([RemoteServer(name: "up", url: up.url)])
        let names = await toolNames(s)
        XCTAssertEqual(names, [])
        XCTAssertEqual(up.requests.count, 0)
    }

    // MARK: - §5 runtime not passed to remote tools

    func testRemoteToolsDoNotCallGetRuntime() async {
        let up = upstream()
        let s = server([RemoteServer(name: "up", url: up.url)])
        var calls = 0
        s.getRuntime = { calls += 1; return "rt" }
        await s.prepare()
        _ = await callText(s, "up.get_page", ["url": "u"])
        XCTAssertEqual(calls, 0)
    }
}
