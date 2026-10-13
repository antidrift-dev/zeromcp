using System.Text.Json;
using System.Text.Json.Serialization;

namespace ZeroMcp;

/// <summary>A remote MCP server whose tools are federated as "&lt;Name&gt;.&lt;tool&gt;".</summary>
public class RemoteServer
{
    [JsonPropertyName("name")]
    public string Name { get; set; } = "";

    [JsonPropertyName("url")]
    public string Url { get; set; } = "";

    /// <summary>Bearer token: "env:VAR" reads the environment variable, anything else is sent literally.</summary>
    [JsonPropertyName("auth")]
    public string? Auth { get; set; }

    /// <summary>Upstream tool names to expose. Null exposes the entire remote surface.</summary>
    [JsonPropertyName("tools")]
    public List<string>? Tools { get; set; }
}

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

    [JsonPropertyName("title")]
    public string? Title { get; set; }

    [JsonPropertyName("remote")]
    public List<RemoteServer>? Remote { get; set; }

    [JsonPropertyName("page_size")]
    public int? PageSize { get; set; } // 0 = no pagination (default)

    /// <summary>URL, file path, or data URI, applied to all tools/resources/prompts.</summary>
    [JsonPropertyName("icon")]
    public string? Icon { get; set; }

    /// <summary>
    /// Read only to reject an "http" transport at Serve(): the built-in HTTP server was removed.
    /// </summary>
    [JsonPropertyName("transport")]
    public JsonElement? Transport { get; set; }

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

    /// <summary>"env:VAR" resolves to the environment variable (warning if unset); anything else is literal.</summary>
    internal static string? ResolveAuth(string? auth)
    {
        if (string.IsNullOrEmpty(auth)) return null;

        if (auth.StartsWith("env:"))
        {
            var envVar = auth[4..];
            var value = Environment.GetEnvironmentVariable(envVar);
            if (string.IsNullOrEmpty(value))
            {
                Console.Error.WriteLine($"[zeromcp] Warning: environment variable {envVar} not set");
            }
            return value;
        }

        return auth;
    }

    private static readonly Dictionary<string, string> IconMime = new()
    {
        [".png"] = "image/png",
        [".jpg"] = "image/jpeg",
        [".jpeg"] = "image/jpeg",
        [".gif"] = "image/gif",
        [".svg"] = "image/svg+xml",
        [".ico"] = "image/x-icon",
        [".webp"] = "image/webp",
    };

    private static readonly HttpClient IconHttp = new();

    /// <summary>
    /// Resolve an icon config value to a data URI.
    /// Accepts: data URI (passthrough), URL (fetched), file path (read).
    /// </summary>
    internal static async Task<string?> ResolveIcon(string? icon)
    {
        if (string.IsNullOrEmpty(icon)) return null;

        // Already a data URI
        if (icon.StartsWith("data:")) return icon;

        // URL: fetch and convert
        if (icon.StartsWith("http://") || icon.StartsWith("https://"))
        {
            try
            {
                using var res = await IconHttp.GetAsync(icon);
                if (!res.IsSuccessStatusCode)
                {
                    Console.Error.WriteLine($"[zeromcp] Warning: failed to fetch icon {icon}: {(int)res.StatusCode}");
                    return null;
                }
                var contentType = res.Content.Headers.ContentType?.ToString();
                if (string.IsNullOrEmpty(contentType)) contentType = "image/png";
                var buf = await res.Content.ReadAsByteArrayAsync();
                return $"data:{contentType};base64,{Convert.ToBase64String(buf)}";
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine($"[zeromcp] Warning: failed to fetch icon {icon}: {ex.Message}");
                return null;
            }
        }

        // File path: read and convert
        try
        {
            var path = icon.StartsWith('~')
                ? (Environment.GetEnvironmentVariable("HOME") ?? "") + icon[1..]
                : icon;
            var buf = await File.ReadAllBytesAsync(path);
            var ext = Path.GetExtension(path).ToLowerInvariant();
            var mime = IconMime.TryGetValue(ext, out var m) ? m : "image/png";
            return $"data:{mime};base64,{Convert.ToBase64String(buf)}";
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"[zeromcp] Warning: failed to read icon file {icon}: {ex.Message}");
            return null;
        }
    }
}
