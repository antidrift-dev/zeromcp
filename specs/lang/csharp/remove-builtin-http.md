# Remove the built-in HTTP server — C#

## Status
Not started. Spec only.

## Why
ZeroMCP doesn't own the HTTP layer. Users run whatever HTTP server they already have and wire ZeroMCP in. `Registry.Create` (routes, OpenAPI, MCP handler as plain data) and `ZeroMcpServer.HandleRequest` already cover that. `ZeroMcpServer.ServeHttp` is the one piece that runs its own `HttpListener` inside the library.

## Remove
- `ZeroMcpServer.ServeHttp(int port = 3000)` and its doc comment (`csharp/ZeroMcp/Server.cs:166-183`): the `HttpListener` on `http://+:{port}/` and the accept loop. Port default 3000 goes with it.
- `HandleHttpContext` (`Server.cs:185-340`): `/mcp` POST passthrough, `/openapi.json`, `/docs` Swagger HTML, route-tagged tool dispatch with query/body merging, 404 and 500 responses. Its only caller is `ServeHttp` (`Server.cs:181`).
- `MatchRoutePath` (`Server.cs:342-363`). Its only caller is `HandleHttpContext` (`Server.cs:262`).
- The `ServeHttp()` mention in the `ContextFactory` doc comment (`Server.cs:23`).
- `csharp/RouteTest/Program.cs:35` (`await server.ServeHttp(14259)`). The project is rewritten as a harness, see Tests.

Not present in C#, nothing to remove: `/health`, CORS, HTTP bearer auth (grep for `cors|bearer|authorization|health|Access-Control` in `csharp/ZeroMcp/*.cs` returns nothing), a CLI (no `bin/` or entry point in `csharp/ZeroMcp`), and HTTP-only dependencies (`ZeroMcp.csproj` has no `PackageReference`; `HttpListener` is BCL).

## Keep
- `Serve()` (stdio, `Server.cs:118`), `HandleRequest` (`Server.cs:373`), `Registry.Create` (`csharp/ZeroMcp/Registry.cs:31-52`).
- `BuildOpenApiSpec()` and `BuildOpenApiPropertySchema` (`Server.cs:885-998`), staying in `ZeroMcpServer` as `internal`. `Registry.Create` calls it (`Registry.cs:49`).
- `ContextFactory` (`Server.cs:26`), used by `CallTool` (`Server.cs:550`) and set by `Registry.Create` (`Registry.cs:35`).
- README "HTTP / Streamable HTTP" section (`csharp/README.md:41-69`). It already documents `HandleRequest` in ASP.NET Minimal API, not `ServeHttp`. Switch the example to `Registry.Create` so it shows `registry.Routes` and `registry.OpenApi` as well as `/mcp`.

## Config: fail on an `http` transport
`ZeroMcpConfig` (`csharp/ZeroMcp/Config.cs:6-27`) has no `transport` key. Today a config with `"transport":[{"type":"http","port":4242}]` loads without error and the key is dropped: checked by loading such a file with `ZeroMcpConfig.Load` against the current source (`dotnet run`, printed `title=T` with no error). `Serve()` then starts stdio. That is the silent fallback the decision rules out.

- Add `[JsonPropertyName("transport")] public JsonElement? Transport { get; set; }` to `ZeroMcpConfig`.
- At the top of `Serve()`, before the startup log lines (`Server.cs:120-121`): if `Transport` is an object, or an array containing an object, whose `type` is `"http"`, throw `InvalidOperationException` with: `zeromcp: the built-in HTTP transport was removed. Mount Registry.Create(tools) (Routes, OpenApi, Mcp) or ZeroMcpServer.HandleRequest in your own HTTP server.` Any other `transport` value (absent, `stdio`) runs stdio as now.
- The check goes in `Serve()`, not `ZeroMcpConfig.Load`: `Load` catches every exception and returns an empty config (`Config.cs:43-46`), so a throw there would be swallowed. It also keeps `Registry.Create`, which builds a `ZeroMcpServer` that loads config from the working directory (`Server.cs:37`, `Registry.cs:35`), from failing on it.

## Breaking change
`ServeHttp` is in the published NuGet package `Antidrift.ZeroMcp` 0.3.0: the NuGet flat container lists 0.1.0, 0.2.0, 0.2.2, 0.3.0, and the `ZeroMcp.dll` in the 0.3.0 nupkg contains `ServeHttp` and `HandleHttpContext`. Removing it breaks anyone who calls it. Note it in the next release's changelog with the one-line replacement: mount `Registry.Create(tools)` in your own server.

## Tests
- Unit tests: nothing in `csharp/ZeroMcp.Tests/` calls `ServeHttp`, `HandleHttpContext` or `MatchRoutePath` (grep returns nothing). Nothing to delete or move. OpenAPI stays covered by `RegistryTests.cs:56-67`.
- Add one test: a `ZeroMcpServer` built with `Transport` set to `[{"type":"http"}]` makes `Serve()` throw `InvalidOperationException` whose message names `Registry.Create`.
- Route conformance: the C# entry (`tests/conformance/run-route.js:90-96`) runs `RouteTest` on port 14259, built by `Dockerfile:119`. Rewrite `csharp/RouteTest/Program.cs` as a test-only harness: same `greet` and `echo` tools, passed to `Registry.Create`, mounted on a BCL `HttpListener` on 14259 that serves:
  - each `registry.Routes` entry, with its own `:param` matching and query/body merging, returning `{ok, result}`, the shape `run-route.js:146-158` asserts;
  - `GET /openapi.json` from `registry.OpenApi`;
  - `POST /mcp` through `registry.Mcp`;
  - `GET /docs`, a static Swagger UI page (`run-route.js:172-176` checks for "swagger"). This tests the harness only.

  Same project name, port and output path, so `Dockerfile:119` and `run-route.js` need no change. No new dependencies.
- Chaos (`tests/chaos/run-chaos.js:442-444`, `ChaosTest`) and performance (`tests/performance/run-mixed-docker.mjs:129-131`, `run-mixed-all.mjs:133-136`, `ResourceTest`) run C# over stdio (`ChaosTest/Program.cs:56`, `ResourceTest/Program.cs:73` call `Serve()`). No change. C# has no entry in `tests/conformance/run-http.js` and no `http-config-*.json` or `route-config-*.json` file.

## Verify
```sh
docker build -t zeromcp-tests .
docker run --rm zeromcp-tests sh -c 'cd csharp && dotnet test ZeroMcp.Tests/ZeroMcp.Tests.csproj'
docker run --rm zeromcp-tests node tests/conformance/run-all.js --language "C#"
docker run --rm zeromcp-tests node tests/conformance/run-route.js
grep -rn -E 'HttpListener|ServeHttp|MatchRoutePath|swagger' csharp/ZeroMcp   # expect nothing
```
Baseline: 3 `TemplateTests` failures already exist on `main` (`specs/lang/csharp/node-parity.md:215`) and are not part of this work.
