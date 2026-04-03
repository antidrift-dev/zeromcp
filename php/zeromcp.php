#!/usr/bin/env php
<?php

require_once __DIR__ . '/src/Schema.php';
require_once __DIR__ . '/src/Config.php';
require_once __DIR__ . '/src/Tool.php';
require_once __DIR__ . '/src/Scanner.php';
require_once __DIR__ . '/src/Server.php';

$command = $argv[1] ?? null;
$toolsDir = $argv[2] ?? null;

if ($command !== 'serve') {
    fwrite(STDERR, "Usage: zeromcp serve [tools-directory]\n");
    exit(1);
}

$config = ZeroMcp\Config::load();
if ($toolsDir) {
    $config = new ZeroMcp\Config(['tools' => $toolsDir]);
}

$server = new ZeroMcp\Server($config);
$server->serve();
