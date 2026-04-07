#!/usr/bin/env php
<?php

require_once __DIR__ . '/src/Schema.php';
require_once __DIR__ . '/src/Config.php';
require_once __DIR__ . '/src/Tool.php';
require_once __DIR__ . '/src/Resource.php';
require_once __DIR__ . '/src/Prompt.php';
require_once __DIR__ . '/src/Sandbox.php';
require_once __DIR__ . '/src/Scanner.php';
require_once __DIR__ . '/src/Server.php';

// Parse --config flag from argv
$configPath = null;
$filteredArgs = [];
for ($i = 1; $i < count($argv); $i++) {
    if ($argv[$i] === '--config' && isset($argv[$i + 1])) {
        $configPath = $argv[$i + 1];
        $i++; // skip next arg
    } else {
        $filteredArgs[] = $argv[$i];
    }
}

$command = $filteredArgs[0] ?? null;
$toolsDir = $filteredArgs[1] ?? null;

if ($command !== 'serve') {
    fwrite(STDERR, "Usage: zeromcp serve [tools-directory] [--config <path>]\n");
    exit(1);
}

if ($configPath) {
    $data = json_decode(file_get_contents($configPath), true);
    $config = new ZeroMcp\Config($data ?? []);
} else {
    $config = ZeroMcp\Config::load();
    if ($toolsDir) {
        $config = new ZeroMcp\Config(['tools' => $toolsDir]);
    }
}

$server = new ZeroMcp\Server($config);
$server->serve();
