using System.Text.Json;
using Xunit;
using ZeroMcp;

namespace ZeroMcp.Tests;

public class PaginationTests
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
        var json = JsonSerializer.Serialize(wrapper);
        return JsonDocument.Parse(json);
    }

    private static JsonDocument MakeRequestWithCursor(string method, string cursor)
    {
        var json = JsonSerializer.Serialize(new Dictionary<string, object?>
        {
            ["jsonrpc"] = "2.0",
            ["id"] = 1,
            ["method"] = method,
            ["params"] = new Dictionary<string, object> { ["cursor"] = cursor }
        });
        return JsonDocument.Parse(json);
    }

    [Fact]
    public async Task CursorRoundTrip_EncodesAndDecodesOffset()
    {
        // Create a server with pageSize=2 and 5 tools to force pagination
        var server = new ZeroMcpServer(new ZeroMcpConfig(), pageSize: 2);
        for (int i = 0; i < 5; i++)
        {
            server.Tool($"tool_{i}", $"Tool {i}");
        }

        // First page
        var resp1 = await server.HandleRequest(MakeRequest("tools/list"));
        Assert.NotNull(resp1);
        var result1 = (Dictionary<string, object>)resp1!["result"]!;
        var tools1 = (List<Dictionary<string, object>>)result1["tools"];
        Assert.Equal(2, tools1.Count);
        Assert.True(result1.ContainsKey("nextCursor"));
        var cursor1 = (string)result1["nextCursor"];

        // Second page using the cursor
        var resp2 = await server.HandleRequest(MakeRequestWithCursor("tools/list", cursor1));
        Assert.NotNull(resp2);
        var result2 = (Dictionary<string, object>)resp2!["result"]!;
        var tools2 = (List<Dictionary<string, object>>)result2["tools"];
        Assert.Equal(2, tools2.Count);
        Assert.True(result2.ContainsKey("nextCursor"));

        // Third page (last)
        var cursor2 = (string)result2["nextCursor"];
        var resp3 = await server.HandleRequest(MakeRequestWithCursor("tools/list", cursor2));
        Assert.NotNull(resp3);
        var result3 = (Dictionary<string, object>)resp3!["result"]!;
        var tools3 = (List<Dictionary<string, object>>)result3["tools"];
        Assert.Single(tools3);
        Assert.False(result3.ContainsKey("nextCursor"));
    }

    [Fact]
    public async Task NoPagination_WhenPageSizeIsZero()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig(), pageSize: 0);
        for (int i = 0; i < 5; i++)
        {
            server.Tool($"tool_{i}", $"Tool {i}");
        }

        var resp = await server.HandleRequest(MakeRequest("tools/list"));
        Assert.NotNull(resp);
        var result = (Dictionary<string, object>)resp!["result"]!;
        var tools = (List<Dictionary<string, object>>)result["tools"];
        Assert.Equal(5, tools.Count);
        Assert.False(result.ContainsKey("nextCursor"));
    }

    [Fact]
    public async Task InvalidCursor_FallsBackToStart()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig(), pageSize: 2);
        server.Tool("tool_a", "Tool A");
        server.Tool("tool_b", "Tool B");
        server.Tool("tool_c", "Tool C");

        // Send garbage cursor
        var resp = await server.HandleRequest(MakeRequestWithCursor("tools/list", "not-valid-base64!@#"));
        Assert.NotNull(resp);
        var result = (Dictionary<string, object>)resp!["result"]!;
        var tools = (List<Dictionary<string, object>>)result["tools"];
        Assert.Equal(2, tools.Count);
    }

    [Fact]
    public async Task ResourcesPagination_Works()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig(), pageSize: 1);
        server.Resource("res1", "file:///a.txt", readFunc: () => Task.FromResult("a"));
        server.Resource("res2", "file:///b.txt", readFunc: () => Task.FromResult("b"));

        var resp1 = await server.HandleRequest(MakeRequest("resources/list"));
        Assert.NotNull(resp1);
        var result1 = (Dictionary<string, object>)resp1!["result"]!;
        var resources1 = (List<Dictionary<string, object>>)result1["resources"];
        Assert.Single(resources1);
        Assert.True(result1.ContainsKey("nextCursor"));
    }

    [Fact]
    public async Task PromptsPagination_Works()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig(), pageSize: 1);
        server.Prompt("p1", description: "Prompt 1", renderFunc: _ => Task.FromResult(new List<Dictionary<string, object>>()));
        server.Prompt("p2", description: "Prompt 2", renderFunc: _ => Task.FromResult(new List<Dictionary<string, object>>()));

        var resp1 = await server.HandleRequest(MakeRequest("prompts/list"));
        Assert.NotNull(resp1);
        var result1 = (Dictionary<string, object>)resp1!["result"]!;
        var prompts = (List<Dictionary<string, object>>)result1["prompts"];
        Assert.Single(prompts);
        Assert.True(result1.ContainsKey("nextCursor"));
    }
}
