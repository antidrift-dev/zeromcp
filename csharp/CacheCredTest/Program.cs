using System.Text.Json;
using ZeroMcp;

var configPath = Environment.GetEnvironmentVariable("ZEROMCP_CONFIG") ?? "zeromcp.config.json";

// Parse config to get credentials.tokenstore.file and cache_credentials.
var credFile = "";
var cacheCredentials = true;
try
{
    var text = File.ReadAllText(configPath);
    var cfg = JsonDocument.Parse(text).RootElement;
    if (cfg.TryGetProperty("credentials", out var creds) &&
        creds.TryGetProperty("tokenstore", out var tokenstore) &&
        tokenstore.TryGetProperty("file", out var fileEl))
    {
        credFile = fileEl.GetString() ?? "";
    }
    if (cfg.TryGetProperty("cache_credentials", out var flagEl))
    {
        cacheCredentials = flagEl.GetBoolean();
    }
}
catch { }

string? ReadTokenFromFile(string path)
{
    try
    {
        var text = File.ReadAllText(path);
        var doc = JsonDocument.Parse(text).RootElement;
        return doc.TryGetProperty("token", out var t) ? t.GetString() : null;
    }
    catch { return null; }
}

var server = new ZeroMcpServer();
string? cachedToken = null;
var tokenCached = false;

server.Tool("tokenstore_check", new ToolDefinition
{
    Description = "Return the current token from credentials",
    Execute = async (args, ctx) =>
    {
        string? token;
        if (cacheCredentials)
        {
            if (!tokenCached) { cachedToken = ReadTokenFromFile(credFile); tokenCached = true; }
            token = cachedToken;
        }
        else
        {
            token = ReadTokenFromFile(credFile);
        }
        return new { token };
    }
});

await server.Serve();
