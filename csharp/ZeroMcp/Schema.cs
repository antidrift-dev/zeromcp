using System.Text.Json;
using System.Text.Json.Serialization;

namespace ZeroMcp;

public enum SimpleType
{
    String,
    Number,
    Boolean,
    Object,
    Array
}

public class InputField
{
    public SimpleType Type { get; set; }
    public string? Description { get; set; }
    public bool Optional { get; set; }

    public InputField(SimpleType type)
    {
        Type = type;
    }

    public InputField(SimpleType type, string? description = null, bool optional = false)
    {
        Type = type;
        Description = description;
        Optional = optional;
    }

    // Implicit conversion from string for convenience
    public static implicit operator InputField(string typeName) =>
        new(Enum.Parse<SimpleType>(typeName, ignoreCase: true));
}

public class JsonSchemaProperty
{
    [JsonPropertyName("type")]
    public string Type { get; set; } = "string";

    [JsonPropertyName("description")]
    [JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingNull)]
    public string? Description { get; set; }
}

public class JsonSchema
{
    [JsonPropertyName("type")]
    public string Type { get; set; } = "object";

    [JsonPropertyName("properties")]
    public Dictionary<string, JsonSchemaProperty> Properties { get; set; } = new();

    [JsonPropertyName("required")]
    public List<string> Required { get; set; } = new();
}

public static class Schema
{
    private static readonly Dictionary<SimpleType, string> TypeMap = new()
    {
        [SimpleType.String] = "string",
        [SimpleType.Number] = "number",
        [SimpleType.Boolean] = "boolean",
        [SimpleType.Object] = "object",
        [SimpleType.Array] = "array",
    };

    public static JsonSchema ToJsonSchema(Dictionary<string, InputField>? input)
    {
        var schema = new JsonSchema();
        if (input == null || input.Count == 0) return schema;

        foreach (var (key, field) in input)
        {
            var typeName = TypeMap[field.Type];
            schema.Properties[key] = new JsonSchemaProperty
            {
                Type = typeName,
                Description = field.Description
            };

            if (!field.Optional)
            {
                schema.Required.Add(key);
            }
        }

        schema.Required.Sort();
        return schema;
    }

    public static List<string> Validate(
        Dictionary<string, JsonElement> input,
        JsonSchema schema)
    {
        var errors = new List<string>();

        foreach (var key in schema.Required)
        {
            if (!input.ContainsKey(key))
            {
                errors.Add($"Missing required field: {key}");
            }
        }

        foreach (var (key, value) in input)
        {
            if (!schema.Properties.TryGetValue(key, out var prop)) continue;

            var actual = GetJsonType(value);
            if (actual != prop.Type)
            {
                errors.Add($"Field \"{key}\" expected {prop.Type}, got {actual}");
            }
        }

        return errors;
    }

    private static string GetJsonType(JsonElement value) => value.ValueKind switch
    {
        JsonValueKind.String => "string",
        JsonValueKind.Number => "number",
        JsonValueKind.True or JsonValueKind.False => "boolean",
        JsonValueKind.Array => "array",
        JsonValueKind.Object => "object",
        _ => "string"
    };
}
