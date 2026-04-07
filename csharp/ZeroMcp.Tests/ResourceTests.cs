using System.Text.Json;
using Xunit;
using ZeroMcp;

namespace ZeroMcp.Tests;

public class ResourceTests
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
    public async Task ResourceRegistration_AppearsInList()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());
        server.Resource("config", "file:///etc/config.json",
            description: "Config file",
            mimeType: "application/json",
            readFunc: () => Task.FromResult("{}"));

        var resp = await server.HandleRequest(MakeRequest("resources/list"));
        Assert.NotNull(resp);
        var result = (Dictionary<string, object>)resp!["result"]!;
        var resources = (List<Dictionary<string, object>>)result["resources"];
        Assert.Single(resources);
        Assert.Equal("file:///etc/config.json", resources[0]["uri"]);
        Assert.Equal("config", resources[0]["name"]);
        Assert.Equal("application/json", resources[0]["mimeType"]);
        Assert.Equal("Config file", resources[0]["description"]);
    }

    [Fact]
    public async Task ResourceRead_ReturnsContent()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());
        server.Resource("greeting", "file:///hello.txt",
            readFunc: () => Task.FromResult("Hello, world!"));

        var resp = await server.HandleRequest(MakeRequest("resources/read",
            new Dictionary<string, object> { ["uri"] = "file:///hello.txt" }));

        Assert.NotNull(resp);
        var result = (Dictionary<string, object>)resp!["result"]!;
        var contents = (List<Dictionary<string, string>>)result["contents"];
        Assert.Single(contents);
        Assert.Equal("file:///hello.txt", contents[0]["uri"]);
        Assert.Equal("Hello, world!", contents[0]["text"]);
        Assert.Equal("text/plain", contents[0]["mimeType"]);
    }

    [Fact]
    public async Task ResourceRead_NotFound_ReturnsError()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());

        var resp = await server.HandleRequest(MakeRequest("resources/read",
            new Dictionary<string, object> { ["uri"] = "file:///nonexistent.txt" }));

        Assert.NotNull(resp);
        Assert.True(resp!.ContainsKey("error"));
        var error = (Dictionary<string, object>)resp["error"]!;
        Assert.Equal(-32002, error["code"]);
    }

    [Fact]
    public async Task ResourceRead_HandlerThrows_ReturnsError()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());
        server.Resource("broken", "file:///broken.txt",
            readFunc: () => throw new InvalidOperationException("disk error"));

        var resp = await server.HandleRequest(MakeRequest("resources/read",
            new Dictionary<string, object> { ["uri"] = "file:///broken.txt" }));

        Assert.NotNull(resp);
        Assert.True(resp!.ContainsKey("error"));
        var error = (Dictionary<string, object>)resp["error"]!;
        Assert.Equal(-32603, error["code"]);
        Assert.Contains("disk error", (string)error["message"]);
    }

    [Fact]
    public async Task MultipleResources_AllListedCorrectly()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());
        server.Resource("r1", "file:///a.txt", readFunc: () => Task.FromResult("a"));
        server.Resource("r2", "file:///b.txt", readFunc: () => Task.FromResult("b"));
        server.Resource("r3", "file:///c.txt", readFunc: () => Task.FromResult("c"));

        var resp = await server.HandleRequest(MakeRequest("resources/list"));
        var result = (Dictionary<string, object>)resp!["result"]!;
        var resources = (List<Dictionary<string, object>>)result["resources"];
        Assert.Equal(3, resources.Count);
    }

    [Fact]
    public async Task ResourceSubscribe_Succeeds()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());
        server.Resource("data", "file:///data.txt", readFunc: () => Task.FromResult("data"));

        var resp = await server.HandleRequest(MakeRequest("resources/subscribe",
            new Dictionary<string, object> { ["uri"] = "file:///data.txt" }));

        Assert.NotNull(resp);
        Assert.True(resp!.ContainsKey("result"));
    }

    [Fact]
    public async Task ResourceDefaultMimeType_IsTextPlain()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());
        server.Resource("simple", "file:///simple.txt",
            readFunc: () => Task.FromResult("content"));

        var resp = await server.HandleRequest(MakeRequest("resources/list"));
        var result = (Dictionary<string, object>)resp!["result"]!;
        var resources = (List<Dictionary<string, object>>)result["resources"];
        Assert.Equal("text/plain", resources[0]["mimeType"]);
    }
}
