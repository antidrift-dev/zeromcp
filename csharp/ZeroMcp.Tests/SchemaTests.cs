using System.Text.Json;
using Xunit;
using ZeroMcp;

namespace ZeroMcp.Tests;

public class SchemaTests
{
    [Fact]
    public void EmptyInput_ReturnsEmptySchema()
    {
        var result = Schema.ToJsonSchema(new Dictionary<string, InputField>());
        Assert.Equal("object", result.Type);
        Assert.Empty(result.Properties);
        Assert.Empty(result.Required);
    }

    [Fact]
    public void SimpleTypes_MapCorrectly()
    {
        var result = Schema.ToJsonSchema(new Dictionary<string, InputField>
        {
            ["name"] = new InputField(SimpleType.String),
            ["age"] = new InputField(SimpleType.Number)
        });

        Assert.Equal("string", result.Properties["name"].Type);
        Assert.Equal("number", result.Properties["age"].Type);
        Assert.Contains("name", result.Required);
        Assert.Contains("age", result.Required);
    }

    [Fact]
    public void ExtendedField_OptionalExcludedFromRequired()
    {
        var result = Schema.ToJsonSchema(new Dictionary<string, InputField>
        {
            ["name"] = new InputField(SimpleType.String, description: "User name"),
            ["email"] = new InputField(SimpleType.String, optional: true)
        });

        Assert.Contains("name", result.Required);
        Assert.DoesNotContain("email", result.Required);
        Assert.Equal("User name", result.Properties["name"].Description);
    }

    [Fact]
    public void Validate_MissingRequired_ReturnsError()
    {
        var schema = Schema.ToJsonSchema(new Dictionary<string, InputField>
        {
            ["name"] = new InputField(SimpleType.String)
        });

        var errors = Schema.Validate(new Dictionary<string, JsonElement>(), schema);
        Assert.Single(errors);
        Assert.Contains("Missing required field", errors[0]);
    }

    [Fact]
    public void Validate_WrongType_ReturnsError()
    {
        var schema = Schema.ToJsonSchema(new Dictionary<string, InputField>
        {
            ["age"] = new InputField(SimpleType.Number)
        });

        var doc = JsonDocument.Parse("{\"age\": \"not a number\"}");
        var input = new Dictionary<string, JsonElement>();
        foreach (var prop in doc.RootElement.EnumerateObject())
            input[prop.Name] = prop.Value.Clone();

        var errors = Schema.Validate(input, schema);
        Assert.Single(errors);
        Assert.Contains("expected number", errors[0]);
    }

    [Fact]
    public void Validate_CorrectInput_NoErrors()
    {
        var schema = Schema.ToJsonSchema(new Dictionary<string, InputField>
        {
            ["name"] = new InputField(SimpleType.String)
        });

        var doc = JsonDocument.Parse("{\"name\": \"Alice\"}");
        var input = new Dictionary<string, JsonElement>();
        foreach (var prop in doc.RootElement.EnumerateObject())
            input[prop.Name] = prop.Value.Clone();

        var errors = Schema.Validate(input, schema);
        Assert.Empty(errors);
    }
}
