<?php

namespace ZeroMcp;

class Scanner
{
    private Config $config;
    /** @var array<string, Tool> */
    private array $tools = [];
    /** @var array<string, Resource> */
    private array $resources = [];
    /** @var array<string, ResourceTemplate> */
    private array $templates = [];
    /** @var array<string, Prompt> */
    private array $prompts = [];

    private const MIME_MAP = [
        'json' => 'application/json',
        'txt'  => 'text/plain',
        'md'   => 'text/markdown',
        'html' => 'text/html',
        'xml'  => 'application/xml',
        'yaml' => 'text/yaml',
        'yml'  => 'text/yaml',
        'csv'  => 'text/csv',
        'css'  => 'text/css',
        'sql'  => 'text/plain',
        'sh'   => 'text/plain',
        'py'   => 'text/plain',
        'rb'   => 'text/plain',
        'go'   => 'text/plain',
        'rs'   => 'text/plain',
        'toml' => 'text/plain',
        'ini'  => 'text/plain',
        'env'  => 'text/plain',
    ];

    public function __construct(Config $config)
    {
        $this->config = $config;
    }

    /** @return array<string, Tool> */
    public function scan(): array
    {
        $this->tools = [];
        $dirs = $this->config->toolsDirs;

        foreach ($dirs as $d) {
            $dir = realpath($d) ?: $d;
            if (!is_dir($dir)) {
                fwrite(STDERR, "[zeromcp] Cannot read tools directory: $dir\n");
                continue;
            }
            $this->scanDir($dir, $dir);
        }

        return $this->tools;
    }

    /**
     * Scan resource directories. Static files served via file_get_contents.
     * PHP files with a read() function are dynamic resources.
     * PHP files returning uriTemplate are resource templates.
     *
     * @return array{resources: array<string, Resource>, templates: array<string, ResourceTemplate>}
     */
    public function scanResources(): array
    {
        $this->resources = [];
        $this->templates = [];

        foreach ($this->config->resourcesDirs as $d) {
            $dir = realpath($d) ?: $d;
            if (!is_dir($dir)) {
                fwrite(STDERR, "[zeromcp] Cannot read resources directory: $dir\n");
                continue;
            }
            $this->scanResourceDir($dir, $dir);
        }

        return ['resources' => $this->resources, 'templates' => $this->templates];
    }

    /**
     * Scan prompt directories. PHP files must define a render($args) function.
     *
     * @return array<string, Prompt>
     */
    public function scanPrompts(): array
    {
        $this->prompts = [];

        foreach ($this->config->promptsDirs as $d) {
            $dir = realpath($d) ?: $d;
            if (!is_dir($dir)) {
                fwrite(STDERR, "[zeromcp] Cannot read prompts directory: $dir\n");
                continue;
            }
            $this->scanPromptDir($dir, $dir);
        }

        return $this->prompts;
    }

    /** @return array<string, Tool> */
    public function getTools(): array
    {
        return $this->tools;
    }

    private function scanDir(string $dir, string $rootDir): void
    {
        $entries = scandir($dir);
        foreach ($entries as $entry) {
            if ($entry[0] === '.') continue;

            $fullPath = $dir . '/' . $entry;

            if (is_dir($fullPath)) {
                $this->scanDir($fullPath, $rootDir);
                continue;
            }

            if (pathinfo($entry, PATHINFO_EXTENSION) !== 'php') continue;

            $this->loadTool($fullPath, $rootDir);
        }
    }

    private function loadTool(string $filePath, string $rootDir): void
    {
        $name = $this->buildName($filePath, $rootDir);

        try {
            $toolDef = require $filePath;

            if (!is_array($toolDef) || !isset($toolDef['execute'])) {
                return;
            }

            $permissions = $toolDef['permissions'] ?? [];
            $this->logPermissions($name, $permissions);

            $this->tools[$name] = new Tool(
                name: $name,
                description: $toolDef['description'] ?? '',
                input: $toolDef['input'] ?? [],
                permissions: $permissions,
                execute: $toolDef['execute']
            );

            fwrite(STDERR, "[zeromcp] Loaded: $name\n");
        } catch (\Throwable $e) {
            $rel = $this->relativePath($filePath, $rootDir);
            fwrite(STDERR, "[zeromcp] Error loading $rel: {$e->getMessage()}\n");
        }
    }

    private function buildName(string $filePath, string $rootDir): string
    {
        $rel = $this->relativePath($filePath, $rootDir);
        $parts = explode('/', $rel);
        $file = array_pop($parts);
        $filename = pathinfo($file, PATHINFO_FILENAME);

        if (count($parts) > 0) {
            $dirPrefix = $parts[0];
            return $dirPrefix . $this->config->separator . $filename;
        }

        return $filename;
    }

    private function relativePath(string $path, string $base): string
    {
        return ltrim(str_replace($base, '', $path), '/');
    }

    private function logPermissions(string $name, array $permissions): void
    {
        $elevated = [];
        if (!empty($permissions['fs'])) $elevated[] = 'fs: ' . $permissions['fs'];
        if (!empty($permissions['exec'])) $elevated[] = 'exec';

        if (!empty($elevated)) {
            fwrite(STDERR, "[zeromcp] $name requests elevated permissions: " . implode(' | ', $elevated) . "\n");
        }
    }

    // --- Resource scanning ---

    private function scanResourceDir(string $dir, string $rootDir): void
    {
        $entries = scandir($dir);
        foreach ($entries as $entry) {
            if ($entry[0] === '.') continue;

            $fullPath = $dir . '/' . $entry;

            if (is_dir($fullPath)) {
                $this->scanResourceDir($fullPath, $rootDir);
                continue;
            }

            $ext = pathinfo($entry, PATHINFO_EXTENSION);

            if ($ext === 'php') {
                $this->loadDynamicResource($fullPath, $rootDir);
            } else {
                $this->loadStaticResource($fullPath, $rootDir, $ext);
            }
        }
    }

    private function loadStaticResource(string $filePath, string $rootDir, string $ext): void
    {
        $relPath = $this->relativePath($filePath, $rootDir);
        $name = preg_replace('/\.[^.]+$/', '', $relPath);
        $name = str_replace('/', $this->config->separator, $name);
        $uri = 'resource:///' . str_replace('\\', '/', $relPath);
        $mimeType = self::MIME_MAP[$ext] ?? 'application/octet-stream';

        $this->resources[$name] = new Resource(
            uri: $uri,
            name: $name,
            description: "Static resource: $relPath",
            mimeType: $mimeType,
            read: function () use ($filePath): string {
                return file_get_contents($filePath);
            }
        );

        fwrite(STDERR, "[zeromcp] Resource loaded: $name ($uri)\n");
    }

    private function loadDynamicResource(string $filePath, string $rootDir): void
    {
        $relPath = $this->relativePath($filePath, $rootDir);
        $name = preg_replace('/\.php$/', '', $relPath);
        $name = str_replace('/', $this->config->separator, $name);

        try {
            $def = require $filePath;

            if (!is_array($def) || !isset($def['read']) || !is_callable($def['read'])) {
                fwrite(STDERR, "[zeromcp] Resource $relPath: missing read() function\n");
                return;
            }

            if (isset($def['uriTemplate'])) {
                // Resource template
                $this->templates[$name] = new ResourceTemplate(
                    uriTemplate: $def['uriTemplate'],
                    name: $name,
                    description: $def['description'] ?? '',
                    mimeType: $def['mimeType'] ?? 'text/plain',
                    read: $def['read']
                );
                fwrite(STDERR, "[zeromcp] Resource template loaded: $name ({$def['uriTemplate']})\n");
            } else {
                $uri = $def['uri'] ?? "resource:///$name";
                $this->resources[$name] = new Resource(
                    uri: $uri,
                    name: $name,
                    description: $def['description'] ?? '',
                    mimeType: $def['mimeType'] ?? 'application/json',
                    read: $def['read']
                );
                fwrite(STDERR, "[zeromcp] Resource loaded: $name ($uri)\n");
            }
        } catch (\Throwable $e) {
            fwrite(STDERR, "[zeromcp] Error loading resource $relPath: {$e->getMessage()}\n");
        }
    }

    // --- Prompt scanning ---

    private function scanPromptDir(string $dir, string $rootDir): void
    {
        $entries = scandir($dir);
        foreach ($entries as $entry) {
            if ($entry[0] === '.') continue;

            $fullPath = $dir . '/' . $entry;

            if (is_dir($fullPath)) {
                $this->scanPromptDir($fullPath, $rootDir);
                continue;
            }

            if (pathinfo($entry, PATHINFO_EXTENSION) !== 'php') continue;

            $this->loadPrompt($fullPath, $rootDir);
        }
    }

    private function loadPrompt(string $filePath, string $rootDir): void
    {
        $relPath = $this->relativePath($filePath, $rootDir);
        $name = preg_replace('/\.php$/', '', $relPath);
        $name = str_replace('/', $this->config->separator, $name);

        try {
            $def = require $filePath;

            if (!is_array($def) || !isset($def['render']) || !is_callable($def['render'])) {
                fwrite(STDERR, "[zeromcp] Prompt $relPath: missing render() function\n");
                return;
            }

            // Convert arguments shorthand to MCP prompt arguments
            $promptArgs = [];
            if (isset($def['arguments']) && is_array($def['arguments'])) {
                foreach ($def['arguments'] as $key => $val) {
                    if (is_string($val)) {
                        $promptArgs[] = ['name' => $key, 'required' => true];
                    } elseif (is_array($val)) {
                        $arg = ['name' => $key];
                        if (isset($val['description'])) $arg['description'] = $val['description'];
                        $arg['required'] = empty($val['optional']);
                        $promptArgs[] = $arg;
                    }
                }
            }

            $this->prompts[$name] = new Prompt(
                name: $name,
                description: $def['description'] ?? '',
                arguments: $promptArgs,
                render: $def['render']
            );

            fwrite(STDERR, "[zeromcp] Prompt loaded: $name\n");
        } catch (\Throwable $e) {
            fwrite(STDERR, "[zeromcp] Error loading prompt $relPath: {$e->getMessage()}\n");
        }
    }
}
