<?php

namespace ZeroMcp;

/**
 * Connects to remote MCP servers over HTTP and exposes their tools locally,
 * keyed "<server.name>.<toolName>". Port of nodejs/src/remote.ts.
 */
final class RemoteManager
{
    /**
     * @param array<int, array{name: string, url: string, auth?: string, tools?: string[]}> $servers
     * @return array<string, Tool>  keyed "<server.name>.<toolName>"
     */
    public function connect(array $servers): array
    {
        $allTools = [];

        foreach ($servers as $server) {
            $serverName = $server['name'] ?? '';
            try {
                $tools = $this->connectOne($server);
                foreach ($tools as $toolName => $tool) {
                    $namespacedName = "{$serverName}.{$toolName}";
                    $allTools[$namespacedName] = $tool;
                    Log::write("[mcp] Remote tool: $namespacedName\n");
                }
            } catch (\Throwable $e) {
                Log::write("[mcp] Failed to connect to {$serverName}: {$e->getMessage()}\n");
            }
        }

        return $allTools;
    }

    /** @return array<string, Tool> */
    private function connectOne(array $server): array
    {
        $url = (string) ($server['url'] ?? '');
        if (!str_starts_with($url, 'http://') && !str_starts_with($url, 'https://')) {
            throw new \RuntimeException("Remote server \"{$server['name']}\" must have an HTTP/HTTPS URL, got: $url");
        }
        return $this->connectHttp($server);
    }

    /** @return array<string, Tool> */
    private function connectHttp(array $server): array
    {
        $tools = [];
        $url = $server['url'];
        $auth = Config::resolveAuth($server['auth'] ?? null);

        // Initialize
        $this->httpRpc($url, [
            'jsonrpc' => '2.0', 'id' => 1, 'method' => 'initialize', 'params' => new \stdClass(),
        ], $auth);

        // List tools
        $listRes = $this->httpRpc($url, [
            'jsonrpc' => '2.0', 'id' => 2, 'method' => 'tools/list', 'params' => new \stdClass(),
        ], $auth);

        $remoteTools = $listRes['result']['tools'] ?? [];
        if (!is_array($remoteTools)) $remoteTools = [];
        $allow = $server['tools'] ?? null;

        foreach ($remoteTools as $rt) {
            if (!is_array($rt) || !isset($rt['name'])) continue;
            if ($allow !== null && !in_array($rt['name'], $allow, true)) continue;

            $remoteName = $rt['name'];
            $input = $this->schemaToInput($rt['inputSchema'] ?? null);

            $tools[$remoteName] = new Tool(
                name: $remoteName,
                description: $rt['description'] ?? '',
                input: $input,
                execute: function (array $args, ?Context $ctx = null) use ($url, $remoteName, $auth): mixed {
                    $callRes = $this->httpRpc($url, [
                        'jsonrpc' => '2.0',
                        'id' => (int) (microtime(true) * 1000),
                        'method' => 'tools/call',
                        'params' => ['name' => $remoteName, 'arguments' => (object) $args],
                    ], $auth);

                    $text = $callRes['result']['content'][0]['text'] ?? null;
                    if ($text) return $text;
                    return $callRes['result'] ?? null;
                },
            );
        }

        Log::write("[mcp] Connected to {$server['name']} (HTTP): " . count($tools) . " tool(s)\n");
        return $tools;
    }

    private function httpRpc(string $url, array $body, ?string $auth): ?array
    {
        $headers = ['Content-Type: application/json'];
        if ($auth) $headers[] = "Authorization: Bearer $auth";

        $ctx = stream_context_create(['http' => [
            'method' => 'POST',
            'header' => implode("\r\n", $headers),
            'content' => json_encode($body, JSON_UNESCAPED_SLASHES),
            'ignore_errors' => true,
        ]]);

        $raw = @file_get_contents($url, false, $ctx);
        // PHP 8.4+ exposes the headers via a function; $http_response_header is
        // deprecated from 8.5 but is the only option on 8.1-8.3.
        $responseHeaders = function_exists('http_get_last_response_headers')
            ? http_get_last_response_headers()
            : ($http_response_header ?? null);
        $statusLine = $responseHeaders[0] ?? null;
        if ($raw === false && $statusLine === null) {
            $err = error_get_last();
            throw new \RuntimeException($err['message'] ?? "Request to $url failed");
        }

        $status = 0;
        if ($statusLine !== null && preg_match('#^HTTP/\S+\s+(\d{3})#', $statusLine, $m)) {
            $status = (int) $m[1];
        }
        if ($status < 200 || $status > 299) {
            throw new \RuntimeException("HTTP $status");
        }

        $decoded = json_decode((string) $raw, true);
        if (!is_array($decoded)) {
            throw new \RuntimeException('Invalid JSON response');
        }
        return $decoded;
    }

    private function schemaToInput(mixed $schema): array
    {
        $input = [];
        if (!is_array($schema) || empty($schema['properties']) || !is_array($schema['properties'])) {
            return $input;
        }
        $required = is_array($schema['required'] ?? null) ? $schema['required'] : [];

        foreach ($schema['properties'] as $key => $prop) {
            $p = is_array($prop) ? $prop : [];
            $isRequired = in_array($key, $required, true);
            $type = !empty($p['type']) ? $p['type'] : 'string';

            if (!empty($p['description']) || !$isRequired) {
                $entry = ['type' => $type];
                if (!empty($p['description'])) $entry['description'] = $p['description'];
                if (!$isRequired) $entry['optional'] = true;
                $input[$key] = $entry;
            } else {
                $input[$key] = $type;
            }
        }

        return $input;
    }
}
