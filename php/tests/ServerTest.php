<?php

require_once __DIR__ . '/../src/Schema.php';
require_once __DIR__ . '/../src/Config.php';
require_once __DIR__ . '/../src/Tool.php';
require_once __DIR__ . '/../src/Resource.php';
require_once __DIR__ . '/../src/Prompt.php';
require_once __DIR__ . '/../src/Scanner.php';
require_once __DIR__ . '/../src/Sandbox.php';
require_once __DIR__ . '/../src/Server.php';

use ZeroMcp\Config;
use ZeroMcp\Server;

class ServerTest
{
    private int $passed = 0;
    private int $failed = 0;

    public function run(): void
    {
        $this->testInitialize();
        $this->testPing();
        $this->testMethodNotFound();
        $this->testNotificationReturnsNull();
        $this->testToolsList();
        $this->testToolsCall();
        $this->testToolsCallUnknown();
        $this->testToolsCallValidationError();
        $this->testResourcesList();
        $this->testResourcesRead();
        $this->testResourcesReadNotFound();
        $this->testResourcesReadTemplate();
        $this->testResourcesTemplatesList();
        $this->testResourcesSubscribe();
        $this->testPromptsList();
        $this->testPromptsGet();
        $this->testPromptsGetNotFound();
        $this->testLoggingSetLevel();
        $this->testCompletionComplete();
        $this->testPagination();
        $this->testPaginationCursor();

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

    private function makeServer(): Server
    {
        $config = new Config([
            'tools' => __DIR__ . '/../tools',
            'resources' => __DIR__ . '/fixtures/resources',
            'prompts' => __DIR__ . '/fixtures/prompts',
        ]);
        $server = new Server($config);
        $server->loadTools();
        return $server;
    }

    private function testInitialize(): void
    {
        $server = $this->makeServer();
        $resp = $server->handleRequest([
            'jsonrpc' => '2.0', 'id' => 1, 'method' => 'initialize', 'params' => [],
        ]);
        $this->assert($resp['id'] === 1, 'initialize returns correct id');
        $this->assert($resp['result']['protocolVersion'] === '2024-11-05', 'protocol version correct');
        $this->assert(isset($resp['result']['capabilities']['tools']), 'tools capability present');
        $this->assert(isset($resp['result']['capabilities']['resources']), 'resources capability present');
        $this->assert(isset($resp['result']['capabilities']['prompts']), 'prompts capability present');
        $this->assert(isset($resp['result']['capabilities']['logging']), 'logging capability present');
        $this->assert($resp['result']['serverInfo']['name'] === 'zeromcp', 'server name correct');
    }

    private function testPing(): void
    {
        $server = $this->makeServer();
        $resp = $server->handleRequest([
            'jsonrpc' => '2.0', 'id' => 2, 'method' => 'ping',
        ]);
        $this->assert($resp['id'] === 2, 'ping returns correct id');
        $this->assert($resp['result'] instanceof \stdClass, 'ping returns empty object');
    }

    private function testMethodNotFound(): void
    {
        $server = $this->makeServer();
        $resp = $server->handleRequest([
            'jsonrpc' => '2.0', 'id' => 3, 'method' => 'nonexistent/method',
        ]);
        $this->assert(isset($resp['error']), 'unknown method returns error');
        $this->assert($resp['error']['code'] === -32601, 'error code is -32601');
    }

    private function testNotificationReturnsNull(): void
    {
        $server = $this->makeServer();
        $resp = $server->handleRequest([
            'jsonrpc' => '2.0', 'method' => 'notifications/initialized',
        ]);
        $this->assert($resp === null, 'notification returns null');
    }

    private function testToolsList(): void
    {
        $server = $this->makeServer();
        $resp = $server->handleRequest([
            'jsonrpc' => '2.0', 'id' => 4, 'method' => 'tools/list', 'params' => [],
        ]);
        $tools = $resp['result']['tools'];
        $this->assert(count($tools) >= 2, 'tools/list returns at least 2 tools');

        $names = array_column($tools, 'name');
        $this->assert(in_array('hello', $names), 'hello tool in list');
        $this->assert(in_array('add', $names), 'add tool in list');

        // Check structure
        $helloTool = null;
        foreach ($tools as $t) {
            if ($t['name'] === 'hello') $helloTool = $t;
        }
        $this->assert(isset($helloTool['description']), 'tool has description');
        $this->assert(isset($helloTool['inputSchema']), 'tool has inputSchema');
        $this->assert($helloTool['inputSchema']['type'] === 'object', 'inputSchema is object type');
    }

    private function testToolsCall(): void
    {
        $server = $this->makeServer();
        $resp = $server->handleRequest([
            'jsonrpc' => '2.0', 'id' => 5, 'method' => 'tools/call',
            'params' => ['name' => 'hello', 'arguments' => ['name' => 'PHP']],
        ]);
        $content = $resp['result']['content'];
        $this->assert(count($content) === 1, 'tools/call returns one content item');
        $this->assert($content[0]['type'] === 'text', 'content type is text');
        $this->assert($content[0]['text'] === 'Hello, PHP!', 'tool returns correct result');
        $this->assert(!isset($resp['result']['isError']), 'no error flag on success');
    }

    private function testToolsCallUnknown(): void
    {
        $server = $this->makeServer();
        $resp = $server->handleRequest([
            'jsonrpc' => '2.0', 'id' => 6, 'method' => 'tools/call',
            'params' => ['name' => 'nonexistent', 'arguments' => []],
        ]);
        $this->assert($resp['result']['isError'] === true, 'unknown tool returns isError');
        $this->assert(str_contains($resp['result']['content'][0]['text'], 'Unknown tool'), 'error mentions unknown tool');
    }

    private function testToolsCallValidationError(): void
    {
        $server = $this->makeServer();
        $resp = $server->handleRequest([
            'jsonrpc' => '2.0', 'id' => 7, 'method' => 'tools/call',
            'params' => ['name' => 'hello', 'arguments' => []],
        ]);
        $this->assert($resp['result']['isError'] === true, 'missing arg returns isError');
        $this->assert(str_contains($resp['result']['content'][0]['text'], 'Validation'), 'error mentions validation');
    }

    private function testResourcesList(): void
    {
        $server = $this->makeServer();
        $resp = $server->handleRequest([
            'jsonrpc' => '2.0', 'id' => 8, 'method' => 'resources/list', 'params' => [],
        ]);
        $resources = $resp['result']['resources'];
        $this->assert(count($resources) >= 3, 'resources/list returns at least 3 resources');

        $names = array_column($resources, 'name');
        $this->assert(in_array('config', $names), 'config resource in list');
        $this->assert(in_array('readme', $names), 'readme resource in list');
        $this->assert(in_array('status', $names), 'status resource in list');

        // Check structure
        foreach ($resources as $r) {
            $this->assert(isset($r['uri']), "resource {$r['name']} has uri");
            $this->assert(isset($r['mimeType']), "resource {$r['name']} has mimeType");
        }
    }

    private function testResourcesRead(): void
    {
        $server = $this->makeServer();
        // Read the status dynamic resource
        $resp = $server->handleRequest([
            'jsonrpc' => '2.0', 'id' => 9, 'method' => 'resources/read',
            'params' => ['uri' => 'resource:///status'],
        ]);
        $contents = $resp['result']['contents'];
        $this->assert(count($contents) === 1, 'resources/read returns one content');
        $this->assert($contents[0]['uri'] === 'resource:///status', 'content uri matches');
        $decoded = json_decode($contents[0]['text'], true);
        $this->assert($decoded['status'] === 'ok', 'dynamic resource content correct');
    }

    private function testResourcesReadNotFound(): void
    {
        $server = $this->makeServer();
        $resp = $server->handleRequest([
            'jsonrpc' => '2.0', 'id' => 10, 'method' => 'resources/read',
            'params' => ['uri' => 'resource:///nonexistent'],
        ]);
        $this->assert(isset($resp['error']), 'missing resource returns error');
        $this->assert($resp['error']['code'] === -32002, 'error code is -32002');
    }

    private function testResourcesReadTemplate(): void
    {
        $server = $this->makeServer();
        $resp = $server->handleRequest([
            'jsonrpc' => '2.0', 'id' => 11, 'method' => 'resources/read',
            'params' => ['uri' => 'resource:///users/42'],
        ]);
        $contents = $resp['result']['contents'];
        $this->assert(count($contents) === 1, 'template read returns one content');
        $decoded = json_decode($contents[0]['text'], true);
        $this->assert($decoded['id'] === '42', 'template param extracted correctly');
        $this->assert($decoded['name'] === 'User 42', 'template returns correct data');
    }

    private function testResourcesTemplatesList(): void
    {
        $server = $this->makeServer();
        $resp = $server->handleRequest([
            'jsonrpc' => '2.0', 'id' => 12, 'method' => 'resources/templates/list', 'params' => [],
        ]);
        $templates = $resp['result']['resourceTemplates'];
        $this->assert(count($templates) >= 1, 'at least one template listed');
        $this->assert(isset($templates[0]['uriTemplate']), 'template has uriTemplate');
        $this->assert(isset($templates[0]['name']), 'template has name');
    }

    private function testResourcesSubscribe(): void
    {
        $server = $this->makeServer();
        $resp = $server->handleRequest([
            'jsonrpc' => '2.0', 'id' => 13, 'method' => 'resources/subscribe',
            'params' => ['uri' => 'resource:///status'],
        ]);
        $this->assert($resp['result'] instanceof \stdClass, 'subscribe returns empty object');
    }

    private function testPromptsList(): void
    {
        $server = $this->makeServer();
        $resp = $server->handleRequest([
            'jsonrpc' => '2.0', 'id' => 14, 'method' => 'prompts/list', 'params' => [],
        ]);
        $prompts = $resp['result']['prompts'];
        $this->assert(count($prompts) >= 2, 'prompts/list returns at least 2 prompts');

        $names = array_column($prompts, 'name');
        $this->assert(in_array('greet', $names), 'greet prompt in list');
        $this->assert(in_array('summarize', $names), 'summarize prompt in list');

        // Check greet has arguments
        $greet = null;
        foreach ($prompts as $p) {
            if ($p['name'] === 'greet') $greet = $p;
        }
        $this->assert(isset($greet['arguments']), 'greet has arguments');
        $this->assert(count($greet['arguments']) === 2, 'greet has 2 arguments');
    }

    private function testPromptsGet(): void
    {
        $server = $this->makeServer();
        $resp = $server->handleRequest([
            'jsonrpc' => '2.0', 'id' => 15, 'method' => 'prompts/get',
            'params' => ['name' => 'greet', 'arguments' => ['name' => 'Alice']],
        ]);
        $messages = $resp['result']['messages'];
        $this->assert(count($messages) === 1, 'prompts/get returns one message');
        $this->assert($messages[0]['role'] === 'user', 'message role is user');
        $this->assert(str_contains($messages[0]['content']['text'], 'Alice'), 'message contains name');
    }

    private function testPromptsGetNotFound(): void
    {
        $server = $this->makeServer();
        $resp = $server->handleRequest([
            'jsonrpc' => '2.0', 'id' => 16, 'method' => 'prompts/get',
            'params' => ['name' => 'nonexistent'],
        ]);
        $this->assert(isset($resp['error']), 'missing prompt returns error');
        $this->assert($resp['error']['code'] === -32002, 'error code is -32002');
    }

    private function testLoggingSetLevel(): void
    {
        $server = $this->makeServer();
        $resp = $server->handleRequest([
            'jsonrpc' => '2.0', 'id' => 17, 'method' => 'logging/setLevel',
            'params' => ['level' => 'debug'],
        ]);
        $this->assert($resp['result'] instanceof \stdClass, 'logging/setLevel returns empty object');
        $this->assert($resp['id'] === 17, 'correct id returned');
    }

    private function testCompletionComplete(): void
    {
        $server = $this->makeServer();
        $resp = $server->handleRequest([
            'jsonrpc' => '2.0', 'id' => 18, 'method' => 'completion/complete', 'params' => [],
        ]);
        $this->assert(isset($resp['result']['completion']), 'completion returns completion object');
        $this->assert($resp['result']['completion']['values'] === [], 'completion values empty');
    }

    private function testPagination(): void
    {
        $config = new Config([
            'tools' => __DIR__ . '/../tools',
            'resources' => __DIR__ . '/fixtures/resources',
            'prompts' => __DIR__ . '/fixtures/prompts',
            'page_size' => 1,
        ]);
        $server = new Server($config);
        $server->loadTools();

        // First page of tools
        $resp = $server->handleRequest([
            'jsonrpc' => '2.0', 'id' => 19, 'method' => 'tools/list', 'params' => [],
        ]);
        $this->assert(count($resp['result']['tools']) === 1, 'page size 1 returns 1 tool');
        $this->assert(isset($resp['result']['nextCursor']), 'first page has nextCursor');

        // First page of resources
        $resp = $server->handleRequest([
            'jsonrpc' => '2.0', 'id' => 20, 'method' => 'resources/list', 'params' => [],
        ]);
        $this->assert(count($resp['result']['resources']) === 1, 'page size 1 returns 1 resource');
        $this->assert(isset($resp['result']['nextCursor']), 'resources first page has nextCursor');

        // First page of prompts
        $resp = $server->handleRequest([
            'jsonrpc' => '2.0', 'id' => 21, 'method' => 'prompts/list', 'params' => [],
        ]);
        $this->assert(count($resp['result']['prompts']) === 1, 'page size 1 returns 1 prompt');
        $this->assert(isset($resp['result']['nextCursor']), 'prompts first page has nextCursor');
    }

    private function testPaginationCursor(): void
    {
        $config = new Config([
            'tools' => __DIR__ . '/../tools',
            'resources' => __DIR__ . '/fixtures/resources',
            'prompts' => __DIR__ . '/fixtures/prompts',
            'page_size' => 1,
        ]);
        $server = new Server($config);
        $server->loadTools();

        // Get first page
        $resp1 = $server->handleRequest([
            'jsonrpc' => '2.0', 'id' => 22, 'method' => 'tools/list', 'params' => [],
        ]);
        $cursor = $resp1['result']['nextCursor'];
        $firstName = $resp1['result']['tools'][0]['name'];

        // Get second page using cursor
        $resp2 = $server->handleRequest([
            'jsonrpc' => '2.0', 'id' => 23, 'method' => 'tools/list',
            'params' => ['cursor' => $cursor],
        ]);
        $secondName = $resp2['result']['tools'][0]['name'];
        $this->assert($firstName !== $secondName, 'cursor advances to different tool');
        $this->assert(count($resp2['result']['tools']) === 1, 'second page returns 1 tool');
    }
}

echo "Server Tests:\n";
$test = new ServerTest();
$test->run();
