<?php
/**
 * Route conformance harness for PHP. ZeroMCP ships no HTTP server, so this
 * test-only router mounts ZeroMcp\Registry under `php -S`:
 *
 *   php -S 127.0.0.1:14253 tests/conformance/route-harness-php.php
 */

if (!defined('STDERR')) {
    define('STDERR', fopen('php://stderr', 'w'));
}

$src = __DIR__ . '/../../php/src';
foreach (['Log', 'Schema', 'Config', 'Tool', 'Resource', 'Prompt', 'Sandbox', 'Scanner', 'RemoteManager', 'Server', 'Registry'] as $f) {
    require_once "$src/$f.php";
}

use ZeroMcp\Config;
use ZeroMcp\Registry;
use ZeroMcp\Scanner;

function respond(int $status, string $contentType, string $body): void
{
    http_response_code($status);
    header("Content-Type: $contentType");
    echo $body;
}

function respondJson(int $status, mixed $data): void
{
    respond($status, 'application/json', json_encode($data, JSON_UNESCAPED_SLASHES));
}

/** @return array<string,string>|null */
function matchRoute(string $pattern, string $path): ?array
{
    // Split on :param first; preg_quote() escapes ':' so it can't run before the substitution.
    $parts = preg_split('/:([a-zA-Z_][a-zA-Z0-9_]*)/', $pattern, -1, PREG_SPLIT_DELIM_CAPTURE);
    $regex = '';
    foreach ($parts as $i => $part) {
        $regex .= $i % 2 === 0 ? preg_quote($part, '#') : '(?P<' . $part . '>[^/]+)';
    }
    if (!preg_match('#^' . $regex . '$#', $path, $matches)) return null;
    return array_filter($matches, 'is_string', ARRAY_FILTER_USE_KEY);
}

$tools = (new Scanner(new Config(['tools' => __DIR__ . '/route-tools'])))->scan();
$registry = Registry::create($tools);

$method = strtoupper($_SERVER['REQUEST_METHOD'] ?? 'GET');
$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';

if ($method === 'GET' && $path === '/health') {
    respondJson(200, ['status' => 'ok']);
    return true;
}

if ($method === 'POST' && $path === '/mcp') {
    $request = json_decode(file_get_contents('php://input'), true);
    if (!is_array($request)) {
        respondJson(400, ['error' => 'Invalid JSON-RPC request']);
        return true;
    }
    $response = $registry->mcp($request);
    if ($response === null) {
        http_response_code(204);
        return true;
    }
    respondJson(200, $response);
    return true;
}

if ($method === 'GET' && $path === '/openapi.json') {
    respondJson(200, $registry->openapi);
    return true;
}

if ($method === 'GET' && $path === '/docs') {
    respond(200, 'text/html; charset=utf-8', <<<'HTML'
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
HTML);
    return true;
}

foreach ($registry->routes as $route) {
    if ($route->method !== $method) continue;
    $pathParams = matchRoute($route->path, $path);
    if ($pathParams === null) continue;

    if ($method === 'GET') {
        $args = array_merge($_GET, $pathParams);
    } else {
        $body = json_decode(file_get_contents('php://input'), true);
        $args = array_merge(is_array($body) ? $body : [], $pathParams);
    }

    try {
        respondJson(200, ['ok' => true, 'result' => $route->tool->call($args)]);
    } catch (\Throwable $e) {
        respondJson(500, ['ok' => false, 'error' => $e->getMessage()]);
    }
    return true;
}

respondJson(404, ['error' => 'Not found']);
return true;
