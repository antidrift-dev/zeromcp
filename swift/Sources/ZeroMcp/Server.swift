import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public class ZeroMcp {
    private var tools: [String: ToolDefinition] = [:]
    private let config: ZeroMcpConfig

    public init(config: ZeroMcpConfig? = nil) {
        self.config = config ?? ZeroMcpConfig.load()
    }

    // Register a tool using builder pattern
    public func tool(
        _ name: String,
        description: String,
        input: InputSchema = [:],
        permissions: Permissions = Permissions(),
        execute: @escaping ([String: Any], ToolContext) async throws -> Any
    ) {
        tools[name] = ToolDefinition(
            description: description,
            input: input,
            permissions: permissions,
            execute: execute
        )
    }

    // Register a tool using trailing closure style
    public func tool(
        _ name: String,
        _ builder: () -> ToolBuilder,
        execute: @escaping ([String: Any], ToolContext) async throws -> Any
    ) {
        let b = builder()
        tools[name] = ToolDefinition(
            description: b.description,
            input: b.input,
            execute: execute
        )
    }

    public func serve() async {
        fputs(stderr, "[zeromcp] \(tools.count) tool(s) loaded\n")
        fputs(stderr, "[zeromcp] stdio transport ready\n")

        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            guard let data = trimmed.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }

            if let response = await handleRequest(request) {
                if let responseData = try? JSONSerialization.data(withJSONObject: response),
                   let responseString = String(data: responseData, encoding: .utf8) {
                    print(responseString)
                    fflush(stdout)
                }
            }
        }
    }

    /// Process a single JSON-RPC request and return a response.
    /// Returns `nil` for notifications that require no response.
    ///
    /// Usage:
    /// ```swift
    /// let response = await server.handleRequest([
    ///     "jsonrpc": "2.0", "id": 1, "method": "tools/list"
    /// ])
    /// ```
    public func handleRequest(_ request: [String: Any]) async -> [String: Any]? {
        let id = request["id"]
        let method = request["method"] as? String ?? ""
        let params = request["params"] as? [String: Any] ?? [:]

        if id == nil && method == "notifications/initialized" {
            return nil
        }

        switch method {
        case "initialize":
            return makeResponse(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": [
                    "tools": ["listChanged": true]
                ],
                "serverInfo": [
                    "name": "zeromcp",
                    "version": "0.1.0"
                ]
            ])

        case "tools/list":
            return makeResponse(id: id, result: [
                "tools": buildToolList()
            ])

        case "tools/call":
            let result = await callTool(params)
            return makeResponse(id: id, result: result)

        case "ping":
            return makeResponse(id: id, result: [:] as [String: Any])

        default:
            if id == nil { return nil }
            return [
                "jsonrpc": "2.0",
                "id": id as Any,
                "error": ["code": -32601, "message": "Method not found: \(method)"]
            ]
        }
    }

    private func makeResponse(id: Any?, result: Any) -> [String: Any] {
        var response: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id = id {
            response["id"] = id
        }
        return response
    }

    private func buildToolList() -> [[String: Any]] {
        return tools.map { (name, tool) in
            let schema = toJsonSchema(tool.input)
            var schemaDict: [String: Any] = [
                "type": schema.type,
                "required": schema.required
            ]
            var propsDict: [String: Any] = [:]
            for (key, prop) in schema.properties {
                var propDict: [String: Any] = ["type": prop.type]
                if let desc = prop.description {
                    propDict["description"] = desc
                }
                propsDict[key] = propDict
            }
            schemaDict["properties"] = propsDict

            return [
                "name": name,
                "description": tool.description,
                "inputSchema": schemaDict
            ]
        }.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
    }

    private func callTool(_ params: [String: Any]) async -> [String: Any] {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]

        guard let tool = tools[name] else {
            return [
                "content": [["type": "text", "text": "Unknown tool: \(name)"]],
                "isError": true
            ]
        }

        let schema = toJsonSchema(tool.input)
        let errors = validateInput(args, schema: schema)
        if !errors.isEmpty {
            return [
                "content": [["type": "text", "text": "Validation errors:\n\(errors.joined(separator: "\n"))"]],
                "isError": true
            ]
        }

        // Tool-level timeout overrides config default
        let timeoutSecs = tool.permissions.executeTimeout ?? config.executeTimeout ?? 30.0

        do {
            let ctx = ToolContext(toolName: name, permissions: tool.permissions)
            let result = try await withThrowingTaskGroup(of: Any.self) { group in
                group.addTask {
                    return try await tool.execute(args, ctx)
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: UInt64(timeoutSecs * 1_000_000_000))
                    throw ZeroMcpTimeoutError(toolName: name, timeoutSecs: timeoutSecs)
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            let text: String
            if let s = result as? String {
                text = s
            } else if let data = try? JSONSerialization.data(
                withJSONObject: result,
                options: []
            ) {
                text = String(data: data, encoding: .utf8) ?? "\(result)"
            } else {
                text = "\(result)"
            }
            return ["content": [["type": "text", "text": text]]]
        } catch let e as ZeroMcpTimeoutError {
            return [
                "content": [["type": "text", "text": "Tool \"\(e.toolName)\" timed out after \(e.timeoutSecs)s"]],
                "isError": true
            ]
        } catch {
            return [
                "content": [["type": "text", "text": "Error: \(error.localizedDescription)"]],
                "isError": true
            ]
        }
    }
}

struct ZeroMcpTimeoutError: Error {
    let toolName: String
    let timeoutSecs: Double
}

private func fputs(_ stream: UnsafeMutablePointer<FILE>, _ string: String) {
    #if canImport(Darwin)
    Darwin.fputs(string, stream)
    #elseif canImport(Glibc)
    Glibc.fputs(string, stream)
    #endif
}
