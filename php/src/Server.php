<?php

namespace ZeroMcp;

class Server
{
    private Config $config;
    private Scanner $scanner;
    /** @var array<string, Tool> */
    private array $tools = [];

    public function __construct(?Config $config = null)
    {
        $this->config = $config ?? Config::load();
        $this->scanner = new Scanner($this->config);
    }

    public function serve(): void
    {
        $this->tools = $this->scanner->scan();
        fwrite(STDERR, "[zeromcp] " . count($this->tools) . " tool(s) loaded\n");
        fwrite(STDERR, "[zeromcp] stdio transport ready\n");

        $stdin = fopen('php://stdin', 'r');

        while (($line = fgets($stdin)) !== false) {
            $line = trim($line);
            if ($line === '') continue;

            $request = json_decode($line, true);
            if (!is_array($request)) continue;

            $response = $this->handleRequest($request);
            if ($response !== null) {
                fwrite(STDOUT, json_encode($response, JSON_UNESCAPED_SLASHES) . "\n");
                fflush(STDOUT);
            }
        }

        fclose($stdin);
    }

    private function handleRequest(array $request): ?array
    {
        $id = $request['id'] ?? null;
        $method = $request['method'] ?? '';
        $params = $request['params'] ?? [];

        if ($id === null && $method === 'notifications/initialized') {
            return null;
        }

        switch ($method) {
            case 'initialize':
                return [
                    'jsonrpc' => '2.0',
                    'id' => $id,
                    'result' => [
                        'protocolVersion' => '2024-11-05',
                        'capabilities' => [
                            'tools' => ['listChanged' => true],
                        ],
                        'serverInfo' => [
                            'name' => 'zeromcp',
                            'version' => '0.1.0',
                        ],
                    ],
                ];

            case 'tools/list':
                return [
                    'jsonrpc' => '2.0',
                    'id' => $id,
                    'result' => [
                        'tools' => $this->buildToolList(),
                    ],
                ];

            case 'tools/call':
                return [
                    'jsonrpc' => '2.0',
                    'id' => $id,
                    'result' => $this->callTool($params),
                ];

            case 'ping':
                return ['jsonrpc' => '2.0', 'id' => $id, 'result' => new \stdClass()];

            default:
                if ($id === null) return null;
                return [
                    'jsonrpc' => '2.0',
                    'id' => $id,
                    'error' => ['code' => -32601, 'message' => "Method not found: $method"],
                ];
        }
    }

    private function buildToolList(): array
    {
        $list = [];
        foreach ($this->tools as $name => $tool) {
            $list[] = [
                'name' => $name,
                'description' => $tool->description,
                'inputSchema' => Schema::toJsonSchema($tool->input),
            ];
        }
        return $list;
    }

    private function callTool(array $params): array
    {
        $name = $params['name'] ?? '';
        $args = $params['arguments'] ?? [];

        if (!isset($this->tools[$name])) {
            return [
                'content' => [['type' => 'text', 'text' => "Unknown tool: $name"]],
                'isError' => true,
            ];
        }

        $tool = $this->tools[$name];
        $schema = Schema::toJsonSchema($tool->input);
        $errors = Schema::validate($args, $schema);

        if (!empty($errors)) {
            return [
                'content' => [['type' => 'text', 'text' => "Validation errors:\n" . implode("\n", $errors)]],
                'isError' => true,
            ];
        }

        try {
            $ctx = new Context($name, null, $tool->permissions);

            // Tool-level timeout overrides config default
            $timeoutSecs = $tool->permissions['execute_timeout'] ?? $this->config->executeTimeout;

            // Use pcntl_alarm for timeout if available (POSIX systems)
            $timedOut = false;
            if (function_exists('pcntl_alarm') && function_exists('pcntl_signal')) {
                $previousHandler = null;
                pcntl_signal(SIGALRM, function () use (&$timedOut) {
                    $timedOut = true;
                    throw new \RuntimeException("__ZEROMCP_TIMEOUT__");
                });
                pcntl_alarm((int) $timeoutSecs);
            }

            try {
                $result = $tool->call($args, $ctx);
            } finally {
                if (function_exists('pcntl_alarm')) {
                    pcntl_alarm(0); // Cancel alarm
                }
            }

            if ($timedOut) {
                return [
                    'content' => [['type' => 'text', 'text' => "Tool \"$name\" timed out after {$timeoutSecs}s"]],
                    'isError' => true,
                ];
            }

            $text = is_string($result) ? $result : json_encode($result, JSON_UNESCAPED_SLASHES);
            return ['content' => [['type' => 'text', 'text' => $text]]];
        } catch (\RuntimeException $e) {
            if ($e->getMessage() === '__ZEROMCP_TIMEOUT__') {
                return [
                    'content' => [['type' => 'text', 'text' => "Tool \"$name\" timed out after {$timeoutSecs}s"]],
                    'isError' => true,
                ];
            }
            return [
                'content' => [['type' => 'text', 'text' => "Error: {$e->getMessage()}"]],
                'isError' => true,
            ];
        } catch (\Throwable $e) {
            return [
                'content' => [['type' => 'text', 'text' => "Error: {$e->getMessage()}"]],
                'isError' => true,
            ];
        }
    }
}
