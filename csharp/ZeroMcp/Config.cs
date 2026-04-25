using System.Text.Json;
using System.Text.Json.Serialization;

namespace ZeroMcp;

public class ZeroMcpConfig
{
    [JsonPropertyName("tools")]
    public string? Tools { get; set; }

    [JsonPropertyName("separator")]
    public string? Separator { get; set; }

    [JsonPropertyName("logging")]
    public bool? Logging { get; set; }

    [JsonPropertyName("bypass_permissions")]
    public bool? BypassPermissions { get; set; }

    [JsonPropertyName("execute_timeout")]
    public int? ExecuteTimeout { get; set; } // ms, default 30000

    [JsonPropertyName("cache_credentials")]
    public bool? CacheCredentials { get; set; } = true; // default true

    public static ZeroMcpConfig Load(string? path = null)
    {
        path ??= Path.Combine(Directory.GetCurrentDirectory(), "zeromcp.config.json");

        if (!File.Exists(path))
        {
            return new ZeroMcpConfig();
        }

        try
        {
            var json = File.ReadAllText(path);
            return JsonSerializer.Deserialize<ZeroMcpConfig>(json) ?? new ZeroMcpConfig();
        }
        catch
        {
            return new ZeroMcpConfig();
        }
    }
}
