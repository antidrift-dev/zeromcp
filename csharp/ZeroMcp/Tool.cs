using System.Text.Json;

namespace ZeroMcp;

public class Permissions
{
    public object? Network { get; set; } // bool, string[], or null
    public object? Fs { get; set; } // bool, "read", "write", or null
    public bool Exec { get; set; }
}

public class ToolContext
{
    public string ToolName { get; set; } = "";
    public object? Credentials { get; set; }
}

public class ToolDefinition
{
    public string Description { get; set; } = "";
    public Dictionary<string, InputField> Input { get; set; } = new();
    public Permissions? Permissions { get; set; }
    public Func<Dictionary<string, JsonElement>, ToolContext, Task<object>>? Execute { get; set; }
}
