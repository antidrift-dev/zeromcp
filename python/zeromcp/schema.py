"""Simplified input schema -> JSON Schema conversion and validation."""

from __future__ import annotations

# Simple types that map directly to JSON Schema types
SIMPLE_TYPES = {"string", "number", "boolean", "object", "array"}


def to_json_schema(input_schema: dict | None) -> dict:
    """Convert a simplified input schema to full JSON Schema.

    Accepts:
      - Simple form:   {"name": "string", "age": "number"}
      - Extended form:  {"name": {"type": "string", "description": "...", "optional": True}}
    """
    if not input_schema:
        return {"type": "object", "properties": {}, "required": []}

    properties: dict = {}
    required: list[str] = []

    for key, value in input_schema.items():
        if isinstance(value, str):
            if value not in SIMPLE_TYPES:
                raise ValueError(f'Unknown type "{value}" for field "{key}"')
            properties[key] = {"type": value}
            required.append(key)

        elif isinstance(value, dict):
            type_name = value.get("type", "string")
            if type_name not in SIMPLE_TYPES:
                raise ValueError(f'Unknown type "{type_name}" for field "{key}"')

            prop: dict = {"type": type_name}
            if "description" in value:
                prop["description"] = value["description"]
            properties[key] = prop

            if not value.get("optional", False):
                required.append(key)

    return {"type": "object", "properties": properties, "required": required}


def validate(input_data: dict, schema: dict) -> list[str]:
    """Validate input data against a JSON Schema. Returns list of error strings."""
    errors: list[str] = []

    for key in schema.get("required", []):
        if input_data.get(key) is None:
            errors.append(f"Missing required field: {key}")

    for key, value in input_data.items():
        prop = schema.get("properties", {}).get(key)
        if not prop:
            continue

        expected = prop["type"]
        if isinstance(value, bool):
            actual = "boolean"
        elif isinstance(value, int) or isinstance(value, float):
            actual = "number"
        elif isinstance(value, str):
            actual = "string"
        elif isinstance(value, list):
            actual = "array"
        elif isinstance(value, dict):
            actual = "object"
        else:
            actual = type(value).__name__

        if actual != expected:
            errors.append(f'Field "{key}" expected {expected}, got {actual}')

    return errors
