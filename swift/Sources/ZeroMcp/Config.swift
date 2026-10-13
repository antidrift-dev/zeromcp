import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One entry of the `transport` config key. Only `type` is decoded; other
/// keys (`port`, `auth`) are ignored. ZeroMCP Swift serves stdio only, so an
/// `http` entry is rejected at startup by `serve()`.
public struct TransportConfig: Codable {
    public var type: String

    public init(type: String) {
        self.type = type
    }
}

public struct ZeroMcpConfig: Codable {
    public var tools: String?
    public var separator: String?
    public var logging: Bool?
    public var bypassPermissions: Bool?
    public var executeTimeout: Double? // seconds, default 30
    public var cacheCredentials: Bool?
    public var title: String?
    /// Remote MCP servers whose tools are federated in as `<name>.<tool>`.
    public var remote: [RemoteServer]?
    /// Page size for cursor-based pagination. 0 or nil means no pagination.
    public var pageSize: Int?
    /// Icon applied to tools/resources/prompts: data URI, http(s) URL or file path.
    public var icon: String?
    /// Transport entries. Decodes a single object or an array, like Node.
    public var transport: [TransportConfig]?

    enum CodingKeys: String, CodingKey {
        case tools
        case separator
        case logging
        case bypassPermissions = "bypass_permissions"
        case executeTimeout = "execute_timeout"
        case cacheCredentials = "cache_credentials"
        case title
        case remote
        case pageSize = "page_size"
        case icon
        case transport
    }

    public init(
        tools: String? = nil,
        separator: String? = nil,
        logging: Bool? = nil,
        bypassPermissions: Bool? = nil,
        executeTimeout: Double? = nil,
        cacheCredentials: Bool? = true,
        title: String? = nil,
        remote: [RemoteServer]? = nil,
        pageSize: Int? = nil,
        icon: String? = nil,
        transport: [TransportConfig]? = nil
    ) {
        self.tools = tools
        self.separator = separator
        self.logging = logging
        self.bypassPermissions = bypassPermissions
        self.executeTimeout = executeTimeout
        self.cacheCredentials = cacheCredentials
        self.title = title
        self.remote = remote
        self.pageSize = pageSize
        self.icon = icon
        self.transport = transport
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tools = try c.decodeIfPresent(String.self, forKey: .tools)
        separator = try c.decodeIfPresent(String.self, forKey: .separator)
        logging = try c.decodeIfPresent(Bool.self, forKey: .logging)
        bypassPermissions = try c.decodeIfPresent(Bool.self, forKey: .bypassPermissions)
        executeTimeout = try c.decodeIfPresent(Double.self, forKey: .executeTimeout)
        cacheCredentials = try c.decodeIfPresent(Bool.self, forKey: .cacheCredentials)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        remote = try c.decodeIfPresent([RemoteServer].self, forKey: .remote)
        pageSize = try c.decodeIfPresent(Int.self, forKey: .pageSize)
        icon = try c.decodeIfPresent(String.self, forKey: .icon)
        if let list = try? c.decodeIfPresent([TransportConfig].self, forKey: .transport) {
            transport = list
        } else if let single = try? c.decodeIfPresent(TransportConfig.self, forKey: .transport) {
            transport = [single]
        } else {
            transport = nil
        }
    }

    public static func load(from path: String? = nil) -> ZeroMcpConfig {
        let configPath = path ?? FileManager.default.currentDirectoryPath + "/zeromcp.config.json"
        guard FileManager.default.fileExists(atPath: configPath),
              let data = FileManager.default.contents(atPath: configPath) else {
            return ZeroMcpConfig()
        }

        do {
            return try JSONDecoder().decode(ZeroMcpConfig.self, from: data)
        } catch {
            return ZeroMcpConfig()
        }
    }
}

/// The error `serve()` prints for a config that asks for the removed `http`
/// transport, or nil when every entry is stdio (or there is no `transport` key).
func transportError(_ config: ZeroMcpConfig) -> String? {
    guard let entries = config.transport else { return nil }
    if entries.contains(where: { $0.type == "http" }) {
        return "[zeromcp] The http transport was removed. Mount createRegistry(_:) (routes, openapi, mcp) in your own HTTP server."
    }
    return nil
}

/// `env:VAR` → that environment variable (warns when unset); anything else is
/// returned as the literal value; nil or empty → nil. Ports config.ts resolveAuth.
func resolveAuth(_ auth: String?) -> String? {
    guard let auth = auth, !auth.isEmpty else { return nil }
    if auth.hasPrefix("env:") {
        let envVar = String(auth.dropFirst(4))
        let value = ProcessInfo.processInfo.environment[envVar]
        if value == nil || value!.isEmpty {
            logStderr("[zeromcp] Warning: environment variable \(envVar) not set\n")
        }
        return value
    }
    return auth
}

private let iconMime: [String: String] = [
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".gif": "image/gif",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
    ".webp": "image/webp",
]

/// Resolve an icon config value to a data URI. Accepts a data URI (passed
/// through), an http(s) URL (fetched) or a file path (read, `~` → HOME).
/// Logs a warning and returns nil on failure. Ports config.ts resolveIcon.
func resolveIcon(_ icon: String?) async -> String? {
    guard let icon = icon, !icon.isEmpty else { return nil }

    if icon.hasPrefix("data:") { return icon }

    if icon.hasPrefix("http://") || icon.hasPrefix("https://") {
        guard let url = URL(string: icon) else {
            logStderr("[zeromcp] Warning: failed to fetch icon \(icon): invalid URL\n")
            return nil
        }
        do {
            let (data, response) = try await httpData(for: URLRequest(url: url))
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                logStderr("[zeromcp] Warning: failed to fetch icon \(icon): \(status)\n")
                return nil
            }
            let contentType = http?.value(forHTTPHeaderField: "Content-Type") ?? "image/png"
            return "data:\(contentType);base64,\(data.base64EncodedString())"
        } catch {
            logStderr("[zeromcp] Warning: failed to fetch icon \(icon): \(error.localizedDescription)\n")
            return nil
        }
    }

    var path = icon
    if path.hasPrefix("~") {
        path = (ProcessInfo.processInfo.environment["HOME"] ?? "") + String(path.dropFirst())
    }
    guard let data = FileManager.default.contents(atPath: path) else {
        logStderr("[zeromcp] Warning: failed to read icon file \(icon): cannot read \(path)\n")
        return nil
    }
    let ext = "." + (path as NSString).pathExtension.lowercased()
    let mime = iconMime[ext] ?? "image/png"
    return "data:\(mime);base64,\(data.base64EncodedString())"
}

/// One HTTP round trip through `URLSession.shared`, bridged with a
/// continuation so it behaves the same on Darwin and swift-corelibs-foundation.
func httpData(for request: URLRequest) async throws -> (Data, URLResponse) {
    try await withCheckedThrowingContinuation { cont in
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                cont.resume(throwing: error)
            } else if let response = response {
                cont.resume(returning: (data ?? Data(), response))
            } else {
                cont.resume(throwing: NSError(
                    domain: "ZeroMcp", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "No response"]
                ))
            }
        }.resume()
    }
}

/// Write to stderr without buffering surprises (shared by every source file).
func logStderr(_ message: String) {
    FileHandle.standardError.write(message.data(using: .utf8)!)
}
