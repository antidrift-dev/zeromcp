using ZeroMcp;

var server = new ZeroMcpServer();

server.Tool("hello", new ToolDefinition
{
    Description = "Say hello to someone",
    Input = new Dictionary<string, InputField>
    {
        ["name"] = new InputField(SimpleType.String)
    },
    Execute = async (args, ctx) =>
    {
        var name = args["name"].GetString() ?? "world";
        return $"Hello, {name}!";
    }
});

server.Tool("add", new ToolDefinition
{
    Description = "Add two numbers together",
    Input = new Dictionary<string, InputField>
    {
        ["a"] = new InputField(SimpleType.Number),
        ["b"] = new InputField(SimpleType.Number)
    },
    Execute = async (args, ctx) =>
    {
        var a = args["a"].GetDouble();
        var b = args["b"].GetDouble();
        return new { sum = a + b };
    }
});

await server.Serve();
