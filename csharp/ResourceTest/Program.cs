using ZeroMcp;

var server = new ZeroMcpServer();

// --- Tool: hello ---

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

// --- Resources ---

server.Resource(
    name: "data.json",
    uri: "resource:///data.json",
    description: "Static JSON data",
    mimeType: "application/json",
    readFunc: async () => """{"key":"value"}"""
);

server.Resource(
    name: "dynamic",
    uri: "resource:///dynamic",
    description: "A dynamic resource",
    mimeType: "text/plain",
    readFunc: async () => "This is dynamic content"
);

// --- Prompt: greet ---

server.Prompt(
    name: "greet",
    description: "Generate a greeting message for a user",
    arguments: new List<PromptArgument>
    {
        new() { Name = "name", Description = "Name of the person to greet", Required = true },
        new() { Name = "style", Description = "Greeting style (formal or casual)", Required = false }
    },
    renderFunc: async (args) =>
    {
        var name = args.GetValueOrDefault("name", "friend");
        var style = args.GetValueOrDefault("style", "casual");

        var text = style == "formal"
            ? $"Dear {name}, it is a pleasure to make your acquaintance."
            : $"Hey {name}, welcome aboard!";

        return new List<Dictionary<string, object>>
        {
            new()
            {
                ["role"] = "user",
                ["content"] = new Dictionary<string, string>
                {
                    ["type"] = "text",
                    ["text"] = text
                }
            }
        };
    }
);

await server.Serve();
