import Foundation

public struct PromptArgument {
    public let name: String
    public let description: String?
    public let required: Bool

    public init(name: String, description: String? = nil, required: Bool = true) {
        self.name = name
        self.description = description
        self.required = required
    }

    func toDict() -> [String: Any] {
        var d: [String: Any] = ["name": name]
        if let desc = description { d["description"] = desc }
        d["required"] = required
        return d
    }
}

public struct PromptDefinition {
    public let name: String
    public let description: String?
    public let arguments: [PromptArgument]?
    public let render: ([String: Any]) async throws -> [[String: Any]]

    public init(
        name: String,
        description: String? = nil,
        arguments: [PromptArgument]? = nil,
        render: @escaping ([String: Any]) async throws -> [[String: Any]]
    ) {
        self.name = name
        self.description = description
        self.arguments = arguments
        self.render = render
    }
}
