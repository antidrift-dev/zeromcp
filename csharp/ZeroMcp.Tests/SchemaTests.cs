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

    [Fact]
    public void NullInput_ReturnsEmptySchema()
    {
        var result = Schema.ToJsonSchema(null);
        Assert.Equal("object", result.Type);
        Assert.Empty(result.Properties);
        Assert.Empty(result.Required);
    }

    [Fact]
    public void AllSimpleTypes_MapCorrectly()
    {
        var result = Schema.ToJsonSchema(new Dictionary<string, InputField>
        {
            ["s"] = new InputField(SimpleType.String),
            ["n"] = new InputField(SimpleType.Number),
            ["b"] = new InputField(SimpleType.Boolean),
            ["o"] = new InputField(SimpleType.Object),
            ["a"] = new InputField(SimpleType.Array)
        });

        Assert.Equal("string", result.Properties["s"].Type);
        Assert.Equal("number", result.Properties["n"].Type);
        Assert.Equal("boolean", result.Properties["b"].Type);
        Assert.Equal("object", result.Properties["o"].Type);
        Assert.Equal("array", result.Properties["a"].Type);
    }

    [Fact]
    public void RequiredFields_AreSorted()
    {
        var result = Schema.ToJsonSchema(new Dictionary<string, InputField>
        {
            ["zebra"] = new InputField(SimpleType.String),
            ["apple"] = new InputField(SimpleType.String),
            ["mango"] = new InputField(SimpleType.String)
        });

        Assert.Equal(new List<string> { "apple", "mango", "zebra" }, result.Required);
    }

    [Fact]
    public void Validate_BooleanType_Passes()
    {
        var schema = Schema.ToJsonSchema(new Dictionary<string, InputField>
        {
            ["flag"] = new InputField(SimpleType.Boolean)
        });

        var doc = JsonDocument.Parse("{\"flag\": true}");
        var input = new Dictionary<string, JsonElement>();
        foreach (var prop in doc.RootElement.EnumerateObject())
            input[prop.Name] = prop.Value.Clone();

        var errors = Schema.Validate(input, schema);
        Assert.Empty(errors);
    }

    [Fact]
    public void Validate_OptionalField_CanBeOmitted()
    {
        var schema = Schema.ToJsonSchema(new Dictionary<string, InputField>
        {
            ["required"] = new InputField(SimpleType.String),
            ["optional"] = new InputField(SimpleType.String, optional: true)
        });

        var doc = JsonDocument.Parse("{\"required\": \"value\"}");
        var input = new Dictionary<string, JsonElement>();
        foreach (var prop in doc.RootElement.EnumerateObject())
            input[prop.Name] = prop.Value.Clone();

        var errors = Schema.Validate(input, schema);
        Assert.Empty(errors);
    }

    [Fact]
    public void Validate_MultipleMissingFields_ReturnsMultipleErrors()
    {
        var schema = Schema.ToJsonSchema(new Dictionary<string, InputField>
        {
            ["a"] = new InputField(SimpleType.String),
            ["b"] = new InputField(SimpleType.Number),
            ["c"] = new InputField(SimpleType.Boolean)
        });

        var errors = Schema.Validate(new Dictionary<string, JsonElement>(), schema);
        Assert.Equal(3, errors.Count);
    }

    [Fact]
    public void Validate_ExtraField_IsIgnored()
    {
        var schema = Schema.ToJsonSchema(new Dictionary<string, InputField>
        {
            ["name"] = new InputField(SimpleType.String)
        });

        var doc = JsonDocument.Parse("{\"name\": \"Alice\", \"extra\": 123}");
        var input = new Dictionary<string, JsonElement>();
        foreach (var prop in doc.RootElement.EnumerateObject())
            input[prop.Name] = prop.Value.Clone();

        var errors = Schema.Validate(input, schema);
        Assert.Empty(errors);
    }

    [Fact]
    public void Validate_ArrayType_Passes()
    {
        var schema = Schema.ToJsonSchema(new Dictionary<string, InputField>
        {
            ["items"] = new InputField(SimpleType.Array)
        });

        var doc = JsonDocument.Parse("{\"items\": [1, 2, 3]}");
        var input = new Dictionary<string, JsonElement>();
        foreach (var prop in doc.RootElement.EnumerateObject())
            input[prop.Name] = prop.Value.Clone();

        var errors = Schema.Validate(input, schema);
        Assert.Empty(errors);
    }

    [Fact]
    public void Validate_ObjectType_Passes()
    {
        var schema = Schema.ToJsonSchema(new Dictionary<string, InputField>
        {
            ["data"] = new InputField(SimpleType.Object)
        });

        var doc = JsonDocument.Parse("{\"data\": {\"key\": \"value\"}}");
        var input = new Dictionary<string, JsonElement>();
        foreach (var prop in doc.RootElement.EnumerateObject())
            input[prop.Name] = prop.Value.Clone();

        var errors = Schema.Validate(input, schema);
        Assert.Empty(errors);
    }

    [Fact]
    public void ImplicitConversion_FromString_Works()
    {
        InputField field = "number";
        Assert.Equal(SimpleType.Number, field.Type);
    }

    [Fact]
    public void ImplicitConversion_CaseInsensitive()
    {
        InputField field = "Boolean";
        Assert.Equal(SimpleType.Boolean, field.Type);
    }
}
