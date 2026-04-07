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
    name: "status",
    uri: "resource:///status",
    description: "Current server status",
    mimeType: "text/plain",
    readFunc: async () => "OK"
);

server.Resource(
    name: "config",
    uri: "resource:///config",
    description: "Server configuration as JSON",
    mimeType: "application/json",
    readFunc: async () => """{"debug":false,"version":"0.2.0"}"""
);

server.Resource(
    name: "readme",
    uri: "resource:///readme",
    description: "Project readme content",
    mimeType: "text/plain",
    readFunc: async () => "ZeroMcp Resource Test — a v0.2.0 conformance example."
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
