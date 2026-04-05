using System.Text.Json;
using System.Text.Json.Serialization;

namespace ZeroMcp;

public class ZeroMcpServer
{
    private readonly Dictionary<string, ToolDefinition> _tools = new();
    private readonly ZeroMcpConfig _config;

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = false
    };

    public ZeroMcpServer(ZeroMcpConfig? config = null)
    {
        _config = config ?? ZeroMcpConfig.Load();
    }

    public void Tool(string name, ToolDefinition tool)
    {
        _tools[name] = tool;
    }

    public void Tool(
        string name,
        string description,
        Dictionary<string, InputField>? input = null,
        Func<Dictionary<string, JsonElement>, ToolContext, Task<object>>? execute = null)
    {
        _tools[name] = new ToolDefinition
        {
            Description = description,
            Input = input ?? new(),
            Execute = execute
        };
    }

    public async Task Serve()
    {
        Console.Error.WriteLine($"[zeromcp] {_tools.Count} tool(s) loaded");
        Console.Error.WriteLine("[zeromcp] stdio transport ready");

        using var reader = new StreamReader(Console.OpenStandardInput());

        while (await reader.ReadLineAsync() is { } line)
        {
            line = line.Trim();
            if (string.IsNullOrEmpty(line)) continue;

            JsonDocument request;
            try
            {
                request = JsonDocument.Parse(line);
                // Verify it's an object (malformed_json resilience)
                if (request.RootElement.ValueKind != JsonValueKind.Object)
                    continue;
            }
            catch (JsonException)
            {
                continue;
            }
            catch (Exception)
            {
                continue;
            }

            Dictionary<string, object?>? response;
            try
            {
                response = await HandleRequest(request);
            }
            catch (Exception)
            {
                // Malformed JSON that slipped past parsing -- skip
                continue;
            }
            if (response != null)
            {
                var json = JsonSerializer.Serialize(response, JsonOptions);
                Console.Out.WriteLine(json);
                Console.Out.Flush();
            }
        }
    }

    /// <summary>
    /// Process a single JSON-RPC request and return a response.
    /// Returns null for notifications that require no response.
    /// </summary>
    /// <example>
    /// var request = JsonDocument.Parse("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}");
    /// var response = await server.HandleRequest(request);
    /// </example>
    public async Task<Dictionary<string, object?>?> HandleRequest(JsonDocument request)
    {
        var root = request.RootElement;
        var hasId = root.TryGetProperty("id", out var idElement);
        object? id = hasId ? GetIdValue(idElement) : null;
        var method = root.TryGetProperty("method", out var m) ? m.GetString() ?? "" : "";
        var paramsEl = root.TryGetProperty("params", out var p) ? p : default;

        if (!hasId && method == "notifications/initialized")
        {
            return null;
        }

        switch (method)
        {
            case "initialize":
                return MakeResponse(id, new Dictionary<string, object>
                {
                    ["protocolVersion"] = "2024-11-05",
                    ["capabilities"] = new Dictionary<string, object>
                    {
                        ["tools"] = new Dictionary<string, object> { ["listChanged"] = true }
                    },
                    ["serverInfo"] = new Dictionary<string, object>
                    {
                        ["name"] = "zeromcp",
                        ["version"] = "0.1.0"
                    }
                });

            case "tools/list":
                return MakeResponse(id, new Dictionary<string, object>
                {
                    ["tools"] = BuildToolList()
                });

            case "tools/call":
                var result = await CallTool(paramsEl);
                return MakeResponse(id, result);

            case "ping":
                return MakeResponse(id, new Dictionary<string, object>());

            default:
                if (!hasId) return null;
                return new Dictionary<string, object?>
                {
                    ["jsonrpc"] = "2.0",
                    ["id"] = id,
                    ["error"] = new Dictionary<string, object>
                    {
                        ["code"] = -32601,
                        ["message"] = $"Method not found: {method}"
                    }
                };
        }
    }

    private static object? GetIdValue(JsonElement el) => el.ValueKind switch
    {
        JsonValueKind.Number => el.GetInt64(),
        JsonValueKind.String => el.GetString(),
        _ => null
    };

    private Dictionary<string, object?> MakeResponse(object? id, object result)
    {
        return new Dictionary<string, object?>
        {
            ["jsonrpc"] = "2.0",
            ["id"] = id,
            ["result"] = result
        };
    }

    private List<Dictionary<string, object>> BuildToolList()
    {
        return _tools.OrderBy(kv => kv.Key).Select(kv =>
        {
            var schema = Schema.ToJsonSchema(kv.Value.Input);
            return new Dictionary<string, object>
            {
                ["name"] = kv.Key,
                ["description"] = kv.Value.Description,
                ["inputSchema"] = schema
            };
        }).ToList();
    }

    private async Task<Dictionary<string, object>> CallTool(JsonElement paramsEl)
    {
        var name = paramsEl.TryGetProperty("name", out var n) ? n.GetString() ?? "" : "";
        var args = new Dictionary<string, JsonElement>();
        if (paramsEl.TryGetProperty("arguments", out var argsEl) && argsEl.ValueKind == JsonValueKind.Object)
        {
            foreach (var prop in argsEl.EnumerateObject())
            {
                args[prop.Name] = prop.Value.Clone();
            }
        }

        if (!_tools.TryGetValue(name, out var tool))
        {
            return new Dictionary<string, object>
            {
                ["content"] = new List<Dictionary<string, string>>
                {
                    new() { ["type"] = "text", ["text"] = $"Unknown tool: {name}" }
                },
                ["isError"] = true
            };
        }

        var schema = Schema.ToJsonSchema(tool.Input);
        var errors = Schema.Validate(args, schema);
        if (errors.Count > 0)
        {
            return new Dictionary<string, object>
            {
                ["content"] = new List<Dictionary<string, string>>
                {
                    new() { ["type"] = "text", ["text"] = $"Validation errors:\n{string.Join("\n", errors)}" }
                },
                ["isError"] = true
            };
        }

        try
        {
            var ctx = new ToolContext { ToolName = name, Permissions = tool.Permissions };

            // Tool-level timeout overrides config default
            var timeoutMs = tool.Permissions?.ExecuteTimeout ?? _config.ExecuteTimeout ?? 30000;

            var executeTask = tool.Execute!(args, ctx);
            var delayTask = Task.Delay(timeoutMs);

            var completed = await Task.WhenAny(executeTask, delayTask);
            if (completed == delayTask)
            {
                return new Dictionary<string, object>
                {
                    ["content"] = new List<Dictionary<string, string>>
                    {
                        new() { ["type"] = "text", ["text"] = $"Tool \"{name}\" timed out after {timeoutMs}ms" }
                    },
                    ["isError"] = true
                };
            }

            var result = await executeTask;
            var text = result is string s
                ? s
                : JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = false });

            return new Dictionary<string, object>
            {
                ["content"] = new List<Dictionary<string, string>>
                {
                    new() { ["type"] = "text", ["text"] = text }
                }
            };
        }
        catch (Exception ex)
        {
            return new Dictionary<string, object>
            {
                ["content"] = new List<Dictionary<string, string>>
                {
                    new() { ["type"] = "text", ["text"] = $"Error: {ex.Message}" }
                },
                ["isError"] = true
            };
        }
    }
}
