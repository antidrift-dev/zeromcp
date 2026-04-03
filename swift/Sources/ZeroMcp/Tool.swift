import Foundation

public struct Permissions {
    public var network: NetworkPermission
    public var fs: FSPermission
    public var exec: Bool

    public init(
        network: NetworkPermission = .full,
        fs: FSPermission = .none,
        exec: Bool = false
    ) {
        self.network = network
        self.fs = fs
        self.exec = exec
    }

    public enum NetworkPermission {
        case full
        case none
        case allowlist([String])
    }

    public enum FSPermission {
        case none
        case read
        case write
    }
}

public struct ToolContext {
    public let toolName: String
    public let credentials: Any?

    public init(toolName: String, credentials: Any? = nil) {
        self.toolName = toolName
        self.credentials = credentials
    }
}

public struct ToolDefinition {
    public let description: String
    public let input: InputSchema
    public let permissions: Permissions
    public let execute: ([String: Any], ToolContext) async throws -> Any

    public init(
        description: String,
        input: InputSchema = [:],
        permissions: Permissions = Permissions(),
        execute: @escaping ([String: Any], ToolContext) async throws -> Any
    ) {
        self.description = description
        self.input = input
        self.permissions = permissions
        self.execute = execute
    }
}

// Convenience initializer matching the DSL style
public struct ToolBuilder {
    public let description: String
    public let input: InputSchema

    public init(description: String, input: InputSchema = [:]) {
        self.description = description
        self.input = input
    }
}
