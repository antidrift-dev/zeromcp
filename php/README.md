# ZeroMCP &mdash; PHP

Drop a `.php` file in a folder, get a sandboxed MCP server. Stdio out of the box, zero dependencies.

## Getting started

```php
<?php
// tools/hello.php — this is a complete MCP server
return [
    'description' => 'Say hello to someone',
    'input' => ['name' => 'string'],
    'execute' => function ($args, $ctx) {
        return "Hello, {$args['name']}!";
    },
];
```

```sh
php zeromcp.php serve ./tools
```

That's it. Stdio works immediately. Drop another `.php` file to add another tool. Delete a file to remove one.

## vs. the official SDK

The official PHP SDK (backed by The PHP Foundation) requires Composer, server setup, transport configuration, and explicit tool registration. ZeroMCP is file-based &mdash; each tool is its own file, discovered automatically. Pure PHP, no Composer, no extensions.

In benchmarks, ZeroMCP PHP handles 13,333 requests/second over stdio versus the official SDK's 18 &mdash; 740x faster. Over HTTP (Slim), ZeroMCP serves 1,561 rps at 11-33 MB versus the official SDK's 17 rps at 31-64 MB. The official SDK takes 54ms per request. ZeroMCP takes 0.53ms. The official SDK corrupted responses on giant strings and slow tools in chaos testing. ZeroMCP survived 22/22 attacks.

The official SDK has **no sandbox**. ZeroMCP lets tools declare network, filesystem, and exec permissions.

PHP passes all 10 conformance suites.

## HTTP / Streamable HTTP

ZeroMCP doesn't own the HTTP layer and ships no HTTP server. You bring your own framework; ZeroMCP gives you the pieces as plain data:

- `ZeroMcp\Registry::create($tools)` returns `->routes` (one `RouteDefinition` per tool that declares a `route`), `->openapi` (an OpenAPI 3.0 array) and `->mcp($request)` (the JSON-RPC handler: takes an associative array, returns an array, or `null` for notifications).
- `Server::handleRequest($request)` is the same JSON-RPC handler for a config-driven server (`new Server($config)` then `->loadTools()`).

A config with `"transport": [{"type": "http"}]` now fails at startup with an error pointing here, and the old `zeromcp.php http` command exits 1.

**Slim**

```php
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Slim\Factory\AppFactory;
use ZeroMcp\Config;
use ZeroMcp\Registry;
use ZeroMcp\Scanner;

// Tools from a directory (or build ZeroMcp\Tool objects / definition arrays in code).
$tools = (new Scanner(new Config(['tools' => __DIR__ . '/tools'])))->scan();
$registry = Registry::create($tools);

$app = AppFactory::create();

$json = function (Response $res, mixed $data, int $status = 200): Response {
    $res->getBody()->write(json_encode($data, JSON_UNESCAPED_SLASHES));
    return $res->withHeader('Content-Type', 'application/json')->withStatus($status);
};

// MCP over HTTP
$app->post('/mcp', function (Request $req, Response $res) use ($registry, $json) {
    $response = $registry->mcp(json_decode((string) $req->getBody(), true) ?? []);
    return $response === null ? $res->withStatus(204) : $json($res, $response);
});

// OpenAPI document
$app->get('/openapi.json', fn(Request $req, Response $res) => $json($res, $registry->openapi));

// One REST route per tool that declares `route` (Slim uses {param}, tools use :param)
foreach ($registry->routes as $route) {
    $path = preg_replace('/:([a-zA-Z_]\w*)/', '{$1}', $route->path);
    $app->map([$route->method], $path, function (Request $req, Response $res, array $params) use ($route, $json) {
        $args = $route->method === 'GET'
            ? array_merge($req->getQueryParams(), $params)
            : array_merge(json_decode((string) $req->getBody(), true) ?? [], $params);
        try {
            return $json($res, ['ok' => true, 'result' => $route->tool->call($args)]);
        } catch (\Throwable $e) {
            return $json($res, ['ok' => false, 'error' => $e->getMessage()], 500);
        }
    });
}

$app->run();
```

`Registry::create()` options:

- `get_env` — callable whose return value becomes `$ctx->credentials` on every call.
- `config` — a `Config` for title, timeouts, page size and so on (default: in-memory defaults, nothing read from disk).
- `remote` — remote MCP servers to federate (see below). Their tools are reachable through `->mcp()` but never appear in `->routes` or `->openapi`. The HTTP calls block, so `create()` stays synchronous.

## Remote servers

Pull another MCP server's tools in over HTTP. Each remote tool is exposed as `<name>.<tool>`:

```json
{
  "tools": "./tools",
  "remote": [
    { "name": "probeo", "url": "https://mcp.example.com/mcp", "auth": "env:PROBEO_TOKEN", "tools": ["list_pages"] }
  ]
}
```

- `auth` is sent as `Authorization: Bearer <value>`; `env:VAR` reads it from the environment.
- `tools` is an optional allowlist of upstream tool names; omit it to expose everything.
- A server that can't be reached, isn't `http(s)://`, or returns a non-2xx status is logged and skipped.
- A local tool with the same name overrides the remote one.

`remote` works for `zeromcp.php serve`, for `new Server($config)` + `loadTools()`, and for `Registry::create($tools, ['remote' => [...]])`.

## Runtime context

Pass a `get_runtime` callable to the `Server` and its return value lands on `$ctx->runtime` for every tool call (it is called once per call; when it returns `null`, `$ctx->runtime` stays `null`):

```php
$server = new ZeroMcp\Server($config, ['get_runtime' => fn() => ['db' => $pdo, 'user' => $currentUser]]);
$server->loadTools();
$response = $server->handleRequest($request);
```

```php
// tools/whoami.php
return [
    'execute' => fn($args, $ctx) => $ctx->runtime['user'],
];
```

## Hot reload

With `"autoload_tools": true`, `zeromcp.php serve` polls the tool directories about once a second. When a tool file is added, changed or removed it logs `[zeromcp] Change detected: <file>`, rescans, and sends `notifications/tools/list_changed`. Tools whose files were deleted stay registered until restart (same as the Node implementation).

## Requirements

- PHP CLI (no extensions required)

## Sandbox

```php
<?php
return [
    'description' => 'Fetch from our API',
    'input' => ['url' => 'string'],
    'permissions' => [
        'network' => ['api.example.com', '*.internal.dev'],
        'fs' => false,
        'exec' => false,
    ],
    'execute' => function ($args, $ctx) {
        // ...
    },
];
```

## Directory structure

Tools are discovered recursively. Subdirectory names become namespace prefixes:

```
tools/
  hello.php          -> tool "hello"
  math/
    add.php          -> tool "math_add"
```

Rename or drop a directory prefix with `namespacing`, and prefix a whole tool source with `{path, prefix}`:

```json
{
  "tools": ["./tools", { "path": "./vendor-tools", "prefix": "vendor" }],
  "namespacing": { "math": { "prefix": "m" } }
}
```

Here `tools/math/add.php` becomes `m_add` (an empty `prefix` gives plain `add`) and `vendor-tools/search.php` becomes `vendor_search`. Both joins use `separator`. Credentials stay keyed by the directory name (`"credentials": {"math": {...}}`), whatever the tool ends up being called.

## Testing

```sh
for f in tests/*Test.php; do php "$f"; done
```
