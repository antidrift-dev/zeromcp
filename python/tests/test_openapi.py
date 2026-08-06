"""Tests for OpenAPI spec generation (_build_openapi)."""

import unittest

from zeromcp.server import _build_openapi


def _make_state(tools, title="ZeroMCP"):
    return {"title": title, "tools": tools}


class TestBuildOpenApiGet(unittest.TestCase):
    def test_get_route_splits_path_and_query_params(self):
        tools = {
            "get_item": {
                "description": "Get an item",
                "route": {"method": "GET", "path": "/items/:id"},
                "_cached_schema": {
                    "type": "object",
                    "properties": {"id": {"type": "string"}, "verbose": {"type": "boolean"}},
                    "required": ["id"],
                },
            },
        }
        spec = _build_openapi(_make_state(tools))
        op = spec["paths"]["/items/{id}"]["get"]
        params_by_name = {p["name"]: p for p in op["parameters"]}
        self.assertEqual(params_by_name["id"]["in"], "path")
        self.assertTrue(params_by_name["id"]["required"])
        self.assertEqual(params_by_name["verbose"]["in"], "query")
        self.assertNotIn("requestBody", op)


class TestBuildOpenApiNonGet(unittest.TestCase):
    def test_put_route_with_path_param_excludes_it_from_body(self):
        tools = {
            "update_item": {
                "description": "Update an item",
                "route": {"method": "PUT", "path": "/items/:id"},
                "_cached_schema": {
                    "type": "object",
                    "properties": {
                        "id": {"type": "string"},
                        "name": {"type": "string"},
                        "note": {"type": "string"},
                    },
                    "required": ["id", "name"],
                },
            },
        }
        spec = _build_openapi(_make_state(tools))
        op = spec["paths"]["/items/{id}"]["put"]

        # Path param is documented as a parameter, not a body property.
        self.assertIn("parameters", op)
        self.assertEqual(len(op["parameters"]), 1)
        param = op["parameters"][0]
        self.assertEqual(param["name"], "id")
        self.assertEqual(param["in"], "path")
        self.assertTrue(param["required"])
        self.assertEqual(param["schema"], {"type": "string"})

        # Body schema excludes the path param entirely.
        body_schema = op["requestBody"]["content"]["application/json"]["schema"]
        self.assertNotIn("id", body_schema["properties"])
        self.assertIn("name", body_schema["properties"])
        self.assertIn("note", body_schema["properties"])
        self.assertNotIn("id", body_schema["required"])
        self.assertIn("name", body_schema["required"])
        self.assertTrue(op["requestBody"]["required"])

    def test_post_route_without_path_param_has_no_parameters_key(self):
        tools = {
            "create_item": {
                "description": "Create an item",
                "route": {"method": "POST", "path": "/items"},
                "_cached_schema": {
                    "type": "object",
                    "properties": {"name": {"type": "string"}},
                    "required": ["name"],
                },
            },
        }
        spec = _build_openapi(_make_state(tools))
        op = spec["paths"]["/items"]["post"]
        self.assertNotIn("parameters", op)
        body_schema = op["requestBody"]["content"]["application/json"]["schema"]
        self.assertEqual(body_schema["properties"], {"name": {"type": "string"}})
        self.assertEqual(body_schema["required"], ["name"])

    def test_post_route_with_no_body_fields_omits_required_key(self):
        tools = {
            "delete_item": {
                "description": "Delete an item",
                "route": {"method": "DELETE", "path": "/items/:id"},
                "_cached_schema": {
                    "type": "object",
                    "properties": {"id": {"type": "string"}},
                    "required": ["id"],
                },
            },
        }
        spec = _build_openapi(_make_state(tools))
        op = spec["paths"]["/items/{id}"]["delete"]
        body_schema = op["requestBody"]["content"]["application/json"]["schema"]
        self.assertEqual(body_schema["properties"], {})
        self.assertNotIn("required", body_schema)


if __name__ == "__main__":
    unittest.main()
