import Foundation

public struct Permissions {
    public var network: NetworkPermission
    public var fs: FSPermission
    public var exec: Bool
    public var executeTimeout: Double? // seconds, overrides config default

    public init(
        network: NetworkPermission = .full,
        fs: FSPermission = .none,
        exec: Bool = false,
        executeTimeout: Double? = nil
    ) {
        self.network = network
        self.fs = fs
        self.exec = exec
        self.executeTimeout = executeTimeout
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
    public let permissions: Permissions
    /// Value returned by `getRuntime` (on `ZeroMcp` or `RegistryOptions`) for
    /// this execution, or nil when no hook is set. Remote tools never get it.
    public let runtime: Any?

    public init(
        toolName: String,
        credentials: Any? = nil,
        permissions: Permissions = Permissions(),
        runtime: Any? = nil
    ) {
        self.toolName = toolName
        self.credentials = credentials
        self.permissions = permissions
        self.runtime = runtime
    }
}

public struct RouteDefinition {
    public let method: String
    public let path: String

    public init(method: String, path: String) {
        self.method = method.uppercased()
        self.path = path
    }
}

public struct ToolDefinition {
    public let description: String
    public let input: InputSchema
    public let cachedSchema: JsonSchema
    public let permissions: Permissions
    public let route: RouteDefinition?
    public let execute: ([String: Any], ToolContext) async throws -> Any

    public init(
        description: String,
        input: InputSchema = [:],
        permissions: Permissions = Permissions(),
        route: RouteDefinition? = nil,
        execute: @escaping ([String: Any], ToolContext) async throws -> Any
    ) {
        self.description = description
        self.input = input
        self.cachedSchema = toJsonSchema(input)
        self.permissions = permissions
        self.route = route
        self.execute = execute
    }
}

// Convenience initializer matching the DSL style
public struct ToolBuilder {
    public let description: String
    public let input: InputSchema
    public let route: RouteDefinition?

    public init(description: String, input: InputSchema = [:], route: RouteDefinition? = nil) {
        self.description = description
        self.input = input
        self.route = route
    }
}
