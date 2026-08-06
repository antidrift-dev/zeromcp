<?php

namespace ZeroMcp;

final class RouteDefinition
{
    public function __construct(
        public string $name,
        public string $method,
        public string $path,
        public Tool $tool,
    ) {}
}

final class Registry
{
    /** @var RouteDefinition[] */
    public array $routes;

    /** Pre-built OpenAPI 3.0 document, same shape Server::buildOpenApiSpec() produces. */
    public array $openapi;

    private Server $server;

    private function __construct(array $routes, array $openapi, Server $server)
    {
        $this->routes = $routes;
        $this->openapi = $openapi;
        $this->server = $server;
    }

    /**
     * @param array<string, Tool|array> $tools  Tool objects, or raw tool-definition
     *   arrays in the same shape a tool file returns (description/input/permissions/
     *   execute/route). Mixed maps of both are fine.
     * @param array{
     *   get_env?: callable(): mixed,
     *   config?: Config,
     * } $options
     */
    public static function create(array $tools, array $options = []): self
    {
        $normalized = [];
        foreach ($tools as $name => $tool) {
            $normalized[$name] = $tool instanceof Tool ? $tool : Tool::fromDefinition($name, $tool);
        }

        $server = Server::fromTools($normalized, $options['config'] ?? null, $options['get_env'] ?? null);

        $routes = [];
        foreach ($normalized as $name => $tool) {
            if ($tool->route === null) continue;
            $routes[] = new RouteDefinition($name, strtoupper($tool->route['method'] ?? 'GET'), $tool->route['path'] ?? '/', $tool);
        }

        return new self($routes, $server->buildOpenApiSpec(), $server);
    }

    /** JSON-RPC handler. Synchronous — PHP has no async/await. */
    public function mcp(array $request): ?array
    {
        return $this->server->handleRequest($request);
    }
}
