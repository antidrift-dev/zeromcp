using System.Text;
using System.Text.Json;

namespace ZeroMcp;

/// <summary>
/// Federates tools from remote MCP servers over HTTP JSON-RPC.
/// Port of nodejs/src/remote.ts.
/// </summary>
internal static class RemoteManager
{
    private static readonly HttpClient Http = new();

    /// <summary>
    /// Returns "&lt;server.Name&gt;.&lt;toolName&gt;" -> ToolDefinition.
    /// Never throws; per-server failures are logged and skipped.
    /// </summary>
    internal static async Task<Dictionary<string, ToolDefinition>> Connect(IEnumerable<RemoteServer> servers)
    {
        var allTools = new Dictionary<string, ToolDefinition>();

        foreach (var server in servers)
        {
            try
            {
                var tools = await ConnectOne(server);
                // Namespace: servername.toolname
                foreach (var (toolName, tool) in tools)
                {
                    var namespacedName = $"{server.Name}.{toolName}";
                    allTools[namespacedName] = tool;
                    Console.Error.WriteLine($"[mcp] Remote tool: {namespacedName}");
                }
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[mcp] Failed to connect to {server.Name}: {ex.Message}");
            }
        }

        return allTools;
    }

    private static async Task<Dictionary<string, ToolDefinition>> ConnectOne(RemoteServer server)
    {
        if (!server.Url.StartsWith("http://") && !server.Url.StartsWith("https://"))
        {
            throw new InvalidOperationException(
                $"Remote server \"{server.Name}\" must have an HTTP/HTTPS URL, got: {server.Url}");
        }

        var tools = new Dictionary<string, ToolDefinition>();
        var auth = ZeroMcpConfig.ResolveAuth(server.Auth);

        // Initialize
        using (await HttpRpc(server.Url, new Dictionary<string, object?>
        {
            ["jsonrpc"] = "2.0", ["id"] = 1, ["method"] = "initialize", ["params"] = new Dictionary<string, object>()
        }, auth)) { }

        // List tools
        using var listRes = await HttpRpc(server.Url, new Dictionary<string, object?>
        {
            ["jsonrpc"] = "2.0", ["id"] = 2, ["method"] = "tools/list", ["params"] = new Dictionary<string, object>()
        }, auth);

        var remoteTools = new List<JsonElement>();
        if (listRes.RootElement.ValueKind == JsonValueKind.Object &&
            listRes.RootElement.TryGetProperty("result", out var result) &&
            result.ValueKind == JsonValueKind.Object &&
            result.TryGetProperty("tools", out var toolsEl) &&
            toolsEl.ValueKind == JsonValueKind.Array)
        {
            foreach (var t in toolsEl.EnumerateArray()) remoteTools.Add(t.Clone());
        }

        foreach (var rt in remoteTools)
        {
            var rtName = rt.TryGetProperty("name", out var n) && n.ValueKind == JsonValueKind.String ? n.GetString()! : "";
            if (server.Tools != null && !server.Tools.Contains(rtName)) continue;

            var description = rt.TryGetProperty("description", out var d) && d.ValueKind == JsonValueKind.String
                ? d.GetString()! : "";
            var input = rt.TryGetProperty("inputSchema", out var schemaEl)
                ? SchemaToInput(schemaEl)
                : new Dictionary<string, InputField>();

            var url = server.Url;
            tools[rtName] = new ToolDefinition
            {
                Description = description,
                Input = input,
                Route = null,
                Permissions = null,
                Execute = async (args, _) =>
                {
                    using var callRes = await HttpRpc(url, new Dictionary<string, object?>
                    {
                        ["jsonrpc"] = "2.0",
                        ["id"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                        ["method"] = "tools/call",
                        ["params"] = new Dictionary<string, object?> { ["name"] = rtName, ["arguments"] = args }
                    }, auth);

                    var root = callRes.RootElement;
                    if (root.ValueKind != JsonValueKind.Object || !root.TryGetProperty("result", out var res))
                        return null!;

                    if (res.ValueKind == JsonValueKind.Object &&
                        res.TryGetProperty("content", out var content) &&
                        content.ValueKind == JsonValueKind.Array &&
                        content.GetArrayLength() > 0 &&
                        content[0].ValueKind == JsonValueKind.Object &&
                        content[0].TryGetProperty("text", out var text) &&
                        text.ValueKind == JsonValueKind.String &&
                        !string.IsNullOrEmpty(text.GetString()))
                    {
                        return text.GetString()!;
                    }

                    return res.Clone();
                }
            };
        }

        Console.Error.WriteLine($"[mcp] Connected to {server.Name} (HTTP): {tools.Count} tool(s)");
        return tools;
    }

    private static async Task<JsonDocument> HttpRpc(string url, object body, string? auth)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, url)
        {
            Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json")
        };
        if (!string.IsNullOrEmpty(auth))
            request.Headers.TryAddWithoutValidation("Authorization", $"Bearer {auth}");

        using var res = await Http.SendAsync(request);
        if (!res.IsSuccessStatusCode) throw new HttpRequestException($"HTTP {(int)res.StatusCode}");

        await using var stream = await res.Content.ReadAsStreamAsync();
        return await JsonDocument.ParseAsync(stream);
    }

    /// <summary>
    /// Convert a remote JSON Schema into InputFields: type defaults to "string",
    /// description kept, not-in-required means optional. An unknown type throws,
    /// which fails the whole server (Node's toJsonSchema does the same).
    /// </summary>
    internal static Dictionary<string, InputField> SchemaToInput(JsonElement schema)
    {
        var input = new Dictionary<string, InputField>();
        if (schema.ValueKind != JsonValueKind.Object ||
            !schema.TryGetProperty("properties", out var props) ||
            props.ValueKind != JsonValueKind.Object)
        {
            return input;
        }

        var required = new HashSet<string>();
        if (schema.TryGetProperty("required", out var req) && req.ValueKind == JsonValueKind.Array)
        {
            foreach (var r in req.EnumerateArray())
                if (r.ValueKind == JsonValueKind.String) required.Add(r.GetString()!);
        }

        foreach (var prop in props.EnumerateObject())
        {
            var p = prop.Value;
            var typeName = p.ValueKind == JsonValueKind.Object &&
                           p.TryGetProperty("type", out var t) && t.ValueKind == JsonValueKind.String &&
                           !string.IsNullOrEmpty(t.GetString())
                ? t.GetString()!
                : "string";

            if (!Enum.TryParse<SimpleType>(typeName, ignoreCase: true, out var type) ||
                !Enum.IsDefined(type) ||
                typeName.Any(char.IsDigit))
            {
                throw new InvalidOperationException($"Unknown type \"{typeName}\" for field \"{prop.Name}\"");
            }

            var description = p.ValueKind == JsonValueKind.Object &&
                              p.TryGetProperty("description", out var d) && d.ValueKind == JsonValueKind.String &&
                              !string.IsNullOrEmpty(d.GetString())
                ? d.GetString()
                : null;

            input[prop.Name] = new InputField(type, description, optional: !required.Contains(prop.Name));
        }

        return input;
    }
}
