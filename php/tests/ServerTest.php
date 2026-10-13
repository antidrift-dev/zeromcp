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
        $this->testOpenApiNonGetRoutePathParam();
        $this->testRuntimeContext();
        $this->testRuntimeInvokedPerCall();
        $this->testRuntimeNullWithoutOption();
        $this->testCredentialsFollowDirectoryAfterRename();
        $this->testAutoloadTools();

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

    private function testOpenApiNonGetRoutePathParam(): void
    {
        $config = new Config([
            'tools' => __DIR__ . '/fixtures/tools',
        ]);
        $server = new Server($config);
        $server->loadTools();

        $method = new \ReflectionMethod(Server::class, 'buildOpenApiSpec');
        $spec = $method->invoke($server);

        $operation = $spec['paths']['/items/{id}']['put'] ?? null;
        $this->assert($operation !== null, 'PUT /items/{id} present in openapi spec');

        $parameters = $operation['parameters'] ?? [];
        $this->assert(count($parameters) === 1, 'non-GET route documents exactly one path parameter');
        $this->assert(
            ($parameters[0] ?? null) === [
                'name' => 'id', 'in' => 'path', 'required' => true, 'schema' => ['type' => 'string'],
            ],
            'path parameter has correct shape'
        );

        $bodySchema = $operation['requestBody']['content']['application/json']['schema'] ?? [];
        $this->assert($operation['requestBody']['required'] === true, 'requestBody is marked required');
        $this->assert(!array_key_exists('id', $bodySchema['properties'] ?? []), 'path param excluded from body properties');
        $this->assert(array_key_exists('name', $bodySchema['properties'] ?? []), 'non-path param still in body properties');
        $this->assert(!in_array('id', $bodySchema['required'] ?? [], true), 'path param excluded from body required list');
    }

    private function callWhoami(Server $server, int $id = 1): mixed
    {
        $resp = $server->handleRequest([
            'jsonrpc' => '2.0', 'id' => $id, 'method' => 'tools/call',
            'params' => ['name' => 'whoami', 'arguments' => []],
        ]);
        return json_decode($resp['result']['content'][0]['text'], true);
    }

    private function testRuntimeContext(): void
    {
        $config = new Config(['tools' => __DIR__ . '/fixtures/runtime_tools']);
        $server = new Server($config, ['get_runtime' => fn() => ['db' => 'x']]);
        $server->loadTools();
        $this->assert($this->callWhoami($server) === ['runtime' => ['db' => 'x']], 'get_runtime value lands on $ctx->runtime');
    }

    private function testRuntimeInvokedPerCall(): void
    {
        $count = 0;
        $config = new Config(['tools' => __DIR__ . '/fixtures/runtime_tools']);
        $server = new Server($config, ['get_runtime' => function () use (&$count) { return ++$count; }]);
        $server->loadTools();
        $first = $this->callWhoami($server, 1);
        $second = $this->callWhoami($server, 2);
        $this->assert($first === ['runtime' => 1] && $second === ['runtime' => 2] && $count === 2, 'get_runtime invoked once per tools/call');
    }

    private function testRuntimeNullWithoutOption(): void
    {
        $server = new Server(new Config(['tools' => __DIR__ . '/fixtures/runtime_tools']));
        $server->loadTools();
        $this->assert($this->callWhoami($server) === ['runtime' => null], '$ctx->runtime is null without get_runtime');
    }

    private function testCredentialsFollowDirectoryAfterRename(): void
    {
        $dir = sys_get_temp_dir() . '/zeromcp-cred-' . getmypid();
        @mkdir("$dir/math", 0777, true);
        file_put_contents("$dir/math/add.php", "<?php return ['execute' => fn(\$a, \$c) => \$c->credentials];");
        putenv('ZEROMCP_TEST_MATH_CRED=mathkey');

        $server = new Server(new Config([
            'tools' => $dir,
            'namespacing' => ['math' => ['prefix' => 'm']],
            'credentials' => ['math' => ['env' => 'ZEROMCP_TEST_MATH_CRED']],
        ]));
        $server->loadTools();
        $resp = $server->handleRequest([
            'jsonrpc' => '2.0', 'id' => 1, 'method' => 'tools/call',
            'params' => ['name' => 'm_add', 'arguments' => []],
        ]);
        $this->assert(($resp['result']['content'][0]['text'] ?? null) === 'mathkey', 'credentials keyed by directory reach a renamed tool (m_add)');

        putenv('ZEROMCP_TEST_MATH_CRED');
        @unlink("$dir/math/add.php");
        @rmdir("$dir/math");
        @rmdir($dir);
    }

    private function testAutoloadTools(): void
    {
        $base = sys_get_temp_dir() . '/zeromcp-autoload-' . getmypid();
        @mkdir("$base/tools", 0777, true);
        file_put_contents("$base/tools/first.php", "<?php return ['description' => 'first', 'execute' => fn(\$a, \$c) => 'one'];");
        file_put_contents("$base/config.json", json_encode(['tools' => "$base/tools", 'autoload_tools' => true]));

        $proc = proc_open(
            [PHP_BINARY, __DIR__ . '/../zeromcp.php', 'serve', '--config', "$base/config.json"],
            [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['file', "$base/stderr.log", 'w']],
            $pipes
        );
        stream_set_blocking($pipes[1], false);

        $buf = '';
        $readUntil = function (string $needle, float $timeout) use ($pipes, &$buf): ?string {
            $deadline = microtime(true) + $timeout;
            while (true) {
                while (($pos = strpos($buf, "\n")) !== false) {
                    $line = substr($buf, 0, $pos);
                    $buf = substr($buf, $pos + 1);
                    if (str_contains($line, $needle)) return $line;
                }
                if (microtime(true) >= $deadline) return null;
                $r = [$pipes[1]]; $w = null; $e = null;
                if (@stream_select($r, $w, $e, 0, 200000) > 0) {
                    $chunk = fread($pipes[1], 65536);
                    if ($chunk === '' || $chunk === false) {
                        if (feof($pipes[1])) return null;
                        continue;
                    }
                    $buf .= $chunk;
                }
            }
        };

        // Wait until the server is up (it answers ping) before changing files.
        fwrite($pipes[0], json_encode(['jsonrpc' => '2.0', 'id' => 1, 'method' => 'ping']) . "\n");
        fflush($pipes[0]);
        $pong = $readUntil('"id":1', 5);
        $this->assert($pong !== null, 'autoload server answers over stdio');

        file_put_contents("$base/tools/second.php", "<?php return ['description' => 'second', 'execute' => fn(\$a, \$c) => 'two'];");
        $note = $readUntil('notifications/tools/list_changed', 5);
        $this->assert($note === '{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{}}', 'list_changed notification sent after a new tool file appears');

        fwrite($pipes[0], json_encode(['jsonrpc' => '2.0', 'id' => 2, 'method' => 'tools/list']) . "\n");
        fflush($pipes[0]);
        $line = $readUntil('"id":2', 5);
        $names = $line ? array_column(json_decode($line, true)['result']['tools'] ?? [], 'name') : [];
        sort($names);
        $this->assert($names === ['first', 'second'], 'tools/list includes the new tool after reload');

        fclose($pipes[0]);
        fclose($pipes[1]);
        proc_terminate($proc);
        proc_close($proc);

        $stderr = (string) @file_get_contents("$base/stderr.log");
        $this->assert(str_contains($stderr, '[zeromcp] autoload_tools enabled — watching for changes'), 'autoload startup line logged');
        $this->assert(str_contains($stderr, '[zeromcp] Change detected: second.php'), 'change detected line logged');

        foreach (['tools/first.php', 'tools/second.php', 'config.json', 'stderr.log'] as $f) @unlink("$base/$f");
        @rmdir("$base/tools");
        @rmdir($base);
    }
}

echo "Server Tests:\n";
$test = new ServerTest();
$test->run();
