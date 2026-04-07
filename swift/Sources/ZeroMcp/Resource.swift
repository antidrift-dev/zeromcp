import Foundation

public struct ResourceDefinition {
    public let uri: String
    public let name: String
    public let description: String?
    public let mimeType: String
    public let read: () async throws -> String

    public init(
        uri: String,
        name: String,
        description: String? = nil,
        mimeType: String = "text/plain",
        read: @escaping () async throws -> String
    ) {
        self.uri = uri
        self.name = name
        self.description = description
        self.mimeType = mimeType
        self.read = read
    }
}

public struct ResourceTemplateDefinition {
    public let uriTemplate: String
    public let name: String
    public let description: String?
    public let mimeType: String
    public let read: ([String: String]) async throws -> String

    public init(
        uriTemplate: String,
        name: String,
        description: String? = nil,
        mimeType: String = "text/plain",
        read: @escaping ([String: String]) async throws -> String
    ) {
        self.uriTemplate = uriTemplate
        self.name = name
        self.description = description
        self.mimeType = mimeType
        self.read = read
    }
}
