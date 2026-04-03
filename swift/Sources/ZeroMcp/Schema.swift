import Foundation

public enum SimpleType: String, Codable {
    case string
    case number
    case boolean
    case object
    case array
}

public enum InputField {
    case simple(SimpleType)
    case extended(type: SimpleType, description: String? = nil, optional: Bool = false)
}

public typealias InputSchema = [String: InputField]

public struct JsonSchema: Codable {
    public let type: String
    public let properties: [String: JsonSchemaProperty]
    public let required: [String]

    public init(properties: [String: JsonSchemaProperty] = [:], required: [String] = []) {
        self.type = "object"
        self.properties = properties
        self.required = required
    }
}

public struct JsonSchemaProperty: Codable {
    public let type: String
    public let description: String?

    public init(type: String, description: String? = nil) {
        self.type = type
        self.description = description
    }
}

public func toJsonSchema(_ input: InputSchema?) -> JsonSchema {
    guard let input = input, !input.isEmpty else {
        return JsonSchema()
    }

    var properties: [String: JsonSchemaProperty] = [:]
    var required: [String] = []

    for (key, field) in input {
        switch field {
        case .simple(let simpleType):
            properties[key] = JsonSchemaProperty(type: simpleType.rawValue)
            required.append(key)
        case .extended(let simpleType, let description, let optional):
            properties[key] = JsonSchemaProperty(type: simpleType.rawValue, description: description)
            if !optional {
                required.append(key)
            }
        }
    }

    return JsonSchema(properties: properties, required: required.sorted())
}

public func validateInput(_ input: [String: Any], schema: JsonSchema) -> [String] {
    var errors: [String] = []

    for key in schema.required {
        if input[key] == nil {
            errors.append("Missing required field: \(key)")
        }
    }

    for (key, value) in input {
        guard let prop = schema.properties[key] else { continue }
        let actual = jsonType(of: value)
        if actual != prop.type {
            errors.append("Field \"\(key)\" expected \(prop.type), got \(actual)")
        }
    }

    return errors
}

private func jsonType(of value: Any) -> String {
    // NSNumber from JSONSerialization: 0/1 match Bool AND Int/Double.
    // Use objCType to distinguish boolean from number.
    if let nsNum = value as? NSNumber {
        let objcType = String(cString: nsNum.objCType)
        if objcType == "c" || objcType == "B" {
            return "boolean"
        }
        return "number"
    }
    switch value {
    case is String:
        return "string"
    case is [Any]:
        return "array"
    case is [String: Any]:
        return "object"
    default:
        return "string"
    }
}
