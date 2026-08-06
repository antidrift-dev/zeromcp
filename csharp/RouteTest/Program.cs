using ZeroMcp;

var server = new ZeroMcpServer();

server.Tool("greet", new ToolDefinition
{
    Description = "Greet a person by name",
    Input = new Dictionary<string, InputField>
    {
        ["name"] = new InputField(SimpleType.String)
    },
    Route = new ToolRoute { Method = "GET", Path = "/greet/:name" },
    Execute = async (args, ctx) =>
    {
        var name = args["name"].GetString() ?? "world";
        return $"Hello, {name}!";
    }
});

server.Tool("echo", new ToolDefinition
{
    Description = "Echo a message back",
    Input = new Dictionary<string, InputField>
    {
        ["message"] = new InputField(SimpleType.String)
    },
    Route = new ToolRoute { Method = "POST", Path = "/echo" },
    Execute = async (args, ctx) =>
    {
        var message = args["message"].GetString();
        return new { message, echoed = true };
    }
});

await server.ServeHttp(14259);
