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

The official SDK has **no sandbox**. ZeroMCP lets tools declare network, filesystem, and exec permissions.

## HTTP / Streamable HTTP

ZeroMCP doesn't own the HTTP layer. You bring your own framework; ZeroMCP gives you a `handleRequest` method that takes an associative array and returns an array (or `null` for notifications).

```php
// $response = $server->handleRequest($request);
```

**Slim**

```php
use Psr\Http\Message\ResponseInterface as Response;
use Psr\Http\Message\ServerRequestInterface as Request;
use Slim\Factory\AppFactory;

$app = AppFactory::create();

$app->post('/mcp', function (Request $req, Response $res) use ($server) {
    $body = json_decode((string) $req->getBody(), true);
    $response = $server->handleRequest($body);

    if ($response === null) {
        return $res->withStatus(204);
    }
    $res->getBody()->write(json_encode($response));
    return $res->withHeader('Content-Type', 'application/json');
});

$app->run();
```

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

## Testing

```sh
php tests/run.php
```
