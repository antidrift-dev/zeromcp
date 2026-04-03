import XCTest
@testable import ZeroMcp

final class SchemaTests: XCTestCase {
    func testEmptyInput() {
        let result = toJsonSchema([:])
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

    func testExtendedFieldOptional() {
        let result = toJsonSchema([
            "name": .extended(type: .string, description: "User name"),
            "email": .extended(type: .string, optional: true)
        ])
        XCTAssertTrue(result.required.contains("name"))
        XCTAssertFalse(result.required.contains("email"))
        XCTAssertEqual(result.properties["name"]?.description, "User name")
    }

    func testValidateMissingRequired() {
        let schema = toJsonSchema(["name": .simple(.string)])
        let errors = validateInput([:], schema: schema)
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors[0].contains("Missing required field"))
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
}
