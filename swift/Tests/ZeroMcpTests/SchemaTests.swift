import XCTest
@testable import ZeroMcp

final class SchemaTests: XCTestCase {
    // MARK: - toJsonSchema

    func testEmptyInput() {
        let result = toJsonSchema([:])
        XCTAssertEqual(result.type, "object")
        XCTAssertTrue(result.properties.isEmpty)
        XCTAssertTrue(result.required.isEmpty)
    }

    func testNilInput() {
        let result = toJsonSchema(nil)
        XCTAssertEqual(result.type, "object")
        XCTAssertTrue(result.properties.isEmpty)
        XCTAssertTrue(result.required.isEmpty)
    }

    func testSimpleTypes() {
        let result = toJsonSchema([
            "name": .simple(.string),
            "age": .simple(.number)
        ])
        XCTAssertEqual(result.properties["name"]?.type, "string")
        XCTAssertEqual(result.properties["age"]?.type, "number")
        XCTAssertTrue(result.required.contains("name"))
        XCTAssertTrue(result.required.contains("age"))
    }

    func testAllSimpleTypes() {
        let result = toJsonSchema([
            "s": .simple(.string),
            "n": .simple(.number),
            "b": .simple(.boolean),
            "o": .simple(.object),
            "a": .simple(.array),
        ])
        XCTAssertEqual(result.properties["s"]?.type, "string")
        XCTAssertEqual(result.properties["n"]?.type, "number")
        XCTAssertEqual(result.properties["b"]?.type, "boolean")
        XCTAssertEqual(result.properties["o"]?.type, "object")
        XCTAssertEqual(result.properties["a"]?.type, "array")
        XCTAssertEqual(result.required.count, 5)
    }

    func testSimpleFieldsHaveNoDescription() {
        let result = toJsonSchema(["x": .simple(.string)])
        XCTAssertNil(result.properties["x"]?.description)
    }

    func testExtendedFieldOptional() {
        let result = toJsonSchema([
            "name": .extended(type: .string, description: "User name"),
            "email": .extended(type: .string, optional: true)
        ])
        XCTAssertTrue(result.required.contains("name"))
        XCTAssertFalse(result.required.contains("email"))
        XCTAssertEqual(result.properties["name"]?.description, "User name")
    }

    func testExtendedFieldDefaults() {
        let result = toJsonSchema([
            "field": .extended(type: .number)
        ])
        XCTAssertNil(result.properties["field"]?.description)
        XCTAssertTrue(result.required.contains("field"))
    }

    func testRequiredFieldsSorted() {
        let result = toJsonSchema([
            "z": .simple(.string),
            "a": .simple(.string),
            "m": .simple(.string),
        ])
        XCTAssertEqual(result.required, ["a", "m", "z"])
    }

    func testMixedRequiredAndOptional() {
        let result = toJsonSchema([
            "req1": .simple(.string),
            "opt1": .extended(type: .string, optional: true),
            "req2": .extended(type: .number, description: "Required number"),
            "opt2": .extended(type: .boolean, optional: true),
        ])
        XCTAssertEqual(result.required.count, 2)
        XCTAssertTrue(result.required.contains("req1"))
        XCTAssertTrue(result.required.contains("req2"))
        XCTAssertEqual(result.properties.count, 4)
    }

    // MARK: - validateInput

    func testValidateMissingRequired() {
        let schema = toJsonSchema(["name": .simple(.string)])
        let errors = validateInput([:], schema: schema)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("Missing required field"))
    }

    func testValidateMultipleMissingRequired() {
        let schema = toJsonSchema([
            "name": .simple(.string),
            "age": .simple(.number),
        ])
        let errors = validateInput([:], schema: schema)
        XCTAssertEqual(errors.count, 2)
    }

    func testValidateWrongType() {
        let schema = toJsonSchema(["age": .simple(.number)])
        let errors = validateInput(["age": "not a number"], schema: schema)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("expected number"))
    }

    func testValidatePasses() {
        let schema = toJsonSchema(["name": .simple(.string)])
        let errors = validateInput(["name": "Alice"], schema: schema)
        XCTAssertTrue(errors.isEmpty)
    }

    func testValidateOptionalFieldMissing() {
        let schema = toJsonSchema([
            "name": .simple(.string),
            "bio": .extended(type: .string, optional: true),
        ])
        let errors = validateInput(["name": "Alice"], schema: schema)
        XCTAssertTrue(errors.isEmpty)
    }

    func testValidateOptionalFieldWrongType() {
        let schema = toJsonSchema([
            "bio": .extended(type: .string, optional: true),
        ])
        let errors = validateInput(["bio": 42], schema: schema)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("expected string"))
    }

    func testValidateExtraFieldIgnored() {
        let schema = toJsonSchema(["name": .simple(.string)])
        let errors = validateInput(["name": "Alice", "extra": "ignored"], schema: schema)
        XCTAssertTrue(errors.isEmpty)
    }

    func testValidateEmptySchemaAcceptsAnything() {
        let schema = toJsonSchema([:])
        let errors = validateInput(["anything": 42], schema: schema)
        XCTAssertTrue(errors.isEmpty)
    }

    func testValidateNumberType() {
        let schema = toJsonSchema(["count": .simple(.number)])
        let errors = validateInput(["count": 42], schema: schema)
        XCTAssertTrue(errors.isEmpty)
    }

    func testValidateArrayType() {
        let schema = toJsonSchema(["items": .simple(.array)])
        let errors = validateInput(["items": [1, 2, 3]], schema: schema)
        XCTAssertTrue(errors.isEmpty)
    }

    func testValidateObjectType() {
        let schema = toJsonSchema(["data": .simple(.object)])
        let errors = validateInput(["data": ["key": "value"]], schema: schema)
        XCTAssertTrue(errors.isEmpty)
    }

    // MARK: - JsonSchema Codable

    func testJsonSchemaCodableRoundtrip() throws {
        let schema = toJsonSchema([
            "name": .extended(type: .string, description: "The name"),
            "age": .simple(.number),
        ])
        let data = try JSONEncoder().encode(schema)
        let decoded = try JSONDecoder().decode(JsonSchema.self, from: data)
        XCTAssertEqual(decoded.type, "object")
        XCTAssertEqual(decoded.properties["name"]?.type, "string")
        XCTAssertEqual(decoded.properties["name"]?.description, "The name")
        XCTAssertEqual(decoded.properties["age"]?.type, "number")
        XCTAssertEqual(decoded.required, schema.required)
    }
}
