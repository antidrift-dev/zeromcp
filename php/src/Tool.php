<?php

namespace ZeroMcp;

class Tool
{
    public string $name;
    public string $description;
    public array $input;
    public array $permissions;
    /** @var callable */
    public $execute;
    /** Pre-computed JSON Schema for $input, set at load time. */
    public array $cachedSchema;
    /** Optional HTTP route: ['method' => 'GET'|'POST'|..., 'path' => '/:param/...'] */
    public ?array $route;

    public function __construct(
        string $name,
        string $description = '',
        array $input = [],
        array $permissions = [],
        ?callable $execute = null,
        ?array $route = null
    ) {
        $this->name = $name;
        $this->description = $description;
        $this->input = $input;
        $this->permissions = $permissions;
        $this->execute = $execute;
        $this->cachedSchema = Schema::toJsonSchema($input);
        $this->route = $route;
    }

    public function call(array $args, ?Context $ctx = null): mixed
    {
        return ($this->execute)($args, $ctx);
    }
}

class Context
{
    public string $toolName;
    public mixed $credentials;
    public array $permissions;
    public bool $bypass;

    public function __construct(string $toolName, mixed $credentials = null, array $permissions = [], bool $bypass = false)
    {
        $this->toolName = $toolName;
        $this->credentials = $credentials;
        $this->permissions = $permissions;
        $this->bypass = $bypass;
    }
}
