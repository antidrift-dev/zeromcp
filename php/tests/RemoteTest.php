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
require_once __DIR__ . '/fixtures/remote/FakeUpstream.php';

use ZeroMcp\Config;
use ZeroMcp\Server;

class RemoteTest
{
    private int $passed = 0;
    private int $failed = 0;
    private FakeUpstream $upstream;
    private string $emptyTools;

    public function run(): void
    {
        $this->upstream = new FakeUpstream();
        $this->upstream->start();
        $this->emptyTools = sys_get_temp_dir() . '/zeromcp-remote-empty-' . getmypid();
        @mkdir($this->emptyTools);

        try {
            $this->testRemoteToolsListed();
            $this->testRemoteToolsCall();
            $this->testAllowlist();
            $this->testEnvAuthSendsBearer();
            $this->testBadServersSkipped();
            $this->testNon2xxSkipped();
            $this->testLocalOverridesRemote();
            $this->testRemoteAbsentFromOpenApi();
            $this->testResolveAuth();
        } finally {
            $this->upstream->stop();
            @rmdir($this->emptyTools);
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

    private function server(array $remote, ?string $tools = null): Server
    {
        $server = new Server(new Config(['tools' => $tools ?? $this->emptyTools, 'remote' => $remote]));
        $server->loadTools();
        return $server;
    }

    private function toolNames(Server $server): array
    {
        $resp = $server->handleRequest(['jsonrpc' => '2.0', 'id' => 1, 'method' => 'tools/list']);
        return array_column($resp['result']['tools'], 'name');
    }

    /** Capture what Log::write sends to STDERR while $fn runs, by running it in a child process. */
    private function stderrOf(string $code): string
    {
        $script = sys_get_temp_dir() . '/zeromcp-remote-child-' . getmypid() . '.php';
        $requires = '';
        foreach (['Log', 'Schema', 'Config', 'Tool', 'Resource', 'Prompt', 'Scanner', 'Sandbox', 'RemoteManager', 'Server'] as $f) {
            $requires .= "require_once " . var_export(__DIR__ . "/../src/$f.php", true) . ";\n";
        }
        file_put_contents($script, "<?php\n$requires\n$code\n");
        $proc = proc_open([PHP_BINARY, $script], [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
        stream_get_contents($pipes[1]);
        $err = stream_get_contents($pipes[2]);
        proc_close($proc);
        @unlink($script);
        return $err;
    }

    private function testRemoteToolsListed(): void
    {
        $server = $this->server([['name' => 'probeo', 'url' => $this->upstream->url()]]);
        $names = $this->toolNames($server);
        $this->assert($names === ['probeo.list_pages', 'probeo.get_page'], 'remote tools listed as <server>.<tool>');

        $resp = $server->handleRequest(['jsonrpc' => '2.0', 'id' => 1, 'method' => 'tools/list']);
        $schema = $resp['result']['tools'][0]['inputSchema'];
        $this->assert($schema['required'] === ['domain'], 'remote inputSchema required carried over');
        $this->assert($schema['properties']['domain'] === ['type' => 'string'], 'remote inputSchema property carried over');
    }

    private function testRemoteToolsCall(): void
    {
        $server = $this->server([['name' => 'probeo', 'url' => $this->upstream->url()]]);
        $resp = $server->handleRequest([
            'jsonrpc' => '2.0', 'id' => 2, 'method' => 'tools/call',
            'params' => ['name' => 'probeo.list_pages', 'arguments' => ['domain' => 'example.com']],
        ]);
        $this->assert(
            $resp['result']['content'] === [['type' => 'text', 'text' => json_encode(['pages' => []])]],
            'tools/call returns upstream content[0].text'
        );
    }

    private function testAllowlist(): void
    {
        $server = $this->server([['name' => 'probeo', 'url' => $this->upstream->url(), 'tools' => ['list_pages']]]);
        $this->assert($this->toolNames($server) === ['probeo.list_pages'], 'tools allowlist exposes only listed tools');
    }

    private function testEnvAuthSendsBearer(): void
    {
        putenv('ZEROMCP_REMOTE_TEST_TOKEN=s3cret');
        $server = $this->server([['name' => 'probeo', 'url' => $this->upstream->url('/echo-auth'), 'auth' => 'env:ZEROMCP_REMOTE_TEST_TOKEN']]);
        $resp = $server->handleRequest([
            'jsonrpc' => '2.0', 'id' => 3, 'method' => 'tools/call',
            'params' => ['name' => 'probeo.get_page', 'arguments' => ['url' => 'x']],
        ]);
        $this->assert($resp['result']['content'][0]['text'] === 'Bearer s3cret', 'auth env:VAR sends Authorization: Bearer <value>');
        putenv('ZEROMCP_REMOTE_TEST_TOKEN');
    }

    private function testBadServersSkipped(): void
    {
        $sock = stream_socket_server('tcp://127.0.0.1:0');
        $name = stream_socket_get_name($sock, false);
        fclose($sock); // nothing listens here now
        $server = $this->server([
            ['name' => 'ws', 'url' => 'ws://127.0.0.1:1/mcp'],
            ['name' => 'down', 'url' => "http://$name/"],
            ['name' => 'probeo', 'url' => $this->upstream->url()],
        ]);
        $this->assert($this->toolNames($server) === ['probeo.list_pages', 'probeo.get_page'], 'non-http and unreachable servers skipped, good server still loads');

        $url = var_export($this->upstream->url(), true);
        $empty = var_export($this->emptyTools, true);
        $err = $this->stderrOf("(new ZeroMcp\\Server(new ZeroMcp\\Config(['tools' => $empty, 'remote' => [['name' => 'ws', 'url' => 'ws://x'], ['name' => 'probeo', 'url' => $url]]])))->loadTools();");
        $this->assert(str_contains($err, '[mcp] Failed to connect to ws: Remote server "ws" must have an HTTP/HTTPS URL, got: ws://x'), 'non-http URL logs failure');
        $this->assert(str_contains($err, '[mcp] Connected to probeo (HTTP): 2 tool(s)'), 'connected line logged');
        $this->assert(str_contains($err, '[mcp] Remote tool: probeo.list_pages'), 'remote tool line logged');
    }

    private function testNon2xxSkipped(): void
    {
        $server = $this->server([
            ['name' => 'broken', 'url' => $this->upstream->url('/fail')],
            ['name' => 'probeo', 'url' => $this->upstream->url()],
        ]);
        $this->assert($this->toolNames($server) === ['probeo.list_pages', 'probeo.get_page'], 'non-2xx server skipped');

        $url = var_export($this->upstream->url('/fail'), true);
        $empty = var_export($this->emptyTools, true);
        $err = $this->stderrOf("(new ZeroMcp\\Server(new ZeroMcp\\Config(['tools' => $empty, 'remote' => [['name' => 'broken', 'url' => $url]]])))->loadTools();");
        $this->assert(str_contains($err, '[mcp] Failed to connect to broken: HTTP 500'), 'non-2xx logs HTTP <status>');
    }

    private function testLocalOverridesRemote(): void
    {
        $dir = sys_get_temp_dir() . '/zeromcp-remote-local-' . getmypid();
        @mkdir($dir);
        file_put_contents("$dir/probeo.list_pages.php", "<?php return ['description' => 'local', 'execute' => fn(\$a, \$c) => 'local wins'];");

        $server = $this->server([['name' => 'probeo', 'url' => $this->upstream->url()]], $dir);
        $resp = $server->handleRequest([
            'jsonrpc' => '2.0', 'id' => 4, 'method' => 'tools/call',
            'params' => ['name' => 'probeo.list_pages', 'arguments' => []],
        ]);
        $this->assert($resp['result']['content'][0]['text'] === 'local wins', 'local tool overrides remote tool of same name');

        $url = var_export($this->upstream->url(), true);
        $d = var_export($dir, true);
        $err = $this->stderrOf("(new ZeroMcp\\Server(new ZeroMcp\\Config(['tools' => $d, 'remote' => [['name' => 'probeo', 'url' => $url]]])))->loadTools();");
        $this->assert(str_contains($err, '[zeromcp] Local tool "probeo.list_pages" overrides remote'), 'override is logged');

        @unlink("$dir/probeo.list_pages.php");
        @rmdir($dir);
    }

    private function testRemoteAbsentFromOpenApi(): void
    {
        $server = $this->server([['name' => 'probeo', 'url' => $this->upstream->url()]], __DIR__ . '/fixtures/tools');
        $paths = (array) $server->buildOpenApiSpec()['paths'];
        $this->assert(array_keys($paths) === ['/items/{id}'], 'remote tools absent from buildOpenApiSpec paths');
    }

    private function testResolveAuth(): void
    {
        $this->assert(Config::resolveAuth(null) === null, 'resolveAuth(null) is null');
        $this->assert(Config::resolveAuth('') === null, "resolveAuth('') is null");
        $this->assert(Config::resolveAuth('literal') === 'literal', 'resolveAuth literal passthrough');
        $err = $this->stderrOf("var_dump(ZeroMcp\\Config::resolveAuth('env:ZEROMCP_DEFINITELY_UNSET'));");
        $this->assert(str_contains($err, '[zeromcp] Warning: environment variable ZEROMCP_DEFINITELY_UNSET not set'), 'resolveAuth warns on unset env var');
    }
}

echo "Remote Tests:\n";
$test = new RemoteTest();
$test->run();
