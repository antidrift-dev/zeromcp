using System.Text.Json;
using Xunit;
using ZeroMcp;

namespace ZeroMcp.Tests;

[Collection("Stderr")]
public class RemoteTests
{
    private static JsonDocument MakeRequest(string method, object? paramsObj = null, object? id = null)
    {
        var wrapper = new Dictionary<string, object?>
        {
            ["jsonrpc"] = "2.0",
            ["id"] = id ?? 1,
            ["method"] = method
        };
        if (paramsObj != null) wrapper["params"] = paramsObj;
        return JsonDocument.Parse(JsonSerializer.Serialize(wrapper));
    }

    private static ZeroMcpServer ServerWith(params RemoteServer[] remote) =>
        new(new ZeroMcpConfig { Remote = remote.ToList() });

    private static async Task<List<Dictionary<string, object>>> ListTools(ZeroMcpServer server)
    {
        var response = await server.HandleRequest(MakeRequest("tools/list"));
        var result = (Dictionary<string, object>)response!["result"]!;
        return (List<Dictionary<string, object>>)result["tools"];
    }

    private static async Task<(string text, bool isError)> Call(ZeroMcpServer server, string name, object args)
    {
        var response = await server.HandleRequest(MakeRequest("tools/call", new { name, arguments = args }));
        var result = (Dictionary<string, object>)response!["result"]!;
        var content = (List<Dictionary<string, string>>)result["content"];
        return (content[0]["text"], result.ContainsKey("isError"));
    }

    private static ToolDefinition LocalListPages() => new()
    {
        Description = "local",
        Input = new() { ["domain"] = new InputField(SimpleType.String) },
        Execute = (_, _) => Task.FromResult<object>("local result")
    };

    [Fact]
    public async Task Prepare_FederatesRemoteTools()
    {
        using var stub = new StubMcpServer();
        var server = ServerWith(new RemoteServer { Name = "probeo", Url = stub.Url });
        await server.Prepare();

        var names = (await ListTools(server)).Select(t => (string)t["name"]).ToList();
        Assert.Equal(new[] { "probeo.get_page", "probeo.list_pages" }, names);

        var (text, isError) = await Call(server, "probeo.list_pages", new { domain = "example.com" });
        Assert.False(isError);
        Assert.Equal(StubMcpServer.CallText, text);

        Assert.True(stub.Calls.TryDequeue(out var call));
        Assert.Equal("list_pages", call.GetProperty("name").GetString());
        Assert.Equal("example.com", call.GetProperty("arguments").GetProperty("domain").GetString());
    }

    [Fact]
    public async Task LocalTool_RegisteredBefore_OverridesRemote()
    {
        using var stub = new StubMcpServer();
        using var err = new StderrCapture();
        var server = ServerWith(new RemoteServer { Name = "probeo", Url = stub.Url });
        server.Tool("probeo.list_pages", LocalListPages());
        await server.Prepare();

        var (text, _) = await Call(server, "probeo.list_pages", new { domain = "x" });
        Assert.Equal("local result", text);
        Assert.Contains("[zeromcp] Local tool \"probeo.list_pages\" overrides remote", err.Text);
    }

    [Fact]
    public async Task LocalTool_RegisteredAfter_OverridesRemote()
    {
        using var stub = new StubMcpServer();
        using var err = new StderrCapture();
        var server = ServerWith(new RemoteServer { Name = "probeo", Url = stub.Url });
        await server.Prepare();
        server.Tool("probeo.list_pages", LocalListPages());

        var (text, _) = await Call(server, "probeo.list_pages", new { domain = "x" });
        Assert.Equal("local result", text);
        Assert.Contains("overrides remote", err.Text);
    }

    [Fact]
    public async Task NonHttpUrl_IsSkipped_OtherServerConnects()
    {
        using var stub = new StubMcpServer();
        using var err = new StderrCapture();
        var server = ServerWith(
            new RemoteServer { Name = "bad", Url = "ftp://example.com" },
            new RemoteServer { Name = "probeo", Url = stub.Url });
        await server.Prepare();

        var names = (await ListTools(server)).Select(t => (string)t["name"]).ToList();
        Assert.Equal(new[] { "probeo.get_page", "probeo.list_pages" }, names);
        Assert.Contains("[mcp] Failed to connect to bad: Remote server \"bad\" must have an HTTP/HTTPS URL, got: ftp://example.com", err.Text);
        Assert.Contains("[mcp] Connected to probeo (HTTP): 2 tool(s)", err.Text);
    }

    [Fact]
    public async Task Http500_FailsThatServer()
    {
        using var stub = new StubMcpServer(status: 500);
        using var err = new StderrCapture();
        var server = ServerWith(new RemoteServer { Name = "broken", Url = stub.Url });
        await server.Prepare();

        Assert.Empty(await ListTools(server));
        Assert.Contains("[mcp] Failed to connect to broken: HTTP 500", err.Text);
    }

    [Fact]
    public async Task Auth_EnvVar_SentAsBearer()
    {
        Environment.SetEnvironmentVariable("ZEROMCP_TEST_TOKEN", "tok-123");
        try
        {
            using var stub = new StubMcpServer();
            var server = ServerWith(new RemoteServer { Name = "probeo", Url = stub.Url, Auth = "env:ZEROMCP_TEST_TOKEN" });
            await server.Prepare();
            await Call(server, "probeo.list_pages", new { domain = "x" });

            Assert.NotEmpty(stub.AuthHeaders);
            Assert.All(stub.AuthHeaders, h => Assert.Equal("Bearer tok-123", h));
        }
        finally
        {
            Environment.SetEnvironmentVariable("ZEROMCP_TEST_TOKEN", null);
        }
    }

    [Fact]
    public async Task Auth_Literal_SentAsIs()
    {
        using var stub = new StubMcpServer();
        var server = ServerWith(new RemoteServer { Name = "probeo", Url = stub.Url, Auth = "literal-key" });
        await server.Prepare();

        Assert.NotEmpty(stub.AuthHeaders);
        Assert.All(stub.AuthHeaders, h => Assert.Equal("Bearer literal-key", h));
    }

    [Fact]
    public async Task NoAuth_SendsNoAuthorizationHeader()
    {
        using var stub = new StubMcpServer();
        var server = ServerWith(new RemoteServer { Name = "probeo", Url = stub.Url });
        await server.Prepare();

        Assert.All(stub.AuthHeaders, Assert.Null);
    }

    [Fact]
    public async Task SchemaToInput_DefaultsTypeKeepsDescriptionAndOptional()
    {
        const string tools = """
        [
          { "name": "search", "description": "Search.", "inputSchema": { "type": "object",
            "properties": {
              "q": { "description": "query text" },
              "limit": { "type": "number" }
            },
            "required": ["q"] } }
        ]
        """;
        using var stub = new StubMcpServer(tools);
        var server = ServerWith(new RemoteServer { Name = "up", Url = stub.Url });
        await server.Prepare();

        var tool = Assert.Single(await ListTools(server));
        var schema = JsonSerializer.SerializeToElement(tool["inputSchema"]);
        Assert.Equal("string", schema.GetProperty("properties").GetProperty("q").GetProperty("type").GetString());
        Assert.Equal("query text", schema.GetProperty("properties").GetProperty("q").GetProperty("description").GetString());
        Assert.Equal("number", schema.GetProperty("properties").GetProperty("limit").GetProperty("type").GetString());
        Assert.Equal(new[] { "q" }, schema.GetProperty("required").EnumerateArray().Select(e => e.GetString()));

        // "limit" is optional: calling without it passes validation
        var (_, isError) = await Call(server, "up.search", new { q = "hi" });
        Assert.False(isError);
    }

    [Fact]
    public async Task SchemaToInput_UnknownType_FailsServer()
    {
        const string tools = """
        [ { "name": "weird", "description": "", "inputSchema": { "type": "object", "properties": { "n": { "type": "integer" } } } } ]
        """;
        using var stub = new StubMcpServer(tools);
        using var err = new StderrCapture();
        var server = ServerWith(new RemoteServer { Name = "up", Url = stub.Url });
        await server.Prepare();

        Assert.Empty(await ListTools(server));
        Assert.Contains("Failed to connect to up: Unknown type \"integer\" for field \"n\"", err.Text);
    }

    [Fact]
    public async Task Allowlist_FiltersUpstreamTools()
    {
        using var stub = new StubMcpServer();
        var server = ServerWith(new RemoteServer { Name = "probeo", Url = stub.Url, Tools = new() { "list_pages" } });
        await server.Prepare();

        var names = (await ListTools(server)).Select(t => (string)t["name"]).ToList();
        Assert.Equal(new[] { "probeo.list_pages" }, names);
    }

    [Fact]
    public async Task Allowlist_Empty_ExposesNothing()
    {
        using var stub = new StubMcpServer();
        var server = ServerWith(new RemoteServer { Name = "probeo", Url = stub.Url, Tools = new() });
        await server.Prepare();

        Assert.Empty(await ListTools(server));
    }

    [Fact]
    public async Task Prepare_Twice_ConnectsOnce()
    {
        using var stub = new StubMcpServer();
        var server = ServerWith(new RemoteServer { Name = "probeo", Url = stub.Url });
        await Task.WhenAll(server.Prepare(), server.Prepare());
        await server.Prepare();

        Assert.Equal(1, stub.InitializeHits);
    }

    [Fact]
    public async Task RemoteTool_AbsentFromOpenApi()
    {
        using var stub = new StubMcpServer();
        // BuildOpenApiSpec is internal; the registry exposes it as OpenApi.
        var registry = await Registry.CreateAsync(new Dictionary<string, ToolDefinition>
        {
            ["greet"] = new ToolDefinition
            {
                Description = "Greet",
                Input = new() { ["name"] = new InputField(SimpleType.String) },
                Route = new ToolRoute { Method = "GET", Path = "/greet/:name" },
                Execute = (_, _) => Task.FromResult<object>("hi")
            }
        }, new RegistryOptions { Remote = new() { new RemoteServer { Name = "probeo", Url = stub.Url } } });

        var paths = (Dictionary<string, object>)registry.OpenApi["paths"];
        Assert.Equal(new[] { "/greet/{name}" }, paths.Keys);
        Assert.Equal("greet", Assert.Single(registry.Routes).Name);
    }
}
