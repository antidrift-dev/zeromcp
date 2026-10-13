<?php

namespace ZeroMcp;

class Server
{
    private Config $config;
    private Scanner $scanner;
    /** @var array<string, Tool> */
    private array $tools = [];
    /** @var array<string, Resource> */
    private array $resources = [];
    /** @var array<string, ResourceTemplate> */
    private array $templates = [];
    /** @var array<string, Prompt> */
    private array $prompts = [];
    /** @var array<string, bool> subscribed resource URIs */
    private array $subscriptions = [];
    private string $logLevel = 'info';
    private ?string $icon = null;
    /** @var array<string, mixed> credential cache keyed by namespace */
    private array $credentialCache = [];
    /** Overrides resolveCredentials() when set — used by Registry::create()'s get_env option. */
    private ?\Closure $envOverride = null;
    /** Per-call runtime context provider (`get_runtime` option); its value lands on $ctx->runtime. */
    private ?\Closure $getRuntime = null;

    private const ICON_MIME = [
        'png'  => 'image/png',
        'svg'  => 'image/svg+xml',
        'jpg'  => 'image/jpeg',
        'jpeg' => 'image/jpeg',
        'gif'  => 'image/gif',
        'ico'  => 'image/x-icon',
        'webp' => 'image/webp',
    ];

    /** @param array{get_runtime?: callable(): mixed} $options */
    public function __construct(?Config $config = null, array $options = [])
    {
        $this->config = $config ?? Config::load();
        $this->scanner = new Scanner($this->config);
        if (isset($options['get_runtime'])) {
            $this->getRuntime = \Closure::fromCallable($options['get_runtime']);
        }
    }

    /**
     * Build a Server directly from already-constructed tools, bypassing Scanner::scan()
     * and any directory/config-file reads. Used by Registry::create(); resources/templates/
     * prompts stay empty since a registry only wires tools.
     *
     * @param array<string, Tool> $tools
     */
    public static function fromTools(array $tools, ?Config $config = null, ?callable $getEnv = null): self
    {
        $server = new self($config ?? new Config([]));
        $server->tools = $tools;
        if ($getEnv !== null) {
            $server->envOverride = \Closure::fromCallable($getEnv);
        }
        return $server;
    }

    /**
     * Load tools (remote first, then local), resources, and prompts from the configured
     * directories. Call this before using handleRequest() directly (serve() calls this
     * automatically). A local scan failure propagates.
     */
    public function loadTools(): void
    {
        $this->loadToolsInternal(false);
    }

    /**
     * @param bool $tolerateScanFailure serve() path: a failed local scan is tolerated when
     *   remote servers, resources or prompts are configured, and exits 1 otherwise.
     */
    private function loadToolsInternal(bool $tolerateScanFailure): void
    {
        $this->tools = [];
        if (!empty($this->config->remote)) {
            $this->tools = (new RemoteManager())->connect($this->config->remote);
        }

        try {
            foreach ($this->scanner->scan() as $name => $tool) {
                if (isset($this->tools[$name])) {
                    Log::write("[zeromcp] Local tool \"$name\" overrides remote\n");
                }
                $this->tools[$name] = $tool;
            }
        } catch (\Throwable $e) {
            if (!$tolerateScanFailure) throw $e;
            if (empty($this->config->remote) && empty($this->config->resourcesDirs) && empty($this->config->promptsDirs)) {
                Log::write("[zeromcp] No tools directory and no remote servers configured\n");
                exit(1);
            }
        }
        Log::write("[zeromcp] " . count($this->tools) . " tool(s) loaded\n");

        $result = $this->scanner->scanResources();
        $this->resources = $result['resources'];
        $this->templates = $result['templates'];
        Log::write("[zeromcp] " . count($this->resources) . " resource(s), " . count($this->templates) . " template(s) loaded\n");

        $this->prompts = $this->scanner->scanPrompts();
        Log::write("[zeromcp] " . count($this->prompts) . " prompt(s) loaded\n");

        $this->icon = $this->resolveIcon($this->config->icon);
    }

    public function buildOpenApiSpec(): array
    {
        $paths = [];

        foreach ($this->tools as $name => $tool) {
            if ($tool->route === null) continue;
            $routeMethod = strtolower($tool->route['method'] ?? 'get');
            $routePath   = $tool->route['path'] ?? '';

            // Convert :param to {param} for OpenAPI
            $openApiPath = preg_replace('/:([a-zA-Z_][a-zA-Z0-9_]*)/', '{$1}', $routePath);

            // Extract path param names from original route
            preg_match_all('/:([a-zA-Z_][a-zA-Z0-9_]*)/', $routePath, $pathParamMatches);
            $pathParamNames = $pathParamMatches[1] ?? [];

            $inputSchema = $tool->cachedSchema;
            $properties  = (array)($inputSchema['properties'] ?? []);
            $required    = $inputSchema['required'] ?? [];

            $operation = [
                'operationId' => $name,
                'description' => $tool->description,
                'responses'   => [
                    '200' => ['description' => 'Success'],
                    '500' => ['description' => 'Error'],
                ],
            ];

            if ($routeMethod === 'get') {
                $parameters = [];
                foreach ($properties as $paramName => $propSchema) {
                    $in = in_array($paramName, $pathParamNames, true) ? 'path' : 'query';
                    $parameters[] = [
                        'name'     => $paramName,
                        'in'       => $in,
                        'required' => $in === 'path' || in_array($paramName, $required, true),
                        'schema'   => $propSchema,
                    ];
                }
                if (!empty($parameters)) {
                    $operation['parameters'] = $parameters;
                }
            } else {
                $bodyProperties = array_diff_key($properties, array_flip($pathParamNames));
                $bodyRequired   = array_values(array_diff($required, $pathParamNames));

                $bodySchema = [
                    'type'       => 'object',
                    'properties' => $bodyProperties,
                ];
                if (!empty($bodyRequired)) {
                    $bodySchema['required'] = $bodyRequired;
                }

                $operation['requestBody'] = [
                    'required' => true,
                    'content'  => [
                        'application/json' => ['schema' => $bodySchema],
                    ],
                ];

                if (!empty($pathParamNames)) {
                    $parameters = [];
                    foreach ($pathParamNames as $paramName) {
                        $parameters[] = [
                            'name'     => $paramName,
                            'in'       => 'path',
                            'required' => true,
                            'schema'   => ['type' => 'string'],
                        ];
                    }
                    $operation['parameters'] = $parameters;
                }
            }

            if (!isset($paths[$openApiPath])) {
                $paths[$openApiPath] = [];
            }
            $paths[$openApiPath][$routeMethod] = $operation;
        }

        return [
            'openapi' => '3.0.0',
            'info'    => [
                'title'   => $this->config->title,
                'version' => '0.5.0',
            ],
            'paths' => empty($paths) ? new \stdClass() : $paths,
        ];
    }

    public function serve(): void
    {
        $this->loadToolsInternal(true);

        if ($this->config->autoloadTools) {
            Log::write("[zeromcp] autoload_tools enabled — watching for changes\n");
            Log::write("[zeromcp] stdio transport ready\n");
            $this->serveWithAutoload();
            return;
        }

        Log::write("[zeromcp] stdio transport ready\n");

        $stdin = fopen('php://stdin', 'r');

        while (($line = fgets($stdin)) !== false) {
            $this->handleLine($line);
        }

        fclose($stdin);
    }

    private function handleLine(string $line): void
    {
        $line = trim($line);
        if ($line === '') return;

        $request = json_decode($line, true);
        if (!is_array($request)) return;

        $response = $this->handleRequest($request);
        if ($response !== null) {
            fwrite(STDOUT, json_encode($response, JSON_UNESCAPED_SLASHES) . "\n");
            fflush(STDOUT);
        }
    }

    /**
     * stdio loop for autoload_tools: stream_select with a 1s timeout so the tool
     * directories can be polled between requests. Stock PHP has no recursive
     * filesystem watcher, so changes are found by comparing mtime/size fingerprints.
     */
    private function serveWithAutoload(): void
    {
        $stdin = fopen('php://stdin', 'r');
        stream_set_blocking($stdin, false);
        $buffer = '';
        $fingerprint = $this->toolFingerprint();
        $lastCheck = microtime(true);

        while (true) {
            $read = [$stdin];
            $write = null;
            $except = null;
            $ready = @stream_select($read, $write, $except, 1);

            if ($ready > 0) {
                $chunk = fread($stdin, 65536);
                if ($chunk === false || ($chunk === '' && feof($stdin))) {
                    if ($buffer !== '') $this->handleLine($buffer);
                    break;
                }
                $buffer .= $chunk;
                while (($pos = strpos($buffer, "\n")) !== false) {
                    $line = substr($buffer, 0, $pos);
                    $buffer = substr($buffer, $pos + 1);
                    $this->handleLine($line);
                }
            }

            if (microtime(true) - $lastCheck >= 1.0) {
                $lastCheck = microtime(true);
                $current = $this->toolFingerprint();
                if ($current !== $fingerprint) {
                    $this->reloadTools($fingerprint, $current);
                    $fingerprint = $current;
                }
            }
        }

        fclose($stdin);
    }

    /**
     * @param array<string, string> $before
     * @param array<string, string> $after
     */
    private function reloadTools(array $before, array $after): void
    {
        $changed = [];
        foreach ($after as $file => $sig) {
            if (($before[$file] ?? null) !== $sig) $changed[] = $file;
        }
        foreach ($before as $file => $_) {
            if (!isset($after[$file])) $changed[] = $file;
        }
        foreach ($changed as $file) {
            Log::write("[zeromcp] Change detected: $file\n");
        }

        // Merge, not replace: tools whose files disappeared stay registered (as in Node).
        foreach ($this->scanner->scan() as $name => $tool) {
            $this->tools[$name] = $tool;
        }

        fwrite(STDOUT, json_encode([
            'jsonrpc' => '2.0',
            'method' => 'notifications/tools/list_changed',
            'params' => new \stdClass(),
        ], JSON_UNESCAPED_SLASHES) . "\n");
        fflush(STDOUT);
    }

    /**
     * mtime/size of every *.php file under each tool source, keyed by path relative
     * to its source directory.
     *
     * @return array<string, string>
     */
    private function toolFingerprint(): array
    {
        clearstatcache();
        $prints = [];
        foreach ($this->config->toolSources as $source) {
            $dir = realpath($source['path']);
            if ($dir === false || !is_dir($dir)) continue;
            $it = new \RecursiveIteratorIterator(
                new \RecursiveDirectoryIterator($dir, \FilesystemIterator::SKIP_DOTS)
            );
            foreach ($it as $file) {
                if (!$file->isFile() || $file->getExtension() !== 'php') continue;
                $path = $file->getPathname();
                $rel = ltrim(substr($path, strlen($dir)), '/');
                $prints[$rel] = $file->getMTime() . ':' . $file->getSize();
            }
        }
        ksort($prints);
        return $prints;
    }

    /**
     * Process a single JSON-RPC request and return a response.
     * Returns null for notifications that require no response.
     *
     * Usage:
     *   $response = $server->handleRequest([
     *       'jsonrpc' => '2.0', 'id' => 1, 'method' => 'tools/list',
     *   ]);
     *
     * Note: tools must be loaded first via serve() or by calling the scanner
     * manually if using this method directly for HTTP integration.
     */
    public function handleRequest(array $request): ?array
    {
        $id = $request['id'] ?? null;
        $method = $request['method'] ?? '';
        $params = $request['params'] ?? [];

        // Notifications (no id)
        if ($id === null) {
            $this->handleNotification($method, $params);
            return null;
        }

        switch ($method) {
            case 'initialize':
                return $this->handleInitialize($id, $params);

            case 'ping':
                return ['jsonrpc' => '2.0', 'id' => $id, 'result' => new \stdClass()];

            // Tools
            case 'tools/list':
                return $this->handleToolsList($id, $params);
            case 'tools/call':
                return ['jsonrpc' => '2.0', 'id' => $id, 'result' => $this->callTool($params)];

            // Resources
            case 'resources/list':
                return $this->handleResourcesList($id, $params);
            case 'resources/read':
                return $this->handleResourcesRead($id, $params);
            case 'resources/subscribe':
                return $this->handleResourcesSubscribe($id, $params);
            case 'resources/templates/list':
                return $this->handleResourcesTemplatesList($id, $params);

            // Prompts
            case 'prompts/list':
                return $this->handlePromptsList($id, $params);
            case 'prompts/get':
                return $this->handlePromptsGet($id, $params);

            // Passthrough
            case 'logging/setLevel':
                return $this->handleLoggingSetLevel($id, $params);
            case 'completion/complete':
                return $this->handleCompletionComplete($id, $params);

            default:
                return [
                    'jsonrpc' => '2.0',
                    'id' => $id,
                    'error' => ['code' => -32601, 'message' => "Method not found: $method"],
                ];
        }
    }

    // --- Notifications ---

    private function handleNotification(string $method, array $params): void
    {
        // notifications/initialized, notifications/roots/list_changed, etc.
        // No response needed.
    }

    // --- Initialize ---

    private function handleInitialize(mixed $id, array $params): array
    {
        $capabilities = [
            'tools' => ['listChanged' => true],
        ];

        if (!empty($this->resources) || !empty($this->templates)) {
            $capabilities['resources'] = ['subscribe' => true, 'listChanged' => true];
        }

        if (!empty($this->prompts)) {
            $capabilities['prompts'] = ['listChanged' => true];
        }

        $capabilities['logging'] = new \stdClass();

        return [
            'jsonrpc' => '2.0',
            'id' => $id,
            'result' => [
                'protocolVersion' => '2024-11-05',
                'capabilities' => $capabilities,
                'serverInfo' => [
                    'name' => 'zeromcp',
                    'version' => '0.2.0',
                ],
            ],
        ];
    }

    // --- Tools ---

    private function handleToolsList(mixed $id, array $params): array
    {
        $cursor = $params['cursor'] ?? null;
        $list = [];
        foreach ($this->tools as $name => $tool) {
            $entry = [
                'name' => $name,
                'description' => $tool->description,
                'inputSchema' => $tool->cachedSchema,
            ];
            if ($this->icon) $entry['icons'] = [['uri' => $this->icon]];
            $list[] = $entry;
        }
        $page = self::paginate($list, $cursor, $this->config->pageSize);
        $result = ['tools' => $page['items']];
        if (isset($page['nextCursor'])) $result['nextCursor'] = $page['nextCursor'];
        return ['jsonrpc' => '2.0', 'id' => $id, 'result' => $result];
    }

    // --- Resources ---

    private function handleResourcesList(mixed $id, array $params): array
    {
        $cursor = $params['cursor'] ?? null;
        $list = [];
        foreach ($this->resources as $res) {
            $entry = [
                'uri' => $res->uri,
                'name' => $res->name,
                'description' => $res->description,
                'mimeType' => $res->mimeType,
            ];
            if ($this->icon) $entry['icons'] = [['uri' => $this->icon]];
            $list[] = $entry;
        }
        $page = self::paginate($list, $cursor, $this->config->pageSize);
        $result = ['resources' => $page['items']];
        if (isset($page['nextCursor'])) $result['nextCursor'] = $page['nextCursor'];
        return ['jsonrpc' => '2.0', 'id' => $id, 'result' => $result];
    }

    private function handleResourcesRead(mixed $id, array $params): array
    {
        $uri = $params['uri'] ?? '';

        // Check static/dynamic resources
        foreach ($this->resources as $res) {
            if ($res->uri === $uri) {
                try {
                    $text = ($res->read)();
                    return ['jsonrpc' => '2.0', 'id' => $id, 'result' => [
                        'contents' => [['uri' => $uri, 'mimeType' => $res->mimeType, 'text' => $text]],
                    ]];
                } catch (\Throwable $e) {
                    return ['jsonrpc' => '2.0', 'id' => $id, 'error' => [
                        'code' => -32603, 'message' => "Error reading resource: {$e->getMessage()}",
                    ]];
                }
            }
        }

        // Check templates
        foreach ($this->templates as $tmpl) {
            $match = self::matchTemplate($tmpl->uriTemplate, $uri);
            if ($match !== null) {
                try {
                    $text = ($tmpl->read)($match);
                    return ['jsonrpc' => '2.0', 'id' => $id, 'result' => [
                        'contents' => [['uri' => $uri, 'mimeType' => $tmpl->mimeType, 'text' => $text]],
                    ]];
                } catch (\Throwable $e) {
                    return ['jsonrpc' => '2.0', 'id' => $id, 'error' => [
                        'code' => -32603, 'message' => "Error reading resource: {$e->getMessage()}",
                    ]];
                }
            }
        }

        return ['jsonrpc' => '2.0', 'id' => $id, 'error' => [
            'code' => -32002, 'message' => "Resource not found: $uri",
        ]];
    }

    private function handleResourcesSubscribe(mixed $id, array $params): array
    {
        $uri = $params['uri'] ?? null;
        if ($uri) $this->subscriptions[$uri] = true;
        return ['jsonrpc' => '2.0', 'id' => $id, 'result' => new \stdClass()];
    }

    private function handleResourcesTemplatesList(mixed $id, array $params): array
    {
        $cursor = $params['cursor'] ?? null;
        $list = [];
        foreach ($this->templates as $tmpl) {
            $entry = [
                'uriTemplate' => $tmpl->uriTemplate,
                'name' => $tmpl->name,
                'description' => $tmpl->description,
                'mimeType' => $tmpl->mimeType,
            ];
            if ($this->icon) $entry['icons'] = [['uri' => $this->icon]];
            $list[] = $entry;
        }
        $page = self::paginate($list, $cursor, $this->config->pageSize);
        $result = ['resourceTemplates' => $page['items']];
        if (isset($page['nextCursor'])) $result['nextCursor'] = $page['nextCursor'];
        return ['jsonrpc' => '2.0', 'id' => $id, 'result' => $result];
    }

    // --- Prompts ---

    private function handlePromptsList(mixed $id, array $params): array
    {
        $cursor = $params['cursor'] ?? null;
        $list = [];
        foreach ($this->prompts as $prompt) {
            $entry = ['name' => $prompt->name];
            if ($prompt->description !== '') $entry['description'] = $prompt->description;
            if (!empty($prompt->arguments)) $entry['arguments'] = $prompt->arguments;
            if ($this->icon) $entry['icons'] = [['uri' => $this->icon]];
            $list[] = $entry;
        }
        $page = self::paginate($list, $cursor, $this->config->pageSize);
        $result = ['prompts' => $page['items']];
        if (isset($page['nextCursor'])) $result['nextCursor'] = $page['nextCursor'];
        return ['jsonrpc' => '2.0', 'id' => $id, 'result' => $result];
    }

    private function handlePromptsGet(mixed $id, array $params): array
    {
        $name = $params['name'] ?? '';
        $args = $params['arguments'] ?? [];

        if (!isset($this->prompts[$name])) {
            return ['jsonrpc' => '2.0', 'id' => $id, 'error' => [
                'code' => -32002, 'message' => "Prompt not found: $name",
            ]];
        }

        try {
            $messages = ($this->prompts[$name]->render)($args);
            return ['jsonrpc' => '2.0', 'id' => $id, 'result' => ['messages' => $messages]];
        } catch (\Throwable $e) {
            return ['jsonrpc' => '2.0', 'id' => $id, 'error' => [
                'code' => -32603, 'message' => "Error rendering prompt: {$e->getMessage()}",
            ]];
        }
    }

    // --- Passthrough ---

    private function handleLoggingSetLevel(mixed $id, array $params): array
    {
        $level = $params['level'] ?? null;
        if ($level) $this->logLevel = $level;
        return ['jsonrpc' => '2.0', 'id' => $id, 'result' => new \stdClass()];
    }

    private function handleCompletionComplete(mixed $id, array $params): array
    {
        return ['jsonrpc' => '2.0', 'id' => $id, 'result' => ['completion' => ['values' => []]]];
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
        $errors = Schema::validate($args, $tool->cachedSchema);

        if (!empty($errors)) {
            return [
                'content' => [['type' => 'text', 'text' => "Validation errors:\n" . implode("\n", $errors)]],
                'isError' => true,
            ];
        }

        try {
            $creds = $this->resolveCredentials($name, $tool);
            $ctx = new Context($name, $creds, $tool->permissions);
            $ctx->bypass = $this->config->bypassPermissions;
            if ($this->getRuntime !== null) {
                $runtime = ($this->getRuntime)();
                if ($runtime !== null) $ctx->runtime = $runtime;
            }

            // Tool-level timeout overrides config default
            $timeoutSecs = $tool->permissions['execute_timeout'] ?? $this->config->executeTimeout;

            // Use pcntl_alarm for timeout if available (POSIX systems)
            // pcntl_async_signals(true) enables signal delivery during blocking
            // calls like sleep(), which pcntl_alarm alone cannot interrupt.
            if (function_exists('pcntl_alarm') && function_exists('pcntl_signal')) {
                if (function_exists('pcntl_async_signals')) {
                    pcntl_async_signals(true);
                }
                pcntl_signal(SIGALRM, function () use ($name, $timeoutSecs) {
                    throw new \RuntimeException("Tool \"$name\" timed out after {$timeoutSecs}s");
                });
                pcntl_alarm((int) $timeoutSecs);
            }

            try {
                $result = $tool->call($args, $ctx);
            } finally {
                if (function_exists('pcntl_alarm')) {
                    pcntl_alarm(0); // Cancel alarm
                }
                if (function_exists('pcntl_async_signals')) {
                    pcntl_async_signals(false);
                }
            }

            $text = is_string($result) ? $result : json_encode($result, JSON_UNESCAPED_SLASHES);
            return ['content' => [['type' => 'text', 'text' => $text]]];
        } catch (\RuntimeException $e) {
            $msg = $e->getMessage();
            $text = str_starts_with($msg, 'Tool "') ? $msg : "Error: $msg";
            return [
                'content' => [['type' => 'text', 'text' => $text]],
                'isError' => true,
            ];
        } catch (\Throwable $e) {
            return [
                'content' => [['type' => 'text', 'text' => "Error: {$e->getMessage()}"]],
                'isError' => true,
            ];
        }
    }

    private function resolveCredentials(string $toolName, ?Tool $tool = null): mixed
    {
        if ($this->envOverride !== null) {
            return ($this->envOverride)();
        }
        if (empty($this->config->credentials)) return null;
        // Scanned tools: credentials are keyed by the tool's first directory segment.
        if ($tool !== null && $tool->credentialNs !== null) {
            $source = $this->config->credentials[$tool->credentialNs] ?? null;
            return is_array($source) ? $this->resolveCredentialsForNs($tool->credentialNs, $source) : null;
        }
        foreach ($this->config->credentials as $ns => $source) {
            $sep = $this->config->separator;
            if (str_starts_with($toolName, "{$ns}_") || str_starts_with($toolName, "{$ns}{$sep}")) {
                return $this->resolveCredentialsForNs((string) $ns, $source);
            }
        }
        return null;
    }

    private function resolveCredentialsForNs(string $ns, array $source): mixed
    {
        if (!$this->config->cacheCredentials) {
            return $this->resolveCredentialSource($source);
        }
        if (array_key_exists($ns, $this->credentialCache)) {
            return $this->credentialCache[$ns];
        }
        $creds = $this->resolveCredentialSource($source);
        $this->credentialCache[$ns] = $creds;
        return $creds;
    }

    private function resolveCredentialSource(array $source): mixed
    {
        if (!empty($source['env'])) {
            $val = getenv($source['env']);
            if ($val === false || $val === '') return null;
            $decoded = json_decode($val, true);
            return $decoded !== null ? $decoded : $val;
        }
        if (!empty($source['file'])) {
            $path = $source['file'];
            if (str_starts_with($path, '~')) $path = getenv('HOME') . substr($path, 1);
            if (!file_exists($path)) return null;
            $val = trim(file_get_contents($path));
            $decoded = json_decode($val, true);
            return $decoded !== null ? $decoded : $val;
        }
        return null;
    }

    // --- Utilities ---

    /**
     * Base64 cursor-based pagination. pageSize 0 = no pagination.
     *
     * @return array{items: array, nextCursor?: string}
     */
    private static function paginate(array $items, ?string $cursor, int $pageSize): array
    {
        if ($pageSize <= 0) {
            return ['items' => $items];
        }

        $offset = 0;
        if ($cursor !== null && $cursor !== '') {
            $decoded = base64_decode($cursor, true);
            if ($decoded !== false) {
                $offset = max(0, (int) $decoded);
            }
        }

        $slice = array_slice($items, $offset, $pageSize);
        $hasMore = ($offset + $pageSize) < count($items);

        $result = ['items' => $slice];
        if ($hasMore) {
            $result['nextCursor'] = base64_encode((string) ($offset + $pageSize));
        }
        return $result;
    }

    /**
     * Match a URI against a URI template with {param} placeholders.
     *
     * @return array<string,string>|null matched params or null
     */
    private static function matchTemplate(string $template, string $uri): ?array
    {
        // Extract {param} placeholders first, then quote the rest
        $parts = preg_split('/(\{(\w+)\})/', $template, -1, PREG_SPLIT_DELIM_CAPTURE);
        $regex = '';
        for ($i = 0; $i < count($parts); $i++) {
            if ($i % 3 === 0) {
                // Literal segment
                $regex .= preg_quote($parts[$i], '/');
            } elseif ($i % 3 === 1) {
                // Full match "{param}" — use named group from next element
                $paramName = $parts[$i + 1];
                $regex .= '(?P<' . $paramName . '>[^\/]+)';
                $i++; // skip the param name part
            }
        }

        if (preg_match('/^' . $regex . '$/', $uri, $matches)) {
            $params = [];
            foreach ($matches as $key => $value) {
                if (is_string($key)) {
                    $params[$key] = $value;
                }
            }
            return $params;
        }

        return null;
    }

    /**
     * Resolve an icon config value to a data URI at startup.
     * Accepts: data URI (passthrough), URL (fetched), file path (read).
     */
    private function resolveIcon(?string $icon): ?string
    {
        if ($icon === null || $icon === '') return null;

        // Already a data URI
        if (str_starts_with($icon, 'data:')) return $icon;

        // URL — fetch and convert
        if (str_starts_with($icon, 'http://') || str_starts_with($icon, 'https://')) {
            try {
                $ctx = stream_context_create(['http' => ['timeout' => 10]]);
                $data = @file_get_contents($icon, false, $ctx);
                if ($data === false) {
                    Log::write("[zeromcp] Warning: failed to fetch icon $icon\n");
                    return null;
                }
                // Try to get content-type from response headers
                $contentType = 'image/png';
                if (isset($http_response_header)) {
                    foreach ($http_response_header as $header) {
                        if (stripos($header, 'content-type:') === 0) {
                            $contentType = trim(substr($header, 13));
                            break;
                        }
                    }
                }
                return 'data:' . $contentType . ';base64,' . base64_encode($data);
            } catch (\Throwable $e) {
                Log::write("[zeromcp] Warning: failed to fetch icon $icon: {$e->getMessage()}\n");
                return null;
            }
        }

        // File path
        try {
            $path = $icon;
            if (str_starts_with($path, '~')) {
                $path = (getenv('HOME') ?: '') . substr($path, 1);
            }
            if (!file_exists($path)) {
                Log::write("[zeromcp] Warning: icon file not found: $path\n");
                return null;
            }
            $data = file_get_contents($path);
            if ($data === false) {
                Log::write("[zeromcp] Warning: failed to read icon file: $path\n");
                return null;
            }
            $ext = strtolower(pathinfo($path, PATHINFO_EXTENSION));
            $mime = self::ICON_MIME[$ext] ?? 'image/png';
            return 'data:' . $mime . ';base64,' . base64_encode($data);
        } catch (\Throwable $e) {
            Log::write("[zeromcp] Warning: failed to read icon file $icon: {$e->getMessage()}\n");
            return null;
        }
    }
}
