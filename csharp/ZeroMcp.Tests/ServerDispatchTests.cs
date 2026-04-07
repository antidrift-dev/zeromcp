using System.Text.Json;
using Xunit;
using ZeroMcp;

namespace ZeroMcp.Tests;

public class ServerDispatchTests
{
    private static JsonDocument MakeRequest(string method, object? paramsObj = null, object? id = null)
    {
        var wrapper = new Dictionary<string, object?>
        {
            ["jsonrpc"] = "2.0",
            ["method"] = method
        };
        if (id != null) wrapper["id"] = id;
        else wrapper["id"] = 1;
        if (paramsObj != null) wrapper["params"] = paramsObj;
        return JsonDocument.Parse(JsonSerializer.Serialize(wrapper));
    }

    private static JsonDocument MakeNotification(string method, object? paramsObj = null)
    {
        var wrapper = new Dictionary<string, object?>
        {
            ["jsonrpc"] = "2.0",
            ["method"] = method
        };
        if (paramsObj != null) wrapper["params"] = paramsObj;
        return JsonDocument.Parse(JsonSerializer.Serialize(wrapper));
    }

    [Fact]
    public async Task Initialize_ReturnsCapabilities()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());
        server.Tool("echo", "Echo tool");

        var resp = await server.HandleRequest(MakeRequest("initialize"));
        Assert.NotNull(resp);
        Assert.Equal("2.0", resp!["jsonrpc"]);
        var result = (Dictionary<string, object>)resp["result"]!;
        Assert.Equal("2024-11-05", result["protocolVersion"]);

        var serverInfo = (Dictionary<string, object>)result["serverInfo"];
        Assert.Equal("zeromcp", serverInfo["name"]);

        var capabilities = (Dictionary<string, object>)result["capabilities"];
        Assert.True(capabilities.ContainsKey("tools"));
        Assert.True(capabilities.ContainsKey("logging"));
    }

    [Fact]
    public async Task Initialize_WithResources_IncludesResourceCapability()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());
        server.Resource("r", "file:///r.txt", readFunc: () => Task.FromResult(""));

        var resp = await server.HandleRequest(MakeRequest("initialize"));
        var result = (Dictionary<string, object>)resp!["result"]!;
        var capabilities = (Dictionary<string, object>)result["capabilities"];
        Assert.True(capabilities.ContainsKey("resources"));
    }

    [Fact]
    public async Task Initialize_WithPrompts_IncludesPromptCapability()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());
        server.Prompt("p", renderFunc: _ => Task.FromResult(new List<Dictionary<string, object>>()));

        var resp = await server.HandleRequest(MakeRequest("initialize"));
        var result = (Dictionary<string, object>)resp!["result"]!;
        var capabilities = (Dictionary<string, object>)result["capabilities"];
        Assert.True(capabilities.ContainsKey("prompts"));
    }

    [Fact]
    public async Task Initialize_NoResourcesOrPrompts_ExcludesThoseCapabilities()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());
        server.Tool("t", "T");

        var resp = await server.HandleRequest(MakeRequest("initialize"));
        var result = (Dictionary<string, object>)resp!["result"]!;
        var capabilities = (Dictionary<string, object>)result["capabilities"];
        Assert.False(capabilities.ContainsKey("resources"));
        Assert.False(capabilities.ContainsKey("prompts"));
    }

    [Fact]
    public async Task Ping_ReturnsEmptyResult()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());

        var resp = await server.HandleRequest(MakeRequest("ping"));
        Assert.NotNull(resp);
        var result = (Dictionary<string, object>)resp!["result"]!;
        Assert.Empty(result);
    }

    [Fact]
    public async Task UnknownMethod_ReturnsMethodNotFound()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());

        var resp = await server.HandleRequest(MakeRequest("nonexistent/method"));
        Assert.NotNull(resp);
        Assert.True(resp!.ContainsKey("error"));
        var error = (Dictionary<string, object>)resp["error"]!;
        Assert.Equal(-32601, error["code"]);
        Assert.Contains("nonexistent/method", (string)error["message"]);
    }

    [Fact]
    public async Task Notification_ReturnsNull()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());

        var resp = await server.HandleRequest(MakeNotification("notifications/initialized"));
        Assert.Null(resp);
    }

    [Fact]
    public async Task ToolsCall_ValidTool_ReturnsResult()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());
        server.Tool("echo", "Echo input",
            input: new Dictionary<string, InputField>
            {
                ["message"] = new InputField(SimpleType.String)
            },
            execute: (args, ctx) =>
            {
                var msg = args["message"].GetString();
                return Task.FromResult<object>($"Echo: {msg}");
            });

        var resp = await server.HandleRequest(MakeRequest("tools/call",
            new Dictionary<string, object>
            {
                ["name"] = "echo",
                ["arguments"] = new Dictionary<string, object> { ["message"] = "hello" }
            }));

        Assert.NotNull(resp);
        var result = (Dictionary<string, object>)resp!["result"]!;
        var content = (List<Dictionary<string, string>>)result["content"];
        Assert.Equal("Echo: hello", content[0]["text"]);
        Assert.False(result.ContainsKey("isError"));
    }

    [Fact]
    public async Task ToolsCall_UnknownTool_ReturnsError()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());

        var resp = await server.HandleRequest(MakeRequest("tools/call",
            new Dictionary<string, object> { ["name"] = "nonexistent" }));

        Assert.NotNull(resp);
        var result = (Dictionary<string, object>)resp!["result"]!;
        Assert.Equal(true, result["isError"]);
    }

    [Fact]
    public async Task ToolsCall_ValidationFails_ReturnsError()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());
        server.Tool("strict", "Requires name",
            input: new Dictionary<string, InputField>
            {
                ["name"] = new InputField(SimpleType.String)
            },
            execute: (args, ctx) => Task.FromResult<object>("ok"));

        // Call without required argument
        var resp = await server.HandleRequest(MakeRequest("tools/call",
            new Dictionary<string, object> { ["name"] = "strict" }));

        Assert.NotNull(resp);
        var result = (Dictionary<string, object>)resp!["result"]!;
        Assert.Equal(true, result["isError"]);
        var content = (List<Dictionary<string, string>>)result["content"];
        Assert.Contains("Validation errors", content[0]["text"]);
    }

    [Fact]
    public async Task ToolsCall_ExecuteThrows_ReturnsError()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());
        server.Tool("broken", "Throws",
            execute: (args, ctx) => throw new InvalidOperationException("tool crashed"));

        var resp = await server.HandleRequest(MakeRequest("tools/call",
            new Dictionary<string, object> { ["name"] = "broken" }));

        Assert.NotNull(resp);
        var result = (Dictionary<string, object>)resp!["result"]!;
        Assert.Equal(true, result["isError"]);
        var content = (List<Dictionary<string, string>>)result["content"];
        Assert.Contains("tool crashed", content[0]["text"]);
    }

    [Fact]
    public async Task ToolsList_ReturnsAllTools()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());
        server.Tool("alpha", "First tool");
        server.Tool("beta", "Second tool",
            input: new Dictionary<string, InputField>
            {
                ["x"] = new InputField(SimpleType.Number, description: "A number")
            });

        var resp = await server.HandleRequest(MakeRequest("tools/list"));
        Assert.NotNull(resp);
        var result = (Dictionary<string, object>)resp!["result"]!;
        var tools = (List<Dictionary<string, object>>)result["tools"];
        Assert.Equal(2, tools.Count);
        // Sorted alphabetically
        Assert.Equal("alpha", tools[0]["name"]);
        Assert.Equal("beta", tools[1]["name"]);
    }

    [Fact]
    public async Task LoggingSetLevel_Succeeds()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());

        var resp = await server.HandleRequest(MakeRequest("logging/setLevel",
            new Dictionary<string, object> { ["level"] = "debug" }));

        Assert.NotNull(resp);
        Assert.True(resp!.ContainsKey("result"));
    }

    [Fact]
    public async Task CompletionComplete_ReturnsEmptyValues()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());

        var resp = await server.HandleRequest(MakeRequest("completion/complete"));
        Assert.NotNull(resp);
        var result = (Dictionary<string, object>)resp!["result"]!;
        var completion = (Dictionary<string, object>)result["completion"];
        var values = (List<string>)completion["values"];
        Assert.Empty(values);
    }

    [Fact]
    public async Task ResponseId_MatchesRequestId()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());

        var resp = await server.HandleRequest(MakeRequest("ping", id: 42));
        Assert.NotNull(resp);
        // The id comes back as long due to JsonElement parsing
        Assert.Equal(42L, resp!["id"]);
    }

    [Fact]
    public async Task StringId_MatchesRequestId()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());

        var resp = await server.HandleRequest(MakeRequest("ping", id: "req-abc"));
        Assert.NotNull(resp);
        Assert.Equal("req-abc", resp!["id"]);
    }

    [Fact]
    public async Task Icon_IncludedInToolsList()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());
        server.Icon = "https://example.com/icon.png";
        server.Tool("t", "Tool with icon");

        var resp = await server.HandleRequest(MakeRequest("tools/list"));
        var result = (Dictionary<string, object>)resp!["result"]!;
        var tools = (List<Dictionary<string, object>>)result["tools"];
        Assert.True(tools[0].ContainsKey("icons"));
    }

    [Fact]
    public async Task ToolsCall_ObjectResult_SerializedAsJson()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());
        server.Tool("obj", "Returns object",
            execute: (args, ctx) => Task.FromResult<object>(new Dictionary<string, int> { ["count"] = 5 }));

        var resp = await server.HandleRequest(MakeRequest("tools/call",
            new Dictionary<string, object> { ["name"] = "obj" }));

        var result = (Dictionary<string, object>)resp!["result"]!;
        var content = (List<Dictionary<string, string>>)result["content"];
        // Should be JSON serialized
        Assert.Contains("count", content[0]["text"]);
        Assert.Contains("5", content[0]["text"]);
    }
}
