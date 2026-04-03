package zeromcp

import "fmt"

// SimpleType is a shorthand type name: "string", "number", "boolean", "object", "array".
type SimpleType = string

// InputField can be a SimpleType string or an ExtendedField for more detail.
type InputField struct {
	Type        SimpleType `json:"type"`
	Description string     `json:"description,omitempty"`
	Optional    bool       `json:"optional,omitempty"`
}

// Input maps field names to their type definitions.
// Use String/Number/Boolean/etc helpers, or InputField structs directly.
type Input map[string]any

// JsonSchema is a JSON Schema object for tool input validation.
type JsonSchema struct {
	Type       string                        `json:"type"`
	Properties map[string]JsonSchemaProperty  `json:"properties"`
	Required   []string                      `json:"required"`
}

// JsonSchemaProperty describes a single property in a JSON Schema.
type JsonSchemaProperty struct {
	Type        string `json:"type"`
	Description string `json:"description,omitempty"`
}

var typeMap = map[string]string{
	"string":  "string",
	"number":  "number",
	"boolean": "boolean",
	"object":  "object",
	"array":   "array",
}

// ToJsonSchema converts a simplified Input definition to a full JSON Schema.
func ToJsonSchema(input Input) JsonSchema {
	schema := JsonSchema{
		Type:       "object",
		Properties: make(map[string]JsonSchemaProperty),
		Required:   []string{},
	}

	if input == nil {
		return schema
	}

	for key, value := range input {
		switch v := value.(type) {
		case string:
			mapped, ok := typeMap[v]
			if !ok {
				panic(fmt.Sprintf("unknown type %q for field %q", v, key))
			}
			schema.Properties[key] = JsonSchemaProperty{Type: mapped}
			schema.Required = append(schema.Required, key)

		case InputField:
			mapped, ok := typeMap[v.Type]
			if !ok {
				panic(fmt.Sprintf("unknown type %q for field %q", v.Type, key))
			}
			prop := JsonSchemaProperty{Type: mapped}
			if v.Description != "" {
				prop.Description = v.Description
			}
			schema.Properties[key] = prop
			if !v.Optional {
				schema.Required = append(schema.Required, key)
			}
		}
	}

	return schema
}

// Validate checks input arguments against a JSON Schema. Returns a list of errors.
func Validate(input map[string]any, schema JsonSchema) []string {
	var errors []string

	for _, key := range schema.Required {
		if input[key] == nil {
			errors = append(errors, fmt.Sprintf("Missing required field: %s", key))
		}
	}

	for key, value := range input {
		prop, ok := schema.Properties[key]
		if !ok {
			continue
		}

		actual := jsonType(value)
		if actual != prop.Type {
			errors = append(errors, fmt.Sprintf("Field %q expected %s, got %s", key, prop.Type, actual))
		}
	}

	return errors
}

func jsonType(v any) string {
	switch v.(type) {
	case string:
		return "string"
	case float64, float32, int, int64, int32:
		return "number"
	case bool:
		return "boolean"
	case []any:
		return "array"
	case map[string]any:
		return "object"
	default:
		return fmt.Sprintf("%T", v)
	}
}
