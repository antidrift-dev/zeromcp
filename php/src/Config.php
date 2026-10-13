<?php

namespace ZeroMcp;

class Config
{
    /** @var string[] tool source paths (derived from $toolSources) */
    public array $toolsDirs;
    /** @var array<int, array{path: string, prefix: ?string}> */
    public array $toolSources;
    /** @var array<string, array{prefix?: string}> */
    public array $namespacing;
    /** @var array<int, array{name: string, url: string, auth?: string, tools?: string[]}> */
    public array $remote;
    public bool $autoloadTools;
    public array $resourcesDirs;
    public array $promptsDirs;
    public string $separator;
    public bool $logging;
    public bool $bypassPermissions;
    public int $executeTimeout;
    public array $credentials;
    public bool $cacheCredentials;
    public int $pageSize;
    public ?string $icon;
    public string $title;

    public const HTTP_TRANSPORT_REMOVED = '[zeromcp] The "http" transport has been removed. ZeroMCP does not ship an HTTP server. '
        . 'Mount ZeroMcp\\Registry::create($tools) (->routes, ->openapi, ->mcp()) or Server::handleRequest() in your own HTTP server.';

    public function __construct(array $opts = [])
    {
        self::rejectHttpTransport($opts['transport'] ?? null);

        $this->toolSources = self::resolveSources($opts['tools'] ?? './tools');
        $this->toolsDirs = array_column($this->toolSources, 'path');
        $this->namespacing = is_array($opts['namespacing'] ?? null) ? $opts['namespacing'] : [];
        $this->remote = is_array($opts['remote'] ?? null) ? $opts['remote'] : [];
        $this->autoloadTools = (bool) ($opts['autoload_tools'] ?? false);

        $this->resourcesDirs = array_column(self::resolveSources($opts['resources'] ?? []), 'path');
        $this->promptsDirs = array_column(self::resolveSources($opts['prompts'] ?? []), 'path');

        $this->separator = $opts['separator'] ?? '_';
        $this->logging = $opts['logging'] ?? false;
        $this->bypassPermissions = $opts['bypass_permissions'] ?? false;
        $this->executeTimeout = $opts['execute_timeout'] ?? 30;
        $this->credentials = $opts['credentials'] ?? [];
        $this->cacheCredentials = $opts['cache_credentials'] ?? true;
        $this->pageSize = $opts['page_size'] ?? 0;
        $this->icon = $opts['icon'] ?? null;
        $this->title = $opts['title'] ?? 'ZeroMCP';
    }

    /**
     * Normalize `string | (string | {path, prefix?})[]` into a list of {path, prefix}.
     *
     * @return array<int, array{path: string, prefix: ?string}>
     */
    private static function resolveSources(mixed $value): array
    {
        $entries = is_array($value) ? $value : [$value];
        $sources = [];
        foreach ($entries as $entry) {
            if (is_array($entry)) {
                $sources[] = ['path' => (string) ($entry['path'] ?? ''), 'prefix' => $entry['prefix'] ?? null];
            } else {
                $sources[] = ['path' => (string) $entry, 'prefix' => null];
            }
        }
        return $sources;
    }

    /** ZeroMCP ships no HTTP server: any `http` transport entry is a startup error. */
    private static function rejectHttpTransport(mixed $transport): void
    {
        if (!is_array($transport)) return;
        $entries = array_is_list($transport) ? $transport : [$transport];
        foreach ($entries as $entry) {
            if (is_array($entry) && ($entry['type'] ?? null) === 'http') {
                throw new \InvalidArgumentException(self::HTTP_TRANSPORT_REMOVED);
            }
        }
    }

    /**
     * Resolve a remote server's `auth` value: `env:VAR` reads the environment
     * variable (warning when unset), anything else is used as-is.
     */
    public static function resolveAuth(?string $auth): ?string
    {
        if ($auth === null || $auth === '') return null;

        if (str_starts_with($auth, 'env:')) {
            $envVar = substr($auth, 4);
            $value = getenv($envVar);
            if ($value === false || $value === '') {
                Log::write("[zeromcp] Warning: environment variable $envVar not set\n");
            }
            return $value === false ? null : $value;
        }

        return $auth;
    }

    public static function load(?string $path = null): self
    {
        $path = $path ?? getcwd() . '/zeromcp.config.json';
        if (!file_exists($path)) {
            return new self();
        }

        $raw = file_get_contents($path);
        $data = json_decode($raw, true);
        if (!is_array($data)) {
            return new self();
        }

        return new self($data);
    }
}
