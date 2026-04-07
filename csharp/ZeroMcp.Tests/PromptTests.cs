using System.Text.Json;
using Xunit;
using ZeroMcp;

namespace ZeroMcp.Tests;

public class PromptTests
{
    private static JsonDocument MakeRequest(string method, object? paramsObj = null)
    {
        var wrapper = new Dictionary<string, object?>
        {
            ["jsonrpc"] = "2.0",
            ["id"] = 1,
            ["method"] = method
        };
        if (paramsObj != null) wrapper["params"] = paramsObj;
        return JsonDocument.Parse(JsonSerializer.Serialize(wrapper));
    }

    [Fact]
    public async Task PromptRegistration_AppearsInList()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());
        server.Prompt("greet", description: "Greeting prompt",
            arguments: new List<PromptArgument>
            {
                new() { Name = "name", Description = "User name", Required = true },
                new() { Name = "style", Description = "Greeting style", Required = false }
            },
            renderFunc: args => Task.FromResult(new List<Dictionary<string, object>>
            {
                new() { ["role"] = "user", ["content"] = new Dictionary<string, string> { ["type"] = "text", ["text"] = $"Hello {args["name"]}" } }
            }));

        var resp = await server.HandleRequest(MakeRequest("prompts/list"));
        Assert.NotNull(resp);
        var result = (Dictionary<string, object>)resp!["result"]!;
        var prompts = (List<Dictionary<string, object>>)result["prompts"];
        Assert.Single(prompts);
        Assert.Equal("greet", prompts[0]["name"]);
        Assert.Equal("Greeting prompt", prompts[0]["description"]);

        var arguments = (List<Dictionary<string, object>>)prompts[0]["arguments"];
        Assert.Equal(2, arguments.Count);
        Assert.Equal("name", arguments[0]["name"]);
        Assert.Equal(true, arguments[0]["required"]);
        Assert.Equal("style", arguments[1]["name"]);
        Assert.Equal(false, arguments[1]["required"]);
    }

    [Fact]
    public async Task PromptsGet_ReturnsRenderedMessages()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());
        server.Prompt("greet",
            renderFunc: args => Task.FromResult(new List<Dictionary<string, object>>
            {
                new()
                {
                    ["role"] = "user",
                    ["content"] = new Dictionary<string, string>
                    {
                        ["type"] = "text",
                        ["text"] = $"Hello {args["name"]}!"
                    }
                }
            }));

        var resp = await server.HandleRequest(MakeRequest("prompts/get",
            new Dictionary<string, object>
            {
                ["name"] = "greet",
                ["arguments"] = new Dictionary<string, object> { ["name"] = "Alice" }
            }));

        Assert.NotNull(resp);
        var result = (Dictionary<string, object>)resp!["result"]!;
        var messages = (List<Dictionary<string, object>>)result["messages"];
        Assert.Single(messages);
        Assert.Equal("user", messages[0]["role"]);
    }

    [Fact]
    public async Task PromptsGet_NotFound_ReturnsError()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());

        var resp = await server.HandleRequest(MakeRequest("prompts/get",
            new Dictionary<string, object> { ["name"] = "nonexistent" }));

        Assert.NotNull(resp);
        Assert.True(resp!.ContainsKey("error"));
        var error = (Dictionary<string, object>)resp["error"]!;
        Assert.Equal(-32002, error["code"]);
        Assert.Contains("nonexistent", (string)error["message"]);
    }

    [Fact]
    public async Task PromptsGet_RenderThrows_ReturnsError()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());
        server.Prompt("broken",
            renderFunc: _ => throw new Exception("render failed"));

        var resp = await server.HandleRequest(MakeRequest("prompts/get",
            new Dictionary<string, object> { ["name"] = "broken" }));

        Assert.NotNull(resp);
        Assert.True(resp!.ContainsKey("error"));
        var error = (Dictionary<string, object>)resp["error"]!;
        Assert.Equal(-32603, error["code"]);
        Assert.Contains("render failed", (string)error["message"]);
    }

    [Fact]
    public async Task PromptWithNoArguments_ListsCleanly()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());
        server.Prompt("simple", description: "No args prompt",
            renderFunc: _ => Task.FromResult(new List<Dictionary<string, object>>()));

        var resp = await server.HandleRequest(MakeRequest("prompts/list"));
        var result = (Dictionary<string, object>)resp!["result"]!;
        var prompts = (List<Dictionary<string, object>>)result["prompts"];
        Assert.Single(prompts);
        Assert.False(prompts[0].ContainsKey("arguments"));
    }

    [Fact]
    public async Task MultiplePrompts_AllListed()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());
        server.Prompt("p1", renderFunc: _ => Task.FromResult(new List<Dictionary<string, object>>()));
        server.Prompt("p2", renderFunc: _ => Task.FromResult(new List<Dictionary<string, object>>()));
        server.Prompt("p3", renderFunc: _ => Task.FromResult(new List<Dictionary<string, object>>()));

        var resp = await server.HandleRequest(MakeRequest("prompts/list"));
        var result = (Dictionary<string, object>)resp!["result"]!;
        var prompts = (List<Dictionary<string, object>>)result["prompts"];
        Assert.Equal(3, prompts.Count);
    }
}
