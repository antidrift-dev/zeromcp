package zeromcp

import (
	"testing"
)

func TestToJsonSchemaSimple(t *testing.T) {
	input := Input{
		"name": "string",
		"age":  "number",
	}

	schema := ToJsonSchema(input)

	if schema.Type != "object" {
		t.Errorf("expected type object, got %s", schema.Type)
	}
	if len(schema.Properties) != 2 {
		t.Errorf("expected 2 properties, got %d", len(schema.Properties))
	}
	if schema.Properties["name"].Type != "string" {
		t.Errorf("expected name type string, got %s", schema.Properties["name"].Type)
	}
	if schema.Properties["age"].Type != "number" {
		t.Errorf("expected age type number, got %s", schema.Properties["age"].Type)
	}
	if len(schema.Required) != 2 {
		t.Errorf("expected 2 required fields, got %d", len(schema.Required))
	}
}

func TestToJsonSchemaExtended(t *testing.T) {
	input := Input{
		"city": InputField{
			Type:        "string",
			Description: "City name",
		},
		"units": InputField{
			Type:     "string",
			Optional: true,
		},
	}

	schema := ToJsonSchema(input)

	if schema.Properties["city"].Description != "City name" {
		t.Errorf("expected description 'City name', got %q", schema.Properties["city"].Description)
	}

	// Only "city" should be required, "units" is optional
	required := make(map[string]bool)
	for _, r := range schema.Required {
		required[r] = true
	}
	if !required["city"] {
		t.Error("expected city to be required")
	}
	if required["units"] {
		t.Error("expected units to be optional")
	}
}

func TestToJsonSchemaNil(t *testing.T) {
	schema := ToJsonSchema(nil)
	if schema.Type != "object" {
		t.Errorf("expected type object, got %s", schema.Type)
	}
	if len(schema.Properties) != 0 {
		t.Errorf("expected 0 properties, got %d", len(schema.Properties))
	}
}

func TestValidateRequired(t *testing.T) {
	schema := ToJsonSchema(Input{"name": "string"})
	errors := Validate(map[string]any{}, schema)

	if len(errors) != 1 {
		t.Fatalf("expected 1 error, got %d", len(errors))
	}
	if errors[0] != "Missing required field: name" {
		t.Errorf("unexpected error: %s", errors[0])
	}
}

func TestValidateTypeMismatch(t *testing.T) {
	schema := ToJsonSchema(Input{"age": "number"})
	errors := Validate(map[string]any{"age": "not a number"}, schema)

	if len(errors) != 1 {
		t.Fatalf("expected 1 error, got %d", len(errors))
	}
}

func TestValidatePass(t *testing.T) {
	schema := ToJsonSchema(Input{"name": "string", "age": "number"})
	errors := Validate(map[string]any{"name": "Alice", "age": float64(30)}, schema)

	if len(errors) != 0 {
		t.Errorf("expected 0 errors, got %d: %v", len(errors), errors)
	}
}
