<?php

require_once __DIR__ . '/../src/Schema.php';
require_once __DIR__ . '/../src/Config.php';
require_once __DIR__ . '/../src/Tool.php';
require_once __DIR__ . '/../src/Resource.php';
require_once __DIR__ . '/../src/Prompt.php';
require_once __DIR__ . '/../src/Scanner.php';

use ZeroMcp\Config;
use ZeroMcp\Scanner;

class ScannerTest
{
    private int $passed = 0;
    private int $failed = 0;

    public function run(): void
    {
        $this->testScanLoadsTools();

        echo "\n{$this->passed} passed, {$this->failed} failed\n";
        if ($this->failed > 0) exit(1);
    }

    private function assert(bool $condition, string $message): void
    {
        if ($condition) {
            $this->passed++;
            echo "  PASS: $message\n";
        } else {
            $this->failed++;
            echo "  FAIL: $message\n";
        }
    }

    private function testScanLoadsTools(): void
    {
        $config = new Config(['tools' => __DIR__ . '/../tools']);
        $scanner = new Scanner($config);
        $tools = $scanner->scan();

        $this->assert(isset($tools['hello']), 'hello tool loaded');
        $this->assert($tools['hello']->description === 'Say hello', 'description correct');

        $result = $tools['hello']->call(['name' => 'World']);
        $this->assert($result === 'Hello, World!', 'execute returns correct result');
    }
}

echo "Scanner Tests:\n";
$test = new ScannerTest();
$test->run();
