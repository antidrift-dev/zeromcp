using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace ZeroMcp.Tests;

/// <summary>
/// A minimal upstream MCP server over HTTP JSON-RPC, the same as the stub in
/// nodejs/test/handler-remote.test.js: answers initialize, tools/list and tools/call,
/// echoing the request id.
/// </summary>
public sealed class StubMcpServer : IDisposable
{
    public const string DefaultTools = """
    [
      { "name": "list_pages", "description": "Lists pages.", "inputSchema": { "type": "object", "properties": { "domain": { "type": "string" } }, "required": ["domain"] } },
      { "name": "get_page", "description": "Gets a page.", "inputSchema": { "type": "object", "properties": { "url": { "type": "string" } }, "required": ["url"] } }
    ]
    """;

    public const string CallText = "{\"pages\":[]}";

    private readonly HttpListener _listener = new();
    private readonly string _toolsJson;
    private readonly int _status;
    private int _initializeHits;

    public string Url { get; }
    public int InitializeHits => _initializeHits;
    public ConcurrentQueue<string?> AuthHeaders { get; } = new();
    public ConcurrentQueue<JsonElement> Calls { get; } = new();

    public StubMcpServer(string toolsJson = DefaultTools, int status = 200)
    {
        _toolsJson = toolsJson;
        _status = status;
        var port = FreePort();
        Url = $"http://127.0.0.1:{port}/";
        _listener.Prefixes.Add(Url);
        _listener.Start();
        _ = Loop();
    }

    private static int FreePort()
    {
        var l = new TcpListener(IPAddress.Loopback, 0);
        l.Start();
        var port = ((IPEndPoint)l.LocalEndpoint).Port;
        l.Stop();
        return port;
    }

    private async Task Loop()
    {
        while (_listener.IsListening)
        {
            HttpListenerContext ctx;
            try { ctx = await _listener.GetContextAsync(); }
            catch { return; }
            _ = Handle(ctx);
        }
    }

    private async Task Handle(HttpListenerContext ctx)
    {
        AuthHeaders.Enqueue(ctx.Request.Headers["Authorization"]);
        using var doc = await JsonDocument.ParseAsync(ctx.Request.InputStream);
        var root = doc.RootElement;
        var method = root.GetProperty("method").GetString();
        var id = root.GetProperty("id").GetRawText();
        if (method == "initialize") Interlocked.Increment(ref _initializeHits);

        string body;
        if (_status != 200)
        {
            body = "{}";
        }
        else
        {
            var result = method switch
            {
                "initialize" => """{"protocolVersion":"2025-03-26","capabilities":{},"serverInfo":{"name":"probeo","version":"test"}}""",
                "tools/list" => "{\"tools\":" + _toolsJson + "}",
                "tools/call" => "{\"content\":[{\"type\":\"text\",\"text\":" + JsonSerializer.Serialize(CallText) + "}]}",
                _ => null
            };
            if (method == "tools/call") Calls.Enqueue(root.GetProperty("params").Clone());
            body = result != null
                ? "{\"jsonrpc\":\"2.0\",\"id\":" + id + ",\"result\":" + result + "}"
                : "{\"jsonrpc\":\"2.0\",\"id\":" + id + ",\"error\":{\"message\":\"Unexpected method: " + method + "\"}}";
        }

        var bytes = Encoding.UTF8.GetBytes(body);
        ctx.Response.StatusCode = _status;
        ctx.Response.ContentType = "application/json";
        await ctx.Response.OutputStream.WriteAsync(bytes);
        ctx.Response.Close();
    }

    public void Dispose()
    {
        try { _listener.Stop(); _listener.Close(); } catch { }
    }
}

/// <summary>Captures Console.Error for the duration of a test. Tests using it run serially (see collection).</summary>
public sealed class StderrCapture : IDisposable
{
    private readonly TextWriter _original;
    private readonly StringWriter _writer = new();

    public StderrCapture()
    {
        _original = Console.Error;
        Console.SetError(TextWriter.Synchronized(_writer));
    }

    public string Text => _writer.ToString();

    public void Dispose() => Console.SetError(_original);
}

[Xunit.CollectionDefinition("Stderr", DisableParallelization = true)]
public class StderrCollection { }
