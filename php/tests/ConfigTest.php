<?php

require_once __DIR__ . '/../src/Config.php';

use ZeroMcp\Config;

class ConfigTest
{
    private int $passed = 0;
    private int $failed = 0;

    public function run(): void
    {
        $this->testDefaults();
        $this->testToolsDirString();
        $this->testToolsDirArray();
        $this->testResourcesDirs();
        $this->testPromptsDirs();
        $this->testSeparator();
        $this->testPageSize();
        $this->testIcon();
        $this->testExecuteTimeout();
        $this->testBypassPermissions();
        $this->testCredentials();
        $this->testLoadMissingFile();

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

    private function testDefaults(): void
    {
        $config = new Config();
        $this->assert($config->toolsDirs === ['./tools'], 'default tools dir');
        $this->assert($config->resourcesDirs === [], 'default resources dirs empty');
        $this->assert($config->promptsDirs === [], 'default prompts dirs empty');
        $this->assert($config->separator === '_', 'default separator');
        $this->assert($config->logging === false, 'default logging off');
        $this->assert($config->bypassPermissions === false, 'default bypass off');
        $this->assert($config->executeTimeout === 30, 'default timeout 30');
        $this->assert($config->pageSize === 0, 'default pageSize 0');
        $this->assert($config->icon === null, 'default icon null');
    }

    private function testToolsDirString(): void
    {
        $config = new Config(['tools' => '/my/tools']);
        $this->assert($config->toolsDirs === ['/my/tools'], 'string tools coerced to array');
    }

    private function testToolsDirArray(): void
    {
        $config = new Config(['tools' => ['/a', '/b']]);
        $this->assert($config->toolsDirs === ['/a', '/b'], 'array tools preserved');
    }

    private function testResourcesDirs(): void
    {
        $config = new Config(['resources' => '/res']);
        $this->assert($config->resourcesDirs === ['/res'], 'string resources coerced to array');

        $config2 = new Config(['resources' => ['/r1', '/r2']]);
        $this->assert($config2->resourcesDirs === ['/r1', '/r2'], 'array resources preserved');
    }

    private function testPromptsDirs(): void
    {
        $config = new Config(['prompts' => '/prompts']);
        $this->assert($config->promptsDirs === ['/prompts'], 'string prompts coerced to array');
    }

    private function testSeparator(): void
    {
        $config = new Config(['separator' => '.']);
        $this->assert($config->separator === '.', 'custom separator');
    }

    private function testPageSize(): void
    {
        $config = new Config(['page_size' => 10]);
        $this->assert($config->pageSize === 10, 'custom page size');
    }

    private function testIcon(): void
    {
        $config = new Config(['icon' => 'data:image/png;base64,abc']);
        $this->assert($config->icon === 'data:image/png;base64,abc', 'icon data URI preserved');
    }

    private function testExecuteTimeout(): void
    {
        $config = new Config(['execute_timeout' => 60]);
        $this->assert($config->executeTimeout === 60, 'custom timeout');
    }

    private function testBypassPermissions(): void
    {
        $config = new Config(['bypass_permissions' => true]);
        $this->assert($config->bypassPermissions === true, 'bypass enabled');
    }

    private function testCredentials(): void
    {
        $creds = ['github' => ['env' => 'GH_TOKEN']];
        $config = new Config(['credentials' => $creds]);
        $this->assert($config->credentials === $creds, 'credentials preserved');
    }

    private function testLoadMissingFile(): void
    {
        $config = Config::load('/nonexistent/path/zeromcp.config.json');
        $this->assert($config->toolsDirs === ['./tools'], 'load missing file returns defaults');
    }
}

echo "Config Tests:\n";
$test = new ConfigTest();
$test->run();
