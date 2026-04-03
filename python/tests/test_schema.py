"""Tests for schema conversion and validation."""

import unittest

from zeromcp.schema import to_json_schema, validate


class TestToJsonSchema(unittest.TestCase):
    def test_converts_simple_string_types(self):
        schema = to_json_schema({"name": "string", "age": "number"})
        self.assertEqual(schema, {
            "type": "object",
            "properties": {
                "name": {"type": "string"},
                "age": {"type": "number"},
            },
            "required": ["name", "age"],
        })

    def test_handles_extended_form_with_optional(self):
        schema = to_json_schema({
            "id": "string",
            "note": {"type": "string", "description": "Optional note", "optional": True},
        })
        self.assertEqual(len(schema["required"]), 1)
        self.assertEqual(schema["required"][0], "id")
        self.assertEqual(schema["properties"]["note"]["description"], "Optional note")

    def test_returns_empty_schema_for_no_input(self):
        schema = to_json_schema({})
        self.assertEqual(schema, {"type": "object", "properties": {}, "required": []})

    def test_returns_empty_schema_for_none(self):
        schema = to_json_schema(None)
        self.assertEqual(schema, {"type": "object", "properties": {}, "required": []})

    def test_unknown_type_raises(self):
        with self.assertRaises(ValueError):
            to_json_schema({"x": "invalid_type"})

    def test_all_simple_types(self):
        schema = to_json_schema({
            "s": "string",
            "n": "number",
            "b": "boolean",
            "o": "object",
            "a": "array",
        })
        self.assertEqual(len(schema["properties"]), 5)
        self.assertEqual(len(schema["required"]), 5)


class TestValidate(unittest.TestCase):
    def test_catches_missing_required_fields(self):
        schema = to_json_schema({"name": "string"})
        errors = validate({}, schema)
        self.assertEqual(len(errors), 1)
        self.assertIn("Missing required field: name", errors[0])

    def test_catches_type_mismatches(self):
        schema = to_json_schema({"amount": "number"})
        errors = validate({"amount": "not a number"}, schema)
        self.assertEqual(len(errors), 1)
        self.assertIn("expected number, got string", errors[0])

    def test_passes_valid_input(self):
        schema = to_json_schema({"name": "string", "count": "number"})
        errors = validate({"name": "test", "count": 42}, schema)
        self.assertEqual(len(errors), 0)

    def test_array_type_detection(self):
        schema = to_json_schema({"items": "array"})
        errors = validate({"items": [1, 2, 3]}, schema)
        self.assertEqual(len(errors), 0)

    def test_boolean_type_detection(self):
        schema = to_json_schema({"flag": "boolean"})
        errors = validate({"flag": True}, schema)
        self.assertEqual(len(errors), 0)

    def test_boolean_not_confused_with_number(self):
        # In Python, bool is subclass of int, so we need to check bool first
        schema = to_json_schema({"flag": "boolean"})
        errors = validate({"flag": True}, schema)
        self.assertEqual(len(errors), 0)
        # And a bool should not pass as a number
        schema2 = to_json_schema({"count": "number"})
        errors2 = validate({"count": True}, schema2)
        self.assertEqual(len(errors2), 1)


if __name__ == "__main__":
    unittest.main()
