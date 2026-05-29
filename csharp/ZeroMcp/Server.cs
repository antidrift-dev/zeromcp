using System.Text.Json;
using System.Text.Json.Serialization;

namespace ZeroMcp;

public class ZeroMcpServer
{
    private readonly Dictionary<string, ToolDefinition> _tools = new();
    private readonly Dictionary<string, ResourceDefinition> _resources = new();
    private readonly Dictionary<string, ResourceTemplateDefinition> _templates = new();
    private readonly Dictionary<string, PromptDefinition> _prompts = new();
    private readonly HashSet<string> _subscriptions = new();
    private readonly ZeroMcpConfig _config;
    private string _logLevel = "info";
    private int _pageSize;

    /// <summary>Optional icon URI applied to all list entries.</summary>
    public string? Icon { get; set; }

    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        WriteIndented = false
    };

    public ZeroMcpServer(ZeroMcpConfig? config = null, int pageSize = 0)
    {
        _config = config ?? ZeroMcpConfig.Load();
        _pageSize = pageSize;
    }

    public void Tool(string name, ToolDefinition tool)
    {
        tool.CachedSchema = Schema.ToJsonSchema(tool.Input);
        _tools[name] = tool;
    }

    public void Tool(
        string name,
        string description,
        Dictionary<string, InputField>? input = null,
        Func<Dictionary<string, JsonElement>, ToolContext, Task<object>>? execute = null,
        ToolRoute? route = null)
    {
        var def = new ToolDefinition
        {
            Description = description,
            Input = input ?? new(),
            Execute = execute,
            Route = route
        };
        def.CachedSchema = Schema.ToJsonSchema(def.Input);
        _tools[name] = def;
    }

    // --- Resource registration ---

    public void Resource(
        string name,
        string uri,
        string? description = null,
        string mimeType = "text/plain",
        Func<Task<string>>? readFunc = null)
    {
        _resources[name] = new ResourceDefinition
        {
            Uri = uri,
            Name = name,
            Description = description,
            MimeType = mimeType,
            Read = readFunc
        };
    }

    public void ResourceTemplate(
        string name,
        string uriTemplate,
        string? description = null,
        string mimeType = "text/plain",
        Func<Dictionary<string, string>, Task<string>>? readFunc = null)
    {
        _templates[name] = new ResourceTemplateDefinition
        {
            UriTemplate = uriTemplate,
            Name = name,
            Description = description,
            MimeType = mimeType,
            Read = readFunc
        };
    }

    // --- Prompt registration ---

    public void Prompt(
        string name,
        string? description = null,
        List<PromptArgument>? arguments = null,
        Func<Dictionary<string, string>, Task<List<Dictionary<string, object>>>>? renderFunc = null)
    {
        _prompts[name] = new PromptDefinition
        {
            Name = name,
            Description = description,
            Arguments = arguments,
            Render = renderFunc
        };
    }

    public async Task Serve()
    {
        Console.Error.WriteLine($"[zeromcp] {_tools.Count} tool(s), {_resources.Count + _templates.Count} resource(s), {_prompts.Count} prompt(s) loaded");
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
    /// Start an HTTP server that exposes route-based endpoints for tools with a Route defined,
    /// plus a /mcp POST endpoint for raw JSON-RPC requests.
    /// </summary>
    public async Task ServeHttp(int port = 3000)
    {
        var prefix = $"http://+:{port}/";
        var listener = new System.Net.HttpListener();
        listener.Prefixes.Add(prefix);
        listener.Start();
        Console.Error.WriteLine($"[zeromcp] HTTP server listening on port {port}");

        while (true)
        {
            var ctx = await listener.GetContextAsync();
            _ = HandleHttpContext(ctx);
        }
    }

    private async Task HandleHttpContext(System.Net.HttpListenerContext ctx)
    {
        var req = ctx.Request;
        var res = ctx.Response;
        res.ContentType = "application/json";

        try
        {
            var method = req.HttpMethod.ToUpperInvariant();
            var rawPath = req.Url?.AbsolutePath ?? "/";

            // /mcp — raw JSON-RPC passthrough
            if (rawPath == "/mcp" && method == "POST")
            {
                using var sr = new StreamReader(req.InputStream);
                var body = await sr.ReadToEndAsync();
                var doc = JsonDocument.Parse(body);
                var rpcResponse = await HandleRequest(doc);
                var json = rpcResponse != null
                    ? JsonSerializer.Serialize(rpcResponse, JsonOptions)
                    : "{}";
                var bytes = System.Text.Encoding.UTF8.GetBytes(json);
                res.StatusCode = 200;
                await res.OutputStream.WriteAsync(bytes);
                res.OutputStream.Close();
                return;
            }

            // Route-based tool dispatch
            foreach (var (name, tool) in _tools)
            {
                if (tool.Route == null) continue;
                if (!string.Equals(tool.Route.Method, method, StringComparison.OrdinalIgnoreCase)) continue;

                var pathParams = MatchRoutePath(tool.Route.Path, rawPath);
                if (pathParams == null) continue;

                var args = new Dictionary<string, JsonElement>();

                // Merge path params
                foreach (var (k, v) in pathParams)
                    args[k] = JsonDocument.Parse(JsonSerializer.Serialize(v)).RootElement.Clone();

                if (method == "GET")
                {
                    // Merge query params
                    foreach (string? key in req.QueryString.Keys)
                    {
                        if (key == null) continue;
                        var val = req.QueryString[key] ?? "";
                        args[key] = JsonDocument.Parse(JsonSerializer.Serialize(val)).RootElement.Clone();
                    }
                }
                else
                {
                    // Merge JSON body
                    using var sr = new StreamReader(req.InputStream);
                    var body = await sr.ReadToEndAsync();
                    if (!string.IsNullOrWhiteSpace(body))
                    {
                        try
                        {
                            var bodyDoc = JsonDocument.Parse(body);
                            if (bodyDoc.RootElement.ValueKind == JsonValueKind.Object)
                            {
                                foreach (var prop in bodyDoc.RootElement.EnumerateObject())
                                    args[prop.Name] = prop.Value.Clone();
                            }
                        }
                        catch { /* ignore malformed body */ }
                    }
                }

                try
                {
                    var toolCtx = new ToolContext { ToolName = name, Permissions = tool.Permissions };
                    var result = await tool.Execute!(args, toolCtx);
                    var json = JsonSerializer.Serialize(new { ok = true, result }, JsonOptions);
                    var bytes = System.Text.Encoding.UTF8.GetBytes(json);
                    res.StatusCode = 200;
                    await res.OutputStream.WriteAsync(bytes);
                }
                catch (Exception ex)
                {
                    var json = JsonSerializer.Serialize(new { ok = false, error = ex.Message }, JsonOptions);
                    var bytes = System.Text.Encoding.UTF8.GetBytes(json);
                    res.StatusCode = 500;
                    await res.OutputStream.WriteAsync(bytes);
                }

                res.OutputStream.Close();
                return;
            }

            // No match
            var notFound = System.Text.Encoding.UTF8.GetBytes("{\"ok\":false,\"error\":\"Not found\"}");
            res.StatusCode = 404;
            await res.OutputStream.WriteAsync(notFound);
            res.OutputStream.Close();
        }
        catch (Exception ex)
        {
            try
            {
                var errBytes = System.Text.Encoding.UTF8.GetBytes(
                    JsonSerializer.Serialize(new { ok = false, error = ex.Message }));
                res.StatusCode = 500;
                await res.OutputStream.WriteAsync(errBytes);
                res.OutputStream.Close();
            }
            catch { /* socket already closed */ }
        }
    }

    /// <summary>
    /// Match a route pattern with :param segments against an incoming path.
    /// Returns captured parameters or null if no match.
    /// </summary>
    private static Dictionary<string, string>? MatchRoutePath(string pattern, string path)
    {
        var patternSegments = pattern.Split('/', StringSplitOptions.RemoveEmptyEntries);
        var pathSegments = path.Split('/', StringSplitOptions.RemoveEmptyEntries);

        if (patternSegments.Length != pathSegments.Length) return null;

        var captured = new Dictionary<string, string>();
        for (var i = 0; i < patternSegments.Length; i++)
        {
            if (patternSegments[i].StartsWith(':'))
                captured[patternSegments[i][1..]] = pathSegments[i];
            else if (!string.Equals(patternSegments[i], pathSegments[i], StringComparison.OrdinalIgnoreCase))
                return null;
        }

        return captured;
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

        // Notifications (no id)
        if (!hasId)
        {
            HandleNotification(method, paramsEl);
            return null;
        }

        switch (method)
        {
            case "initialize":
                return HandleInitialize(id, paramsEl);

            case "ping":
                return MakeResponse(id, new Dictionary<string, object>());

            // Tools
            case "tools/list":
                return HandleToolsList(id, paramsEl);
            case "tools/call":
                return MakeResponse(id, await CallTool(paramsEl));

            // Resources
            case "resources/list":
                return HandleResourcesList(id, paramsEl);
            case "resources/read":
                return await HandleResourcesRead(id, paramsEl);
            case "resources/subscribe":
                return HandleResourcesSubscribe(id, paramsEl);
            case "resources/templates/list":
                return HandleResourcesTemplatesList(id, paramsEl);

            // Prompts
            case "prompts/list":
                return HandlePromptsList(id, paramsEl);
            case "prompts/get":
                return await HandlePromptsGet(id, paramsEl);

            // Passthrough
            case "logging/setLevel":
                return HandleLoggingSetLevel(id, paramsEl);
            case "completion/complete":
                return HandleCompletionComplete(id);

            default:
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

    // --- Notifications ---

    private void HandleNotification(string method, JsonElement paramsEl)
    {
        switch (method)
        {
            case "notifications/initialized":
                break;
            case "notifications/roots/list_changed":
                // Accept but no action needed in code-registration mode
                break;
        }
    }

    // --- Initialize ---

    private Dictionary<string, object?> HandleInitialize(object? id, JsonElement paramsEl)
    {
        var capabilities = new Dictionary<string, object>
        {
            ["tools"] = new Dictionary<string, object> { ["listChanged"] = true }
        };

        if (_resources.Count > 0 || _templates.Count > 0)
        {
            capabilities["resources"] = new Dictionary<string, object>
            {
                ["subscribe"] = true,
                ["listChanged"] = true
            };
        }

        if (_prompts.Count > 0)
        {
            capabilities["prompts"] = new Dictionary<string, object> { ["listChanged"] = true };
        }

        capabilities["logging"] = new Dictionary<string, object>();

        return MakeResponse(id, new Dictionary<string, object>
        {
            ["protocolVersion"] = "2024-11-05",
            ["capabilities"] = capabilities,
            ["serverInfo"] = new Dictionary<string, object>
            {
                ["name"] = "zeromcp",
                ["version"] = "0.2.0"
            }
        });
    }

    // --- Tools ---

    private Dictionary<string, object?> HandleToolsList(object? id, JsonElement paramsEl)
    {
        var cursor = paramsEl.ValueKind == JsonValueKind.Object &&
                     paramsEl.TryGetProperty("cursor", out var c) ? c.GetString() : null;

        var list = _tools.OrderBy(kv => kv.Key).Select(kv =>
        {
            var entry = new Dictionary<string, object>
            {
                ["name"] = kv.Key,
                ["description"] = kv.Value.Description,
                ["inputSchema"] = kv.Value.CachedSchema!
            };
            if (Icon != null) entry["icons"] = new List<Dictionary<string, string>> { new() { ["uri"] = Icon } };
            return entry;
        }).ToList();

        return MakePagedResponse(id, "tools", list, cursor);
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

        var errors = Schema.Validate(args, tool.CachedSchema!);
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

    // --- Resources ---

    private Dictionary<string, object?> HandleResourcesList(object? id, JsonElement paramsEl)
    {
        var cursor = paramsEl.ValueKind == JsonValueKind.Object &&
                     paramsEl.TryGetProperty("cursor", out var c) ? c.GetString() : null;

        var list = _resources.Values.Select(res =>
        {
            var entry = new Dictionary<string, object>
            {
                ["uri"] = res.Uri,
                ["name"] = res.Name,
                ["mimeType"] = res.MimeType
            };
            if (res.Description != null) entry["description"] = res.Description;
            if (Icon != null) entry["icons"] = new List<Dictionary<string, string>> { new() { ["uri"] = Icon } };
            return entry;
        }).ToList();

        return MakePagedResponse(id, "resources", list, cursor);
    }

    private async Task<Dictionary<string, object?>> HandleResourcesRead(object? id, JsonElement paramsEl)
    {
        var uri = paramsEl.ValueKind == JsonValueKind.Object &&
                  paramsEl.TryGetProperty("uri", out var u) ? u.GetString() ?? "" : "";

        // Check static resources
        foreach (var res in _resources.Values)
        {
            if (res.Uri == uri)
            {
                try
                {
                    var text = await res.Read!();
                    return MakeResponse(id, new Dictionary<string, object>
                    {
                        ["contents"] = new List<Dictionary<string, string>>
                        {
                            new() { ["uri"] = uri, ["mimeType"] = res.MimeType, ["text"] = text }
                        }
                    });
                }
                catch (Exception ex)
                {
                    return MakeError(id, -32603, $"Error reading resource: {ex.Message}");
                }
            }
        }

        // Check templates
        foreach (var tmpl in _templates.Values)
        {
            var match = MatchTemplate(tmpl.UriTemplate, uri);
            if (match != null)
            {
                try
                {
                    var text = await tmpl.Read!(match);
                    return MakeResponse(id, new Dictionary<string, object>
                    {
                        ["contents"] = new List<Dictionary<string, string>>
                        {
                            new() { ["uri"] = uri, ["mimeType"] = tmpl.MimeType, ["text"] = text }
                        }
                    });
                }
                catch (Exception ex)
                {
                    return MakeError(id, -32603, $"Error reading resource: {ex.Message}");
                }
            }
        }

        return MakeError(id, -32002, $"Resource not found: {uri}");
    }

    private Dictionary<string, object?> HandleResourcesSubscribe(object? id, JsonElement paramsEl)
    {
        var uri = paramsEl.ValueKind == JsonValueKind.Object &&
                  paramsEl.TryGetProperty("uri", out var u) ? u.GetString() : null;
        if (uri != null) _subscriptions.Add(uri);
        return MakeResponse(id, new Dictionary<string, object>());
    }

    private Dictionary<string, object?> HandleResourcesTemplatesList(object? id, JsonElement paramsEl)
    {
        var cursor = paramsEl.ValueKind == JsonValueKind.Object &&
                     paramsEl.TryGetProperty("cursor", out var c) ? c.GetString() : null;

        var list = _templates.Values.Select(tmpl =>
        {
            var entry = new Dictionary<string, object>
            {
                ["uriTemplate"] = tmpl.UriTemplate,
                ["name"] = tmpl.Name,
                ["mimeType"] = tmpl.MimeType
            };
            if (tmpl.Description != null) entry["description"] = tmpl.Description;
            if (Icon != null) entry["icons"] = new List<Dictionary<string, string>> { new() { ["uri"] = Icon } };
            return entry;
        }).ToList();

        return MakePagedResponse(id, "resourceTemplates", list, cursor);
    }

    // --- Prompts ---

    private Dictionary<string, object?> HandlePromptsList(object? id, JsonElement paramsEl)
    {
        var cursor = paramsEl.ValueKind == JsonValueKind.Object &&
                     paramsEl.TryGetProperty("cursor", out var c) ? c.GetString() : null;

        var list = _prompts.Values.Select(prompt =>
        {
            var entry = new Dictionary<string, object> { ["name"] = prompt.Name };
            if (prompt.Description != null) entry["description"] = prompt.Description;
            if (prompt.Arguments != null)
            {
                entry["arguments"] = prompt.Arguments.Select(a =>
                {
                    var arg = new Dictionary<string, object> { ["name"] = a.Name };
                    if (a.Description != null) arg["description"] = a.Description;
                    arg["required"] = a.Required;
                    return arg;
                }).ToList();
            }
            if (Icon != null) entry["icons"] = new List<Dictionary<string, string>> { new() { ["uri"] = Icon } };
            return entry;
        }).ToList();

        return MakePagedResponse(id, "prompts", list, cursor);
    }

    private async Task<Dictionary<string, object?>> HandlePromptsGet(object? id, JsonElement paramsEl)
    {
        var name = paramsEl.ValueKind == JsonValueKind.Object &&
                   paramsEl.TryGetProperty("name", out var n) ? n.GetString() ?? "" : "";
        var args = new Dictionary<string, string>();
        if (paramsEl.ValueKind == JsonValueKind.Object &&
            paramsEl.TryGetProperty("arguments", out var argsEl) && argsEl.ValueKind == JsonValueKind.Object)
        {
            foreach (var prop in argsEl.EnumerateObject())
            {
                args[prop.Name] = prop.Value.GetString() ?? "";
            }
        }

        if (!_prompts.TryGetValue(name, out var prompt))
        {
            return MakeError(id, -32002, $"Prompt not found: {name}");
        }

        try
        {
            var messages = await prompt.Render!(args);
            return MakeResponse(id, new Dictionary<string, object> { ["messages"] = messages });
        }
        catch (Exception ex)
        {
            return MakeError(id, -32603, $"Error rendering prompt: {ex.Message}");
        }
    }

    // --- Passthrough ---

    private Dictionary<string, object?> HandleLoggingSetLevel(object? id, JsonElement paramsEl)
    {
        var level = paramsEl.ValueKind == JsonValueKind.Object &&
                    paramsEl.TryGetProperty("level", out var l) ? l.GetString() : null;
        if (level != null) _logLevel = level;
        return MakeResponse(id, new Dictionary<string, object>());
    }

    private Dictionary<string, object?> HandleCompletionComplete(object? id)
    {
        return MakeResponse(id, new Dictionary<string, object>
        {
            ["completion"] = new Dictionary<string, object>
            {
                ["values"] = new List<string>()
            }
        });
    }

    // --- Utilities ---

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

    private static Dictionary<string, object?> MakeError(object? id, int code, string message)
    {
        return new Dictionary<string, object?>
        {
            ["jsonrpc"] = "2.0",
            ["id"] = id,
            ["error"] = new Dictionary<string, object>
            {
                ["code"] = code,
                ["message"] = message
            }
        };
    }

    /// <summary>
    /// Build a paginated list response with base64 cursor.
    /// </summary>
    private Dictionary<string, object?> MakePagedResponse(
        object? id, string key, List<Dictionary<string, object>> items, string? cursor)
    {
        var (slice, nextCursor) = Paginate(items, cursor);
        var result = new Dictionary<string, object> { [key] = slice };
        if (nextCursor != null) result["nextCursor"] = nextCursor;
        return MakeResponse(id, result);
    }

    private (List<Dictionary<string, object>> items, string? nextCursor) Paginate(
        List<Dictionary<string, object>> items, string? cursor)
    {
        if (_pageSize <= 0)
            return (items, null);

        var offset = cursor != null ? DecodeCursor(cursor) : 0;
        var slice = items.Skip(offset).Take(_pageSize).ToList();
        var hasMore = offset + _pageSize < items.Count;
        return (slice, hasMore ? EncodeCursor(offset + _pageSize) : null);
    }

    private static string EncodeCursor(int offset)
    {
        return Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(offset.ToString()));
    }

    private static int DecodeCursor(string cursor)
    {
        try
        {
            var decoded = System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(cursor));
            return int.TryParse(decoded, out var offset) && offset >= 0 ? offset : 0;
        }
        catch
        {
            return 0;
        }
    }

    /// <summary>
    /// Match a URI against a template with {param} placeholders.
    /// Returns the captured parameters or null if no match.
    /// </summary>
    private static Dictionary<string, string>? MatchTemplate(string template, string uri)
    {
        var pattern = System.Text.RegularExpressions.Regex.Replace(
            System.Text.RegularExpressions.Regex.Escape(template),
            @"\\{(\w+)\\}",
            @"(?<$1>[^/]+)");

        var match = System.Text.RegularExpressions.Regex.Match(uri, $"^{pattern}$");
        if (!match.Success) return null;

        var result = new Dictionary<string, string>();
        // Extract named groups from the regex match
        var groupNames = System.Text.RegularExpressions.Regex.Matches(template, @"\{(\w+)\}");
        foreach (System.Text.RegularExpressions.Match g in groupNames)
        {
            var groupName = g.Groups[1].Value;
            var groupValue = match.Groups[groupName].Value;
            if (!string.IsNullOrEmpty(groupValue))
                result[groupName] = groupValue;
        }

        return result.Count > 0 ? result : null;
    }
}
