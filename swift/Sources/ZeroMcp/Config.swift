import Foundation

public struct ZeroMcpConfig: Codable {
    public var tools: String?
    public var separator: String?
    public var logging: Bool?
    public var bypassPermissions: Bool?

    enum CodingKeys: String, CodingKey {
        case tools
        case separator
        case logging
        case bypassPermissions = "bypass_permissions"
    }

    public init(
        tools: String? = nil,
        separator: String? = nil,
        logging: Bool? = nil,
        bypassPermissions: Bool? = nil
    ) {
        self.tools = tools
        self.separator = separator
        self.logging = logging
        self.bypassPermissions = bypassPermissions
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
