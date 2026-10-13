import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A remote MCP server (Streamable HTTP, JSON responses) whose tools are
/// federated in as `<name>.<tool>`.
public struct RemoteServer: Codable {
    public var name: String
    public var url: String
    /// Bearer token: `env:VAR` reads that environment variable, anything else is literal.
    public var auth: String?
    /// Upstream tool names to keep. Omit to expose the entire remote surface.
    public var tools: [String]?

    public init(name: String, url: String, auth: String? = nil, tools: [String]? = nil) {
        self.name = name
        self.url = url
        self.auth = auth
        self.tools = tools
    }
}

/// Connects remote MCP servers and wraps their tools. Ported from nodejs/src/remote.ts.
final class RemoteManager {
    /// Returns namespaced `"<server.name>.<toolName>"` → ToolDefinition, in
    /// connection order. Never throws; per-server failures are logged and skipped.
    func connect(_ servers: [RemoteServer]) async -> [(name: String, tool: ToolDefinition)] {
        var all: [(name: String, tool: ToolDefinition)] = []
        for server in servers {
            do {
                let tools = try await connectOne(server)
                for (toolName, tool) in tools {
                    let namespaced = "\(server.name).\(toolName)"
                    all.append((namespaced, tool))
                    logStderr("[mcp] Remote tool: \(namespaced)\n")
                }
            } catch {
                logStderr("[mcp] Failed to connect to \(server.name): \(error.localizedDescription)\n")
            }
        }
        return all
    }

    private func connectOne(_ server: RemoteServer) async throws -> [(String, ToolDefinition)] {
        if !server.url.hasPrefix("http://") && !server.url.hasPrefix("https://") {
            throw remoteError("Remote server \"\(server.name)\" must have an HTTP/HTTPS URL, got: \(server.url)")
        }
        return try await connectHttp(server)
    }

    private func connectHttp(_ server: RemoteServer) async throws -> [(String, ToolDefinition)] {
        let auth = resolveAuth(server.auth)
        let url = server.url

        _ = try await httpRpc(url, [
            "jsonrpc": "2.0", "id": 1, "method": "initialize", "params": [:] as [String: Any],
        ], auth: auth)

        let listRes = try await httpRpc(url, [
            "jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": [:] as [String: Any],
        ], auth: auth)

        let remoteTools = ((listRes["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? [])
            .filter { rt in
                guard let allow = server.tools else { return true }
                return allow.contains(rt["name"] as? String ?? "")
            }

        var tools: [(String, ToolDefinition)] = []
        for rt in remoteTools {
            let rtName = rt["name"] as? String ?? ""
            let input = schemaToInput(rt["inputSchema"] as? [String: Any])
            let tool = ToolDefinition(
                description: rt["description"] as? String ?? "",
                input: input
            ) { args, _ in
                // Captures the manager strongly: it owns no tools, so no cycle.
                let callRes = try await self.httpRpc(url, [
                    "jsonrpc": "2.0",
                    "id": Int(Date().timeIntervalSince1970 * 1000),
                    "method": "tools/call",
                    "params": ["name": rtName, "arguments": args] as [String: Any],
                ], auth: auth)
                let result = callRes["result"]
                if let content = (result as? [String: Any])?["content"] as? [[String: Any]],
                   let text = content.first?["text"] as? String, !text.isEmpty {
                    return text
                }
                return result ?? NSNull()
            }
            tools.append((rtName, tool))
        }

        logStderr("[mcp] Connected to \(server.name) (HTTP): \(tools.count) tool(s)\n")
        return tools
    }

    private func httpRpc(_ url: String, _ body: [String: Any], auth: String?) async throws -> [String: Any] {
        guard let target = URL(string: url) else {
            throw remoteError("Invalid URL: \(url)")
        }
        var request = URLRequest(url: target)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let auth = auth, !auth.isEmpty {
            request.setValue("Bearer \(auth)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await httpData(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw remoteError("HTTP \(status)")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw remoteError("Invalid JSON-RPC response")
        }
        return json
    }

    private func remoteError(_ message: String) -> NSError {
        NSError(domain: "ZeroMcp.Remote", code: -1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// Convert a remote tool's JSON Schema back to an InputSchema. A property's
/// `type` defaults to `string`, and types SimpleType can't hold (e.g.
/// `integer`) become `.string`. Not required, or has a description →
/// `.extended`; otherwise `.simple`.
func schemaToInput(_ schema: [String: Any]?) -> InputSchema {
    var input: InputSchema = [:]
    guard let properties = schema?["properties"] as? [String: Any] else { return input }
    let required = schema?["required"] as? [String] ?? []

    for (key, value) in properties {
        let prop = value as? [String: Any] ?? [:]
        let type = SimpleType(rawValue: prop["type"] as? String ?? "string") ?? .string
        let description = prop["description"] as? String
        let isRequired = required.contains(key)

        if (description != nil && !description!.isEmpty) || !isRequired {
            let desc = (description?.isEmpty ?? true) ? nil : description
            input[key] = .extended(type: type, description: desc, optional: !isRequired)
        } else {
            input[key] = .simple(type)
        }
    }
    return input
}
