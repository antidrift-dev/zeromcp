<?php
// Fake upstream MCP server for RemoteTest/RegistryTest, run under `php -S`.
// Same canned responses as nodejs/test/handler-remote.test.js:6-17.
//   POST /           — normal upstream
//   POST /echo-auth  — tools/call returns the Authorization header it received
//   POST /fail       — always HTTP 500

$path = parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?: '/';
header('Content-Type: application/json');

if ($path === '/fail') {
    http_response_code(500);
    echo json_encode(['error' => 'boom']);
    return true;
}

$request = json_decode(file_get_contents('php://input'), true) ?: [];
$method = $request['method'] ?? '';

if ($method === 'initialize') {
    $payload = ['result' => [
        'protocolVersion' => '2025-03-26',
        'capabilities' => new stdClass(),
        'serverInfo' => ['name' => 'probeo', 'version' => 'test'],
    ]];
} elseif ($method === 'tools/list') {
    $payload = ['result' => ['tools' => [
        ['name' => 'list_pages', 'description' => 'Lists pages.', 'inputSchema' => [
            'type' => 'object', 'properties' => ['domain' => ['type' => 'string']], 'required' => ['domain'],
        ]],
        ['name' => 'get_page', 'description' => 'Gets a page.', 'inputSchema' => [
            'type' => 'object', 'properties' => ['url' => ['type' => 'string']], 'required' => ['url'],
        ]],
    ]]];
} elseif ($method === 'tools/call') {
    $text = $path === '/echo-auth'
        ? ($_SERVER['HTTP_AUTHORIZATION'] ?? '')
        : json_encode(['pages' => []]);
    $payload = ['result' => ['content' => [['type' => 'text', 'text' => $text]]]];
} else {
    $payload = ['error' => ['message' => "Unexpected method: $method"]];
}

echo json_encode(['jsonrpc' => '2.0', 'id' => $request['id'] ?? null] + $payload);
return true;
