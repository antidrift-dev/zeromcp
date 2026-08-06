using System.Text.Json;

namespace ZeroMcp;

/// <summary>A single JSON-RPC request/response round trip, reusing ZeroMcpServer's own dispatch.</summary>
public delegate Task<Dictionary<string, object?>?> McpHandler(JsonDocument request);

/// <summary>One route-tagged tool, exposed as plain data — no HTTP binding is done here.</summary>
public record RouteDefinition(string Name, string Method, string Path, ToolDefinition Tool);

public class RegistryOptions
{
    /// <summary>
    /// Supplies the ToolContext passed to every tool's Execute when invoked through
    /// ToolRegistry.Mcp or a caller-driven route dispatch. Defaults to a context with
    /// only ToolName/Permissions populated (Credentials left null), matching what
    /// ZeroMcpServer.CallTool already constructs.
    /// </summary>
    public Func<string, Permissions?, ToolContext>? GetContext { get; set; }
}

public class ToolRegistry
{
    public IReadOnlyList<RouteDefinition> Routes { get; init; } = Array.Empty<RouteDefinition>();
    public Dictionary<string, object> OpenApi { get; init; } = new();
    public McpHandler Mcp { get; init; } = null!;
}

public static class Registry
{
    public static ToolRegistry Create(
        Dictionary<string, ToolDefinition> tools,
        RegistryOptions? options = null)
    {
        var server = new ZeroMcpServer { ContextFactory = options?.GetContext };
        foreach (var (name, tool) in tools)
        {
            server.Tool(name, tool);
        }

        var routes = tools
            .Where(kv => kv.Value.Route != null)
            .Select(kv => new RouteDefinition(kv.Key, kv.Value.Route!.Method, kv.Value.Route!.Path, kv.Value))
            .ToList();

        return new ToolRegistry
        {
            Routes = routes,
            OpenApi = server.BuildOpenApiSpec(),
            Mcp = request => server.HandleRequest(request)
        };
    }
}
