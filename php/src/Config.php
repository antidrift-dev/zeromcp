<?php

namespace ZeroMcp;

class Config
{
    public array $toolsDirs;
    public string $separator;
    public bool $logging;
    public bool $bypassPermissions;
    public int $executeTimeout;
    public array $credentials;

    public function __construct(array $opts = [])
    {
        $tools = $opts['tools'] ?? './tools';
        $this->toolsDirs = is_array($tools) ? $tools : [$tools];
        $this->separator = $opts['separator'] ?? '_';
        $this->logging = $opts['logging'] ?? false;
        $this->bypassPermissions = $opts['bypass_permissions'] ?? false;
        $this->executeTimeout = $opts['execute_timeout'] ?? 30;
        $this->credentials = $opts['credentials'] ?? [];
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
