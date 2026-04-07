using System.Text.Json;
using Xunit;
using ZeroMcp;

namespace ZeroMcp.Tests;

public class TemplateTests
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
    public async Task TemplateRegistration_AppearsInTemplatesList()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());
        server.ResourceTemplate("user-profile", "users/{userId}/profile",
            description: "User profile",
            mimeType: "application/json",
            readFunc: args => Task.FromResult($"{{\"id\": \"{args["userId"]}\"}}"));

        var resp = await server.HandleRequest(MakeRequest("resources/templates/list"));
        Assert.NotNull(resp);
        var result = (Dictionary<string, object>)resp!["result"]!;
        var templates = (List<Dictionary<string, object>>)result["resourceTemplates"];
        Assert.Single(templates);
        Assert.Equal("users/{userId}/profile", templates[0]["uriTemplate"]);
        Assert.Equal("user-profile", templates[0]["name"]);
        Assert.Equal("application/json", templates[0]["mimeType"]);
        Assert.Equal("User profile", templates[0]["description"]);
    }

    [Fact]
    public async Task TemplateMatch_SingleParam_ReturnsContent()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());
        server.ResourceTemplate("user", "users/{id}",
            readFunc: args => Task.FromResult($"User {args["id"]}"));

        var resp = await server.HandleRequest(MakeRequest("resources/read",
            new Dictionary<string, object> { ["uri"] = "users/42" }));

        Assert.NotNull(resp);
        Assert.True(resp!.ContainsKey("result"));
        var result = (Dictionary<string, object>)resp["result"]!;
        var contents = (List<Dictionary<string, string>>)result["contents"];
        Assert.Equal("User 42", contents[0]["text"]);
        Assert.Equal("users/42", contents[0]["uri"]);
    }

    [Fact]
    public async Task TemplateMatch_MultipleParams_ExtractsAll()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());
        server.ResourceTemplate("repo-file", "repos/{owner}/{repo}/files/{path}",
            readFunc: args => Task.FromResult($"{args["owner"]}/{args["repo"]}:{args["path"]}"));

        var resp = await server.HandleRequest(MakeRequest("resources/read",
            new Dictionary<string, object> { ["uri"] = "repos/acme/widgets/files/readme" }));

        Assert.NotNull(resp);
        var result = (Dictionary<string, object>)resp["result"]!;
        var contents = (List<Dictionary<string, string>>)result["contents"];
        Assert.Equal("acme/widgets:readme", contents[0]["text"]);
    }

    [Fact]
    public async Task TemplateNoMatch_ReturnsNotFound()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());
        server.ResourceTemplate("user", "users/{id}",
            readFunc: args => Task.FromResult("data"));

        var resp = await server.HandleRequest(MakeRequest("resources/read",
            new Dictionary<string, object> { ["uri"] = "posts/1" }));

        Assert.NotNull(resp);
        Assert.True(resp!.ContainsKey("error"));
        var error = (Dictionary<string, object>)resp["error"]!;
        Assert.Equal(-32002, error["code"]);
    }

    [Fact]
    public async Task TemplateReadThrows_ReturnsError()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());
        server.ResourceTemplate("broken", "items/{id}",
            readFunc: _ => throw new Exception("template read failed"));

        var resp = await server.HandleRequest(MakeRequest("resources/read",
            new Dictionary<string, object> { ["uri"] = "items/5" }));

        Assert.NotNull(resp);
        Assert.True(resp!.ContainsKey("error"));
        var error = (Dictionary<string, object>)resp["error"]!;
        Assert.Equal(-32603, error["code"]);
        Assert.Contains("template read failed", (string)error["message"]);
    }

    [Fact]
    public async Task StaticResourceTakesPrecedenceOverTemplate()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig());
        server.Resource("specific", "users/admin",
            readFunc: () => Task.FromResult("static admin"));
        server.ResourceTemplate("user", "users/{id}",
            readFunc: args => Task.FromResult($"template {args["id"]}"));

        var resp = await server.HandleRequest(MakeRequest("resources/read",
            new Dictionary<string, object> { ["uri"] = "users/admin" }));

        Assert.NotNull(resp);
        var result = (Dictionary<string, object>)resp["result"]!;
        var contents = (List<Dictionary<string, string>>)result["contents"];
        Assert.Equal("static admin", contents[0]["text"]);
    }

    [Fact]
    public async Task TemplatesPagination_Works()
    {
        var server = new ZeroMcpServer(new ZeroMcpConfig(), pageSize: 1);
        server.ResourceTemplate("t1", "a/{id}", readFunc: _ => Task.FromResult(""));
        server.ResourceTemplate("t2", "b/{id}", readFunc: _ => Task.FromResult(""));

        var resp = await server.HandleRequest(MakeRequest("resources/templates/list"));
        var result = (Dictionary<string, object>)resp!["result"]!;
        var templates = (List<Dictionary<string, object>>)result["resourceTemplates"];
        Assert.Single(templates);
        Assert.True(result.ContainsKey("nextCursor"));
    }
}
