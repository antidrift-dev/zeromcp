<?php

namespace ZeroMcp;

class Config
{
    public array $toolsDirs;
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

    public function __construct(array $opts = [])
    {
        $tools = $opts['tools'] ?? './tools';
        $this->toolsDirs = is_array($tools) ? $tools : [$tools];

        $resources = $opts['resources'] ?? [];
        $this->resourcesDirs = is_array($resources) ? $resources : [$resources];

        $prompts = $opts['prompts'] ?? [];
        $this->promptsDirs = is_array($prompts) ? $prompts : [$prompts];

        $this->separator = $opts['separator'] ?? '_';
        $this->logging = $opts['logging'] ?? false;
        $this->bypassPermissions = $opts['bypass_permissions'] ?? false;
        $this->executeTimeout = $opts['execute_timeout'] ?? 30;
        $this->credentials = $opts['credentials'] ?? [];
        $this->cacheCredentials = $opts['cache_credentials'] ?? true;
        $this->pageSize = $opts['page_size'] ?? 0;
        $this->icon = $opts['icon'] ?? null;
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
