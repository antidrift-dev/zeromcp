// Route conformance harness (test-only). ZeroMCP ships no HTTP server: this mounts
// Registry.Create's Routes, OpenApi and Mcp on a BCL HttpListener, the way a user
// would in their own framework. Port 14259 is what tests/conformance/run-route.js expects.
using System.Net;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using ZeroMcp;

var registry = Registry.Create(new Dictionary<string, ToolDefinition>
{
    ["greet"] = new ToolDefinition
    {
        Description = "Greet a person by name",
        Input = new Dictionary<string, InputField>
        {
            ["name"] = new InputField(SimpleType.String)
        },
        Route = new ToolRoute { Method = "GET", Path = "/greet/:name" },
        Execute = (args, ctx) =>
        {
            var name = args["name"].GetString() ?? "world";
            return Task.FromResult<object>($"Hello, {name}!");
        }
    },
    ["echo"] = new ToolDefinition
    {
        Description = "Echo a message back",
        Input = new Dictionary<string, InputField>
        {
            ["message"] = new InputField(SimpleType.String)
        },
        Route = new ToolRoute { Method = "POST", Path = "/echo" },
        Execute = (args, ctx) =>
        {
            var message = args["message"].GetString();
            return Task.FromResult<object>(new { message, echoed = true });
        }
    }
});

var json = new JsonSerializerOptions
{
    PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
};

const string DocsHtml = """
<!DOCTYPE html>
<html>
<head>
  <title>ZeroMCP API</title>
  <meta charset="utf-8"/>
  <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist/swagger-ui.css">
</head>
<body>
<div id="swagger-ui"></div>
<script src="https://unpkg.com/swagger-ui-dist/swagger-ui-bundle.js"></script>
<script>SwaggerUIBundle({ url: '/openapi.json', dom_id: '#swagger-ui' })</script>
</body>
</html>
""";

var listener = new HttpListener();
listener.Prefixes.Add("http://+:14259/");
listener.Start();
Console.Error.WriteLine("[RouteTest] listening on 14259");

while (true)
{
    var ctx = await listener.GetContextAsync();
    _ = Handle(ctx);
}

async Task Handle(HttpListenerContext ctx)
{
    var req = ctx.Request;
    var res = ctx.Response;
    try
    {
        var method = req.HttpMethod.ToUpperInvariant();
        var path = req.Url?.AbsolutePath ?? "/";

        if (path == "/mcp" && method == "POST")
        {
            var doc = await JsonDocument.ParseAsync(req.InputStream);
            var rpc = await registry.Mcp(doc);
            await Write(res, 200, "application/json", rpc != null ? JsonSerializer.Serialize(rpc, json) : "{}");
            return;
        }

        if (path == "/openapi.json" && method == "GET")
        {
            await Write(res, 200, "application/json", JsonSerializer.Serialize(registry.OpenApi, json));
            return;
        }

        if (path == "/docs" && method == "GET")
        {
            await Write(res, 200, "text/html", DocsHtml);
            return;
        }

        foreach (var route in registry.Routes)
        {
            if (!string.Equals(route.Method, method, StringComparison.OrdinalIgnoreCase)) continue;
            var pathParams = MatchRoute(route.Path, path);
            if (pathParams == null) continue;

            var args = new Dictionary<string, JsonElement>();
            foreach (var (k, v) in pathParams) args[k] = JsonSerializer.SerializeToElement(v);

            if (method == "GET")
            {
                foreach (string? key in req.QueryString.Keys)
                {
                    if (key == null) continue;
                    args[key] = JsonSerializer.SerializeToElement(req.QueryString[key] ?? "");
                }
            }
            else
            {
                using var sr = new StreamReader(req.InputStream);
                var body = await sr.ReadToEndAsync();
                if (!string.IsNullOrWhiteSpace(body))
                {
                    try
                    {
                        using var bodyDoc = JsonDocument.Parse(body);
                        if (bodyDoc.RootElement.ValueKind == JsonValueKind.Object)
                            foreach (var prop in bodyDoc.RootElement.EnumerateObject())
                                args[prop.Name] = prop.Value.Clone();
                    }
                    catch { /* ignore malformed body */ }
                }
            }

            try
            {
                var toolCtx = new ToolContext { ToolName = route.Name, Permissions = route.Tool.Permissions };
                var result = await route.Tool.Execute!(args, toolCtx);
                await Write(res, 200, "application/json", JsonSerializer.Serialize(new { ok = true, result }, json));
            }
            catch (Exception ex)
            {
                await Write(res, 500, "application/json", JsonSerializer.Serialize(new { ok = false, error = ex.Message }, json));
            }
            return;
        }

        await Write(res, 404, "application/json", "{\"ok\":false,\"error\":\"Not found\"}");
    }
    catch (Exception ex)
    {
        try { await Write(res, 500, "application/json", JsonSerializer.Serialize(new { ok = false, error = ex.Message })); }
        catch { /* socket already closed */ }
    }
}

static async Task Write(HttpListenerResponse res, int status, string contentType, string body)
{
    var bytes = Encoding.UTF8.GetBytes(body);
    res.StatusCode = status;
    res.ContentType = contentType;
    await res.OutputStream.WriteAsync(bytes);
    res.OutputStream.Close();
}

static Dictionary<string, string>? MatchRoute(string pattern, string path)
{
    var patternSegments = pattern.Split('/', StringSplitOptions.RemoveEmptyEntries);
    var pathSegments = path.Split('/', StringSplitOptions.RemoveEmptyEntries);
    if (patternSegments.Length != pathSegments.Length) return null;

    var captured = new Dictionary<string, string>();
    for (var i = 0; i < patternSegments.Length; i++)
    {
        if (patternSegments[i].StartsWith(':'))
            captured[patternSegments[i][1..]] = Uri.UnescapeDataString(pathSegments[i]);
        else if (!string.Equals(patternSegments[i], pathSegments[i], StringComparison.OrdinalIgnoreCase))
            return null;
    }
    return captured;
}
