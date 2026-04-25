import Foundation

public struct ZeroMcpConfig: Codable {
    public var tools: String?
    public var separator: String?
    public var logging: Bool?
    public var bypassPermissions: Bool?
    public var executeTimeout: Double? // seconds, default 30
    public var cacheCredentials: Bool?

    enum CodingKeys: String, CodingKey {
        case tools
        case separator
        case logging
        case bypassPermissions = "bypass_permissions"
        case executeTimeout = "execute_timeout"
        case cacheCredentials = "cache_credentials"
    }

    public init(
        tools: String? = nil,
        separator: String? = nil,
        logging: Bool? = nil,
        bypassPermissions: Bool? = nil,
        executeTimeout: Double? = nil,
        cacheCredentials: Bool? = true
    ) {
        self.tools = tools
        self.separator = separator
        self.logging = logging
        self.bypassPermissions = bypassPermissions
        self.executeTimeout = executeTimeout
        self.cacheCredentials = cacheCredentials
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
