import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public class ZeroMcp {
    private var tools: [String: ToolDefinition] = [:]
    private var resources: [String: ResourceDefinition] = [:]
    private var templates: [String: ResourceTemplateDefinition] = [:]
    private var prompts: [String: PromptDefinition] = [:]
    private var subscriptions: Set<String> = []
    private var logLevel: String = "info"
    private var roots: [[String: Any]] = []
    private var clientCapabilities: [String: Any] = [:]
    private let config: ZeroMcpConfig

    /// Optional icon URI included in list responses.
    public var icon: String?

    /// Page size for cursor-based pagination. 0 means no pagination.
    public var pageSize: Int = 0

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

    // Register a static resource
    public func resource(_ name: String, _ definition: ResourceDefinition) {
        resources[name] = definition
    }

    // Register a resource template
    public func resourceTemplate(_ name: String, _ definition: ResourceTemplateDefinition) {
        templates[name] = definition
    }

    // Register a prompt
    public func prompt(_ name: String, _ definition: PromptDefinition) {
        prompts[name] = definition
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

        // Notifications (no id) — no response expected
        if id == nil {
            handleNotification(method, params)
            return nil
        }

        switch method {
        case "initialize":
            return handleInitialize(id: id, params: params)

        case "ping":
            return makeResponse(id: id, result: [:] as [String: Any])

        // Tools
        case "tools/list":
            return handleToolsList(id: id, params: params)
        case "tools/call":
            return await handleToolsCall(id: id, params: params)

        // Resources
        case "resources/list":
            return handleResourcesList(id: id, params: params)
        case "resources/read":
            return await handleResourcesRead(id: id, params: params)
        case "resources/subscribe":
            return handleResourcesSubscribe(id: id, params: params)
        case "resources/templates/list":
            return handleResourcesTemplatesList(id: id, params: params)

        // Prompts
        case "prompts/list":
            return handlePromptsList(id: id, params: params)
        case "prompts/get":
            return await handlePromptsGet(id: id, params: params)

        // Passthrough
        case "logging/setLevel":
            return handleLoggingSetLevel(id: id, params: params)
        case "completion/complete":
            return handleCompletionComplete(id: id, params: params)

        default:
            return [
                "jsonrpc": "2.0",
                "id": id as Any,
                "error": ["code": -32601, "message": "Method not found: \(method)"]
            ]
        }
    }

    // MARK: - Notifications

    private func handleNotification(_ method: String, _ params: [String: Any]) {
        switch method {
        case "notifications/initialized":
            break
        case "notifications/roots/list_changed":
            if let r = params["roots"] as? [[String: Any]] {
                roots = r
            }
        default:
            break
        }
    }

    // MARK: - Initialize

    private func handleInitialize(id: Any?, params: [String: Any]) -> [String: Any] {
        if let caps = params["capabilities"] as? [String: Any] {
            clientCapabilities = caps
        }

        var capabilities: [String: Any] = [
            "tools": ["listChanged": true]
        ]

        if !resources.isEmpty || !templates.isEmpty {
            capabilities["resources"] = ["subscribe": true, "listChanged": true] as [String: Any]
        }

        if !prompts.isEmpty {
            capabilities["prompts"] = ["listChanged": true]
        }

        capabilities["logging"] = [:] as [String: Any]

        var serverInfo: [String: Any] = [
            "name": "zeromcp",
            "version": "0.2.0"
        ]
        if let icon = icon {
            serverInfo["icon"] = icon
        }

        return makeResponse(id: id, result: [
            "protocolVersion": "2024-11-05",
            "capabilities": capabilities,
            "serverInfo": serverInfo
        ])
    }

    // MARK: - Tools

    private func handleToolsList(id: Any?, params: [String: Any]) -> [String: Any] {
        let cursor = params["cursor"] as? String
        let list = buildToolList()
        let page = paginate(list, cursor: cursor, pageSize: pageSize)
        var result: [String: Any] = ["tools": page.items]
        if let next = page.nextCursor { result["nextCursor"] = next }
        return makeResponse(id: id, result: result)
    }

    private func handleToolsCall(id: Any?, params: [String: Any]) async -> [String: Any] {
        let result = await callTool(params)
        return makeResponse(id: id, result: result)
    }

    // MARK: - Resources

    private func handleResourcesList(id: Any?, params: [String: Any]) -> [String: Any] {
        let cursor = params["cursor"] as? String
        var list: [[String: Any]] = []
        for (_, res) in resources.sorted(by: { $0.key < $1.key }) {
            var entry: [String: Any] = [
                "uri": res.uri,
                "name": res.name,
                "mimeType": res.mimeType
            ]
            if let desc = res.description { entry["description"] = desc }
            if let icon = icon { entry["icons"] = [["uri": icon]] }
            list.append(entry)
        }
        let page = paginate(list, cursor: cursor, pageSize: pageSize)
        var result: [String: Any] = ["resources": page.items]
        if let next = page.nextCursor { result["nextCursor"] = next }
        return makeResponse(id: id, result: result)
    }

    private func handleResourcesRead(id: Any?, params: [String: Any]) async -> [String: Any] {
        let uri = params["uri"] as? String ?? ""

        // Check static resources
        for (_, res) in resources {
            if res.uri == uri {
                do {
                    let text = try await res.read()
                    return makeResponse(id: id, result: [
                        "contents": [["uri": uri, "mimeType": res.mimeType, "text": text]]
                    ])
                } catch {
                    return makeError(id: id, code: -32603, message: "Error reading resource: \(error.localizedDescription)")
                }
            }
        }

        // Check templates
        for (_, tmpl) in templates {
            if let match = matchTemplate(tmpl.uriTemplate, uri: uri) {
                do {
                    let text = try await tmpl.read(match)
                    return makeResponse(id: id, result: [
                        "contents": [["uri": uri, "mimeType": tmpl.mimeType, "text": text]]
                    ])
                } catch {
                    return makeError(id: id, code: -32603, message: "Error reading resource: \(error.localizedDescription)")
                }
            }
        }

        return makeError(id: id, code: -32002, message: "Resource not found: \(uri)")
    }

    private func handleResourcesSubscribe(id: Any?, params: [String: Any]) -> [String: Any] {
        if let uri = params["uri"] as? String {
            subscriptions.insert(uri)
        }
        return makeResponse(id: id, result: [:] as [String: Any])
    }

    private func handleResourcesTemplatesList(id: Any?, params: [String: Any]) -> [String: Any] {
        let cursor = params["cursor"] as? String
        var list: [[String: Any]] = []
        for (_, tmpl) in templates.sorted(by: { $0.key < $1.key }) {
            var entry: [String: Any] = [
                "uriTemplate": tmpl.uriTemplate,
                "name": tmpl.name,
                "mimeType": tmpl.mimeType
            ]
            if let desc = tmpl.description { entry["description"] = desc }
            if let icon = icon { entry["icons"] = [["uri": icon]] }
            list.append(entry)
        }
        let page = paginate(list, cursor: cursor, pageSize: pageSize)
        var result: [String: Any] = ["resourceTemplates": page.items]
        if let next = page.nextCursor { result["nextCursor"] = next }
        return makeResponse(id: id, result: result)
    }

    // MARK: - Prompts

    private func handlePromptsList(id: Any?, params: [String: Any]) -> [String: Any] {
        let cursor = params["cursor"] as? String
        var list: [[String: Any]] = []
        for (_, prompt) in prompts.sorted(by: { $0.key < $1.key }) {
            var entry: [String: Any] = ["name": prompt.name]
            if let desc = prompt.description { entry["description"] = desc }
            if let args = prompt.arguments {
                entry["arguments"] = args.map { $0.toDict() }
            }
            if let icon = icon { entry["icons"] = [["uri": icon]] }
            list.append(entry)
        }
        let page = paginate(list, cursor: cursor, pageSize: pageSize)
        var result: [String: Any] = ["prompts": page.items]
        if let next = page.nextCursor { result["nextCursor"] = next }
        return makeResponse(id: id, result: result)
    }

    private func handlePromptsGet(id: Any?, params: [String: Any]) async -> [String: Any] {
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]

        guard let prompt = prompts[name] else {
            return makeError(id: id, code: -32002, message: "Prompt not found: \(name)")
        }

        do {
            let messages = try await prompt.render(args)
            return makeResponse(id: id, result: ["messages": messages])
        } catch {
            return makeError(id: id, code: -32603, message: "Error rendering prompt: \(error.localizedDescription)")
        }
    }

    // MARK: - Passthrough

    private func handleLoggingSetLevel(id: Any?, params: [String: Any]) -> [String: Any] {
        if let level = params["level"] as? String {
            logLevel = level
        }
        return makeResponse(id: id, result: [:] as [String: Any])
    }

    private func handleCompletionComplete(id: Any?, params: [String: Any]) -> [String: Any] {
        return makeResponse(id: id, result: ["completion": ["values": [] as [Any]]])
    }

    // MARK: - Helpers

    private func makeResponse(id: Any?, result: Any) -> [String: Any] {
        var response: [String: Any] = ["jsonrpc": "2.0", "result": result]
        if let id = id {
            response["id"] = id
        }
        return response
    }

    private func makeError(id: Any?, code: Int, message: String) -> [String: Any] {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message] as [String: Any]
        ]
        if let id = id {
            response["id"] = id
        }
        return response
    }

    private func buildToolList() -> [[String: Any]] {
        return tools.map { (name, tool) in
            let schema = tool.cachedSchema
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

            var entry: [String: Any] = [
                "name": name,
                "description": tool.description,
                "inputSchema": schemaDict
            ]
            if let icon = icon { entry["icons"] = [["uri": icon]] }
            return entry
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

        let errors = validateInput(args, schema: tool.cachedSchema)
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
            } else if JSONSerialization.isValidJSONObject(result),
                      let data = try? JSONSerialization.data(
                          withJSONObject: result,
                          options: []
                      ),
                      let str = String(data: data, encoding: .utf8) {
                // Collections (dicts/arrays) — encode as JSON
                text = str
            } else {
                // Primitives (Bool, Int, Double, etc.) — JSONSerialization
                // fatalErrors on non-collection top-level values on Linux,
                // so we must stringify these directly.
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

    // MARK: - Pagination

    private struct PaginatedResult {
        let items: [[String: Any]]
        let nextCursor: String?
    }

    private func paginate(_ items: [[String: Any]], cursor: String?, pageSize: Int) -> PaginatedResult {
        guard pageSize > 0 else {
            return PaginatedResult(items: items, nextCursor: nil)
        }

        let offset = cursor.flatMap { decodeCursor($0) } ?? 0
        let end = min(offset + pageSize, items.count)
        let slice = Array(items[offset..<end])
        let hasMore = end < items.count

        return PaginatedResult(
            items: slice,
            nextCursor: hasMore ? encodeCursor(end) : nil
        )
    }

    private func encodeCursor(_ offset: Int) -> String {
        let data = String(offset).data(using: .utf8)!
        return data.base64EncodedString()
    }

    private func decodeCursor(_ cursor: String) -> Int? {
        guard let data = Data(base64Encoded: cursor),
              let str = String(data: data, encoding: .utf8),
              let offset = Int(str), offset >= 0 else {
            return nil
        }
        return offset
    }

    // MARK: - Template matching

    private func matchTemplate(_ template: String, uri: String) -> [String: String]? {
        // Convert {param} placeholders to named regex groups
        var regexPattern = "^"
        var paramNames: [String] = []
        var remaining = template[template.startIndex...]

        while let openRange = remaining.range(of: "{") {
            // Append literal text before the placeholder
            regexPattern += NSRegularExpression.escapedPattern(for: String(remaining[remaining.startIndex..<openRange.lowerBound]))

            let afterOpen = openRange.upperBound
            guard let closeRange = remaining[afterOpen...].range(of: "}") else { break }

            let paramName = String(remaining[afterOpen..<closeRange.lowerBound])
            paramNames.append(paramName)
            regexPattern += "([^/]+)"

            remaining = remaining[closeRange.upperBound...]
        }
        regexPattern += NSRegularExpression.escapedPattern(for: String(remaining))
        regexPattern += "$"

        guard let regex = try? NSRegularExpression(pattern: regexPattern),
              let match = regex.firstMatch(in: uri, range: NSRange(uri.startIndex..., in: uri)),
              match.numberOfRanges == paramNames.count + 1 else {
            return nil
        }

        var result: [String: String] = [:]
        for (i, name) in paramNames.enumerated() {
            if let range = Range(match.range(at: i + 1), in: uri) {
                result[name] = String(uri[range])
            }
        }
        return result
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
