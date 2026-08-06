using System.Text.Json;
using Xunit;
using ZeroMcp;

namespace ZeroMcp.Tests;

public class RegistryTests
{
    private static JsonDocument MakeRequest(string method, object? paramsObj = null, object? id = null)
    {
        var wrapper = new Dictionary<string, object?>
        {
            ["jsonrpc"] = "2.0",
            ["method"] = method
        };
        wrapper["id"] = id ?? 1;
        if (paramsObj != null) wrapper["params"] = paramsObj;
        return JsonDocument.Parse(JsonSerializer.Serialize(wrapper));
    }

    private static ToolDefinition RoutedTool(string method = "GET", string path = "/greet/:name")
    {
        return new ToolDefinition
        {
            Description = "Greet someone",
            Input = new() { ["name"] = new InputField(SimpleType.String) },
            Route = new ToolRoute { Method = method, Path = path },
            Execute = (args, _) => Task.FromResult<object>("hi " + args["name"].GetString())
        };
    }

    private static ToolDefinition UnroutedTool()
    {
        return new ToolDefinition
        {
            Description = "No route",
            Execute = (_, _) => Task.FromResult<object>("")
        };
    }

    [Fact]
    public void Routes_OnlyIncludesRoutedTools()
    {
        var registry = Registry.Create(new Dictionary<string, ToolDefinition>
        {
            ["greet"] = RoutedTool(),
            ["hidden"] = UnroutedTool()
        });

        Assert.Single(registry.Routes);
        Assert.Equal("greet", registry.Routes[0].Name);
        Assert.Equal("GET", registry.Routes[0].Method);
        Assert.Equal("/greet/:name", registry.Routes[0].Path);
    }

    [Fact]
    public void Openapi_MatchesRoutedTools()
    {
        var registry = Registry.Create(new Dictionary<string, ToolDefinition>
        {
            ["greet"] = RoutedTool()
        });

        var paths = (Dictionary<string, object>)registry.OpenApi["paths"];
        Assert.True(paths.ContainsKey("/greet/{name}"));
    }

    [Fact]
    public async Task RouteTool_InvokedDirectly_ProducesExpectedResult()
    {
        var registry = Registry.Create(new Dictionary<string, ToolDefinition>
        {
            ["greet"] = RoutedTool()
        });

        var route = registry.Routes[0];
        var ctx = new ToolContext { ToolName = route.Name, Permissions = route.Tool.Permissions };
        var args = new Dictionary<string, JsonElement>
        {
            ["name"] = JsonSerializer.SerializeToElement("Ada")
        };
        var result = await route.Tool.Execute!(args, ctx);
        Assert.Equal("hi Ada", result);
    }

    [Fact]
    public async Task Mcp_DispatchesToolsList()
    {
        var registry = Registry.Create(new Dictionary<string, ToolDefinition>
        {
            ["greet"] = RoutedTool()
        });

        var response = await registry.Mcp(MakeRequest("tools/list"));
        var result = (Dictionary<string, object>)response!["result"]!;
        var toolsList = (List<Dictionary<string, object>>)result["tools"];
        Assert.Single(toolsList);
    }

    [Fact]
    public async Task Mcp_DispatchesToolsCall()
    {
        var registry = Registry.Create(new Dictionary<string, ToolDefinition>
        {
            ["greet"] = RoutedTool(method: "POST", path: "/greet")
        });

        var response = await registry.Mcp(MakeRequest("tools/call", new
        {
            name = "greet",
            arguments = new { name = "Ada" }
        }));

        var result = (Dictionary<string, object>)response!["result"]!;
        var content = (List<Dictionary<string, string>>)result["content"];
        Assert.Equal("hi Ada", content[0]["text"]);
    }

    [Fact]
    public async Task Mcp_UsesGetContextWhenSupplied()
    {
        ToolContext? captured = null;
        var options = new RegistryOptions
        {
            GetContext = (name, permissions) =>
            {
                var ctx = new ToolContext { ToolName = name, Permissions = permissions, Credentials = "secret" };
                captured = ctx;
                return ctx;
            }
        };
        var registry = Registry.Create(new Dictionary<string, ToolDefinition>
        {
            ["greet"] = new ToolDefinition
            {
                Description = "Greet",
                Input = new() { ["name"] = new InputField(SimpleType.String) },
                Execute = (_, ctx) => Task.FromResult<object>((string)ctx.Credentials!)
            }
        }, options);

        var response = await registry.Mcp(MakeRequest("tools/call", new
        {
            name = "greet",
            arguments = new { name = "Ada" }
        }));

        var result = (Dictionary<string, object>)response!["result"]!;
        var content = (List<Dictionary<string, string>>)result["content"];
        Assert.Equal("secret", content[0]["text"]);
        Assert.NotNull(captured);
    }

    [Fact]
    public void Empty_WhenNoRoutedTools()
    {
        var registry = Registry.Create(new Dictionary<string, ToolDefinition>
        {
            ["hidden"] = UnroutedTool()
        });

        Assert.Empty(registry.Routes);
    }
}
