<?php

require_once __DIR__ . '/../src/Log.php';
require_once __DIR__ . '/../src/Schema.php';
require_once __DIR__ . '/../src/Config.php';
require_once __DIR__ . '/../src/Tool.php';
require_once __DIR__ . '/../src/Resource.php';
require_once __DIR__ . '/../src/Prompt.php';
require_once __DIR__ . '/../src/Scanner.php';
require_once __DIR__ . '/../src/Sandbox.php';
require_once __DIR__ . '/../src/RemoteManager.php';
require_once __DIR__ . '/../src/Server.php';
require_once __DIR__ . '/../src/Registry.php';
require_once __DIR__ . '/fixtures/remote/FakeUpstream.php';

use ZeroMcp\Config;
use ZeroMcp\Registry;
use ZeroMcp\Tool;

class RegistryTest
{
    private int $passed = 0;
    private int $failed = 0;

    public function run(): void
    {
        $this->testRoutesOnlyIncludesRoutedTools();
        $this->testRoutesPreserveInsertionOrder();
        $this->testOpenApiMatchesRoutedTools();
        $this->testRouteToolInvokedDirectly();
        $this->testMcpDispatchesToolsList();
        $this->testMcpDispatchesToolsCall();
        $this->testGetEnvOverridesCredentials();
        $this->testAcceptsRawDefinitionArrays();
        $this->testEmptyWhenNoRoutedTools();
        $this->testDefaultConfigDoesNotLoadFromDisk();

        $upstream = new FakeUpstream();
        $upstream->start();
        try {
            $this->testRemoteToolsInMcp($upstream);
            $this->testLocalOverridesRemote($upstream);
            $this->testRemoteAbsentFromRoutesAndOpenApi($upstream);
        } finally {
            $upstream->stop();
        }

        echo "\n{$this->passed} passed, {$this->failed} failed\n";
        if ($this->failed > 0) exit(1);
    }

    private function assert(bool $condition, string $message): void
    {
        if ($condition) {
            $this->passed++;
            echo "  PASS: $message\n";
        } else {
            $this->failed++;
            echo "  FAIL: $message\n";
        }
    }

    private function routedTool(string $name = 'greet', string $method = 'GET', string $path = '/greet/:name'): Tool
    {
        return new Tool(
            name: $name,
            description: 'Greet someone',
            input: ['name' => 'string'],
            execute: fn($args, $ctx) => 'hi ' . $args['name'],
            route: ['method' => $method, 'path' => $path],
        );
    }

    private function unroutedTool(string $name = 'hidden'): Tool
    {
        return new Tool(name: $name, description: 'No route', execute: fn($args, $ctx) => '');
    }

    private function testRoutesOnlyIncludesRoutedTools(): void
    {
        $registry = Registry::create([
            'greet' => $this->routedTool(),
            'hidden' => $this->unroutedTool(),
        ]);
        $this->assert(count($registry->routes) === 1, 'only routed tools appear in routes');
        $this->assert($registry->routes[0]->name === 'greet', 'route name is correct');
        $this->assert($registry->routes[0]->method === 'GET', 'route method is correct');
        $this->assert($registry->routes[0]->path === '/greet/:name', 'route path is correct');
    }

    private function testRoutesPreserveInsertionOrder(): void
    {
        $registry = Registry::create([
            'charlie' => $this->routedTool('charlie', 'GET', '/charlie'),
            'alpha' => $this->routedTool('alpha', 'GET', '/alpha'),
            'bravo' => $this->routedTool('bravo', 'GET', '/bravo'),
        ]);
        $names = array_map(fn($r) => $r->name, $registry->routes);
        $this->assert($names === ['charlie', 'alpha', 'bravo'], 'routes preserve insertion order');
    }

    private function testOpenApiMatchesRoutedTools(): void
    {
        $registry = Registry::create(['greet' => $this->routedTool()]);
        $this->assert(array_key_exists('/greet/{name}', $registry->openapi['paths'] ?? []), 'openapi documents the routed tool');
    }

    private function testRouteToolInvokedDirectly(): void
    {
        $registry = Registry::create(['greet' => $this->routedTool()]);
        $result = $registry->routes[0]->tool->call(['name' => 'Ada']);
        $this->assert($result === 'hi Ada', 'invoking route.tool directly produces expected result');
    }

    private function testMcpDispatchesToolsList(): void
    {
        $registry = Registry::create(['greet' => $this->routedTool()]);
        $resp = $registry->mcp(['jsonrpc' => '2.0', 'id' => 1, 'method' => 'tools/list']);
        $this->assert(count($resp['result']['tools']) === 1, 'mcp tools/list reflects registered tools');
        $this->assert($resp['result']['tools'][0]['name'] === 'greet', 'mcp tools/list has correct tool name');
    }

    private function testMcpDispatchesToolsCall(): void
    {
        $registry = Registry::create(['greet' => $this->routedTool('greet', 'POST', '/greet')]);
        $resp = $registry->mcp([
            'jsonrpc' => '2.0', 'id' => 1, 'method' => 'tools/call',
            'params' => ['name' => 'greet', 'arguments' => ['name' => 'Ada']],
        ]);
        $this->assert($resp['result']['content'][0]['text'] === 'hi Ada', 'mcp tools/call dispatches to the tool');
    }

    private function testGetEnvOverridesCredentials(): void
    {
        $tool = new Tool(
            name: 'greet',
            description: 'Greet',
            input: ['name' => 'string'],
            execute: fn($args, $ctx) => $ctx->credentials,
        );
        $registry = Registry::create(['greet' => $tool], [
            'get_env' => fn() => ['apiKey' => 'secret'],
        ]);
        $resp = $registry->mcp([
            'jsonrpc' => '2.0', 'id' => 1, 'method' => 'tools/call',
            'params' => ['name' => 'greet', 'arguments' => ['name' => 'Ada']],
        ]);
        $this->assert(
            str_contains($resp['result']['content'][0]['text'], 'secret'),
            'get_env value flows into $ctx->credentials via mcp()'
        );
    }

    private function testAcceptsRawDefinitionArrays(): void
    {
        $registry = Registry::create([
            'greet' => [
                'description' => 'Greet someone',
                'input' => ['name' => 'string'],
                'route' => ['method' => 'GET', 'path' => '/greet/:name'],
                'execute' => fn($args, $ctx) => 'hi ' . $args['name'],
            ],
        ]);
        $this->assert(count($registry->routes) === 1, 'raw definition arrays are normalized via Tool::fromDefinition');
        $this->assert($registry->routes[0]->tool instanceof Tool, 'normalized entry is a Tool instance');
    }

    private function testEmptyWhenNoRoutedTools(): void
    {
        $registry = Registry::create(['hidden' => $this->unroutedTool()]);
        $this->assert(count($registry->routes) === 0, 'no routes when no tool declares a route');
    }

    private function testDefaultConfigDoesNotLoadFromDisk(): void
    {
        // Should build cleanly using in-memory Config([]) defaults, not Config::load().
        $registry = Registry::create(['greet' => $this->routedTool()]);
        $this->assert($registry->openapi['info']['title'] === 'ZeroMCP', 'default config title is the in-memory default');
    }

    private function testRemoteToolsInMcp(FakeUpstream $upstream): void
    {
        $registry = Registry::create([], ['remote' => [['name' => 'probeo', 'url' => $upstream->url()]]]);
        $listed = $registry->mcp(['jsonrpc' => '2.0', 'id' => 1, 'method' => 'tools/list']);
        $names = array_column($listed['result']['tools'], 'name');
        $this->assert($names === ['probeo.list_pages', 'probeo.get_page'], 'remote tools appear in mcp tools/list');

        $called = $registry->mcp([
            'jsonrpc' => '2.0', 'id' => 2, 'method' => 'tools/call',
            'params' => ['name' => 'probeo.list_pages', 'arguments' => ['domain' => 'example.com']],
        ]);
        $this->assert($called['result']['content'][0]['text'] === json_encode(['pages' => []]), 'mcp tools/call returns upstream text');
    }

    private function testLocalOverridesRemote(FakeUpstream $upstream): void
    {
        $registry = Registry::create(
            ['probeo.list_pages' => new Tool(name: 'probeo.list_pages', description: 'local', execute: fn($a, $c) => 'local')],
            ['remote' => [['name' => 'probeo', 'url' => $upstream->url()]]],
        );
        $called = $registry->mcp([
            'jsonrpc' => '2.0', 'id' => 3, 'method' => 'tools/call',
            'params' => ['name' => 'probeo.list_pages', 'arguments' => []],
        ]);
        $this->assert($called['result']['content'][0]['text'] === 'local', 'local tool overrides remote tool in registry');
    }

    private function testRemoteAbsentFromRoutesAndOpenApi(FakeUpstream $upstream): void
    {
        $registry = Registry::create(
            ['greet' => $this->routedTool()],
            ['remote' => [['name' => 'probeo', 'url' => $upstream->url()]]],
        );
        $this->assert(array_map(fn($r) => $r->name, $registry->routes) === ['greet'], 'routes contain no remote tools');
        $this->assert(array_keys((array) $registry->openapi['paths']) === ['/greet/{name}'], 'openapi paths contain no remote tools');
    }
}

echo "Registry Tests:\n";
$test = new RegistryTest();
$test->run();
