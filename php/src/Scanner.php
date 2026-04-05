<?php

namespace ZeroMcp;

class Scanner
{
    private Config $config;
    /** @var array<string, Tool> */
    private array $tools = [];

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
}
