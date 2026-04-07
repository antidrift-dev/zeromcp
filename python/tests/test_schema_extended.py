"""Extended tests for schema conversion and validation."""

import unittest

from zeromcp.schema import SIMPLE_TYPES, to_json_schema, validate


class TestToJsonSchemaEdgeCases(unittest.TestCase):
    """Edge cases for to_json_schema conversion."""

    def test_extended_form_required_by_default(self):
        schema = to_json_schema({"name": {"type": "string", "description": "Full name"}})
        self.assertIn("name", schema["required"])
        self.assertEqual(schema["properties"]["name"]["description"], "Full name")

    def test_extended_form_optional_true(self):
        schema = to_json_schema({"tag": {"type": "string", "optional": True}})
        self.assertNotIn("tag", schema["required"])

    def test_extended_form_optional_false(self):
        schema = to_json_schema({"tag": {"type": "string", "optional": False}})
        self.assertIn("tag", schema["required"])

    def test_extended_form_defaults_to_string_type(self):
        schema = to_json_schema({"name": {"description": "A name"}})
        self.assertEqual(schema["properties"]["name"]["type"], "string")

    def test_unknown_type_in_extended_form_raises(self):
        with self.assertRaises(ValueError) as ctx:
            to_json_schema({"x": {"type": "uuid"}})
        self.assertIn("uuid", str(ctx.exception))

    def test_mixed_simple_and_extended(self):
        schema = to_json_schema({
            "id": "number",
            "name": {"type": "string", "description": "Full name"},
            "active": {"type": "boolean", "optional": True},
        })
        self.assertEqual(sorted(schema["required"]), ["id", "name"])
        self.assertEqual(len(schema["properties"]), 3)

    def test_all_simple_type_strings(self):
        for t in SIMPLE_TYPES:
            schema = to_json_schema({"field": t})
            self.assertEqual(schema["properties"]["field"]["type"], t)
            self.assertIn("field", schema["required"])

    def test_single_field(self):
        schema = to_json_schema({"x": "string"})
        self.assertEqual(schema["properties"], {"x": {"type": "string"}})
        self.assertEqual(schema["required"], ["x"])

    def test_description_not_added_when_absent(self):
        schema = to_json_schema({"x": {"type": "string"}})
        self.assertNotIn("description", schema["properties"]["x"])


class TestValidateEdgeCases(unittest.TestCase):
    """Edge cases for validation."""

    def test_extra_fields_ignored(self):
        schema = to_json_schema({"name": "string"})
        errors = validate({"name": "ok", "extra": 123}, schema)
        self.assertEqual(errors, [])

    def test_multiple_required_missing(self):
        schema = to_json_schema({"a": "string", "b": "number"})
        errors = validate({}, schema)
        self.assertEqual(len(errors), 2)

    def test_optional_field_absent_no_error(self):
        schema = to_json_schema({"opt": {"type": "string", "optional": True}})
        errors = validate({}, schema)
        self.assertEqual(errors, [])

    def test_optional_field_wrong_type(self):
        schema = to_json_schema({"opt": {"type": "number", "optional": True}})
        errors = validate({"opt": "text"}, schema)
        self.assertEqual(len(errors), 1)

    def test_object_type_valid(self):
        schema = to_json_schema({"data": "object"})
        errors = validate({"data": {"key": "val"}}, schema)
        self.assertEqual(errors, [])

    def test_object_type_invalid(self):
        schema = to_json_schema({"data": "object"})
        errors = validate({"data": "not an object"}, schema)
        self.assertEqual(len(errors), 1)

    def test_float_passes_number(self):
        schema = to_json_schema({"val": "number"})
        errors = validate({"val": 3.14}, schema)
        self.assertEqual(errors, [])

    def test_int_passes_number(self):
        schema = to_json_schema({"val": "number"})
        errors = validate({"val": 42}, schema)
        self.assertEqual(errors, [])

    def test_empty_object_no_required(self):
        schema = to_json_schema({})
        errors = validate({"anything": "goes"}, schema)
        self.assertEqual(errors, [])

    def test_required_field_none_value(self):
        schema = to_json_schema({"name": "string"})
        errors = validate({"name": None}, schema)
        self.assertGreater(len(errors), 0)

    def test_mixed_valid_and_invalid(self):
        schema = to_json_schema({"a": "string", "b": "number"})
        errors = validate({"a": "ok", "b": "not a number"}, schema)
        self.assertEqual(len(errors), 1)
        self.assertIn("b", errors[0])


if __name__ == "__main__":
    unittest.main()
