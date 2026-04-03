use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// Simplified input schema builder.
///
/// Fields are either required or optional. Each has a name, a type string
/// (`"string"`, `"number"`, `"boolean"`, `"object"`, `"array"`), and an
/// optional description.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Input {
    fields: Vec<Field>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Field {
    name: String,
    type_name: String,
    description: Option<String>,
    optional: bool,
}

/// The JSON Schema representation we emit for MCP.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct JsonSchema {
    #[serde(rename = "type")]
    pub schema_type: String,
    pub properties: BTreeMap<String, PropertySchema>,
    pub required: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PropertySchema {
    #[serde(rename = "type")]
    pub prop_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
}

impl Input {
    pub fn new() -> Self {
        Self { fields: Vec::new() }
    }

    /// Add a required field.
    pub fn required(mut self, name: &str, type_name: &str) -> Self {
        self.fields.push(Field {
            name: name.to_string(),
            type_name: type_name.to_string(),
            description: None,
            optional: false,
        });
        self
    }

    /// Add a required field with a description.
    pub fn required_desc(mut self, name: &str, type_name: &str, desc: &str) -> Self {
        self.fields.push(Field {
            name: name.to_string(),
            type_name: type_name.to_string(),
            description: Some(desc.to_string()),
            optional: false,
        });
        self
    }

    /// Add an optional field.
    pub fn optional(mut self, name: &str, type_name: &str) -> Self {
        self.fields.push(Field {
            name: name.to_string(),
            type_name: type_name.to_string(),
            description: None,
            optional: true,
        });
        self
    }

    /// Add an optional field with a description.
    pub fn optional_desc(mut self, name: &str, type_name: &str, desc: &str) -> Self {
        self.fields.push(Field {
            name: name.to_string(),
            type_name: type_name.to_string(),
            description: Some(desc.to_string()),
            optional: true,
        });
        self
    }

    /// Convert to JSON Schema.
    pub fn to_json_schema(&self) -> JsonSchema {
        let mut properties = BTreeMap::new();
        let mut required = Vec::new();

        for field in &self.fields {
            let json_type = match field.type_name.as_str() {
                "string" => "string",
                "number" => "number",
                "boolean" => "boolean",
                "object" => "object",
                "array" => "array",
                other => panic!("Unknown type: {other}"),
            };
            properties.insert(
                field.name.clone(),
                PropertySchema {
                    prop_type: json_type.to_string(),
                    description: field.description.clone(),
                },
            );
            if !field.optional {
                required.push(field.name.clone());
            }
        }

        JsonSchema {
            schema_type: "object".to_string(),
            properties,
            required,
        }
    }
}

/// Validate input arguments against a schema. Returns a list of error strings.
pub fn validate(input: &Value, schema: &JsonSchema) -> Vec<String> {
    let mut errors = Vec::new();

    let obj = match input.as_object() {
        Some(o) => o,
        None => {
            errors.push("Input must be an object".to_string());
            return errors;
        }
    };

    // Check required fields
    for key in &schema.required {
        match obj.get(key) {
            None | Some(Value::Null) => {
                errors.push(format!("Missing required field: {key}"));
            }
            _ => {}
        }
    }

    // Type-check provided fields
    for (key, value) in obj {
        if let Some(prop) = schema.properties.get(key) {
            let actual = match value {
                Value::String(_) => "string",
                Value::Number(_) => "number",
                Value::Bool(_) => "boolean",
                Value::Object(_) => "object",
                Value::Array(_) => "array",
                Value::Null => "null",
            };
            if actual != prop.prop_type {
                errors.push(format!(
                    "Field \"{key}\" expected {}, got {actual}",
                    prop.prop_type
                ));
            }
        }
    }

    errors
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn empty_input_produces_empty_schema() {
        let input = Input::new();
        let schema = input.to_json_schema();
        assert!(schema.properties.is_empty());
        assert!(schema.required.is_empty());
        assert_eq!(schema.schema_type, "object");
    }

    #[test]
    fn required_fields_appear_in_required_list() {
        let input = Input::new()
            .required("name", "string")
            .required("age", "number");
        let schema = input.to_json_schema();
        assert_eq!(schema.required, vec!["name", "age"]);
        assert_eq!(schema.properties.len(), 2);
        assert_eq!(schema.properties["name"].prop_type, "string");
        assert_eq!(schema.properties["age"].prop_type, "number");
    }

    #[test]
    fn optional_fields_not_in_required() {
        let input = Input::new()
            .required("name", "string")
            .optional("greeting", "string");
        let schema = input.to_json_schema();
        assert_eq!(schema.required, vec!["name"]);
        assert_eq!(schema.properties.len(), 2);
    }

    #[test]
    fn descriptions_are_preserved() {
        let input = Input::new().required_desc("name", "string", "The user's name");
        let schema = input.to_json_schema();
        assert_eq!(
            schema.properties["name"].description.as_deref(),
            Some("The user's name")
        );
    }

    #[test]
    fn validate_catches_missing_required() {
        let input = Input::new().required("name", "string");
        let schema = input.to_json_schema();
        let errors = validate(&json!({}), &schema);
        assert_eq!(errors.len(), 1);
        assert!(errors[0].contains("Missing required field: name"));
    }

    #[test]
    fn validate_catches_wrong_type() {
        let input = Input::new().required("count", "number");
        let schema = input.to_json_schema();
        let errors = validate(&json!({"count": "not a number"}), &schema);
        assert_eq!(errors.len(), 1);
        assert!(errors[0].contains("expected number, got string"));
    }

    #[test]
    fn validate_passes_correct_input() {
        let input = Input::new()
            .required("name", "string")
            .optional("age", "number");
        let schema = input.to_json_schema();
        let errors = validate(&json!({"name": "Alice", "age": 30}), &schema);
        assert!(errors.is_empty());
    }

    #[test]
    fn validate_passes_with_missing_optional() {
        let input = Input::new()
            .required("name", "string")
            .optional("age", "number");
        let schema = input.to_json_schema();
        let errors = validate(&json!({"name": "Alice"}), &schema);
        assert!(errors.is_empty());
    }

    #[test]
    fn all_type_names_produce_correct_json_types() {
        let input = Input::new()
            .required("s", "string")
            .required("n", "number")
            .required("b", "boolean")
            .required("o", "object")
            .required("a", "array");
        let schema = input.to_json_schema();
        assert_eq!(schema.properties["s"].prop_type, "string");
        assert_eq!(schema.properties["n"].prop_type, "number");
        assert_eq!(schema.properties["b"].prop_type, "boolean");
        assert_eq!(schema.properties["o"].prop_type, "object");
        assert_eq!(schema.properties["a"].prop_type, "array");
    }

    #[test]
    #[should_panic(expected = "Unknown type")]
    fn unknown_type_panics() {
        Input::new().required("x", "bigint").to_json_schema();
    }
}
