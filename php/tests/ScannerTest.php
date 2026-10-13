<?php

require_once __DIR__ . '/../src/Log.php';
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
        $this->testScanStaticResources();
        $this->testScanDynamicResource();
        $this->testScanResourceTemplate();
        $this->testScanPrompts();
        $this->testScanPromptsArguments();
        $this->testScanEmptyDir();
        $this->testSourcePrefix();
        $this->testNamespacingPrefix();
        $this->testNamespacingEmptyPrefix();
        $this->testCustomSeparatorBothJoins();
        $this->testCredentialNs();

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
        $this->assert($tools['hello']->description === 'Say hello to someone', 'description correct');

        $result = $tools['hello']->call(['name' => 'World']);
        $this->assert($result === 'Hello, World!', 'execute returns correct result');
    }

    private function testScanStaticResources(): void
    {
        $config = new Config(['resources' => __DIR__ . '/fixtures/resources']);
        $scanner = new Scanner($config);
        $result = $scanner->scanResources();
        $resources = $result['resources'];

        $this->assert(isset($resources['config']), 'static json resource loaded');
        $this->assert($resources['config']->mimeType === 'application/json', 'json mime type correct');
        $this->assert($resources['config']->uri === 'resource:///config.json', 'json uri correct');

        $content = ($resources['config']->read)();
        $this->assert(str_contains($content, '"version"'), 'json content readable');

        $this->assert(isset($resources['readme']), 'static md resource loaded');
        $this->assert($resources['readme']->mimeType === 'text/markdown', 'md mime type correct');
    }

    private function testScanDynamicResource(): void
    {
        $config = new Config(['resources' => __DIR__ . '/fixtures/resources']);
        $scanner = new Scanner($config);
        $result = $scanner->scanResources();
        $resources = $result['resources'];

        $this->assert(isset($resources['status']), 'dynamic php resource loaded');
        $this->assert($resources['status']->mimeType === 'application/json', 'dynamic mime type correct');
        $this->assert($resources['status']->description === 'Current server status', 'dynamic description correct');

        $content = ($resources['status']->read)();
        $decoded = json_decode($content, true);
        $this->assert($decoded['status'] === 'ok', 'dynamic resource returns correct data');
    }

    private function testScanResourceTemplate(): void
    {
        $config = new Config(['resources' => __DIR__ . '/fixtures/resources']);
        $scanner = new Scanner($config);
        $result = $scanner->scanResources();
        $templates = $result['templates'];

        $this->assert(isset($templates['user']), 'resource template loaded');
        $this->assert($templates['user']->uriTemplate === 'resource:///users/{id}', 'template uri correct');
        $this->assert($templates['user']->description === 'User by ID', 'template description correct');

        $content = ($templates['user']->read)(['id' => '42']);
        $decoded = json_decode($content, true);
        $this->assert($decoded['id'] === '42', 'template read receives params');
        $this->assert($decoded['name'] === 'User 42', 'template read returns correct data');
    }

    private function testScanPrompts(): void
    {
        $config = new Config(['prompts' => __DIR__ . '/fixtures/prompts']);
        $scanner = new Scanner($config);
        $prompts = $scanner->scanPrompts();

        $this->assert(isset($prompts['greet']), 'greet prompt loaded');
        $this->assert($prompts['greet']->description === 'Greet a user', 'prompt description correct');

        $this->assert(isset($prompts['summarize']), 'summarize prompt loaded');

        $messages = ($prompts['summarize']->render)(['text' => 'Hello world']);
        $this->assert(count($messages) === 1, 'render returns one message');
        $this->assert($messages[0]['role'] === 'user', 'message role is user');
        $this->assert(str_contains($messages[0]['content']['text'], 'Hello world'), 'message contains input');
    }

    private function testScanPromptsArguments(): void
    {
        $config = new Config(['prompts' => __DIR__ . '/fixtures/prompts']);
        $scanner = new Scanner($config);
        $prompts = $scanner->scanPrompts();

        $args = $prompts['greet']->arguments;
        $this->assert(count($args) === 2, 'greet has 2 arguments');

        $nameArg = null;
        $styleArg = null;
        foreach ($args as $a) {
            if ($a['name'] === 'name') $nameArg = $a;
            if ($a['name'] === 'style') $styleArg = $a;
        }
        $this->assert($nameArg !== null && $nameArg['required'] === true, 'name argument is required');
        $this->assert($styleArg !== null && $styleArg['required'] === false, 'style argument is optional');
        $this->assert(isset($styleArg['description']), 'style argument has description');
    }

    private function testScanEmptyDir(): void
    {
        $tmpDir = sys_get_temp_dir() . '/zeromcp_test_empty_' . getmypid();
        @mkdir($tmpDir);
        $config = new Config([
            'tools' => $tmpDir,
            'resources' => $tmpDir,
            'prompts' => $tmpDir,
        ]);
        $scanner = new Scanner($config);

        $tools = $scanner->scan();
        $this->assert(empty($tools), 'empty dir returns no tools');

        $result = $scanner->scanResources();
        $this->assert(empty($result['resources']), 'empty dir returns no resources');
        $this->assert(empty($result['templates']), 'empty dir returns no templates');

        $prompts = $scanner->scanPrompts();
        $this->assert(empty($prompts), 'empty dir returns no prompts');

        @rmdir($tmpDir);
    }

    /** Temp tools dir with math/add.php and top.php. */
    private function makeToolsDir(): string
    {
        $dir = sys_get_temp_dir() . '/zeromcp-scan-' . getmypid() . '-' . bin2hex(random_bytes(3));
        mkdir("$dir/math", 0777, true);
        file_put_contents("$dir/math/add.php", "<?php return ['description' => 'add', 'execute' => fn(\$a, \$c) => 'sum'];");
        file_put_contents("$dir/top.php", "<?php return ['description' => 'top', 'execute' => fn(\$a, \$c) => 'top'];");
        return $dir;
    }

    private function removeDir(string $dir): void
    {
        @unlink("$dir/math/add.php");
        @unlink("$dir/top.php");
        @rmdir("$dir/math");
        @rmdir($dir);
    }

    private function scanNames(array $opts): array
    {
        $names = array_keys((new Scanner(new Config($opts)))->scan());
        sort($names);
        return $names;
    }

    private function testSourcePrefix(): void
    {
        $dir = $this->makeToolsDir();
        $names = $this->scanNames(['tools' => [['path' => $dir, 'prefix' => 'x']]]);
        $this->assert($names === ['x_math_add', 'x_top'], 'source prefix gives x_math_add');
        $this->removeDir($dir);
    }

    private function testNamespacingPrefix(): void
    {
        $dir = $this->makeToolsDir();
        $names = $this->scanNames(['tools' => $dir, 'namespacing' => ['math' => ['prefix' => 'm']]]);
        $this->assert($names === ['m_add', 'top'], 'namespacing prefix m gives m_add');
        $this->removeDir($dir);
    }

    private function testNamespacingEmptyPrefix(): void
    {
        $dir = $this->makeToolsDir();
        $names = $this->scanNames(['tools' => $dir, 'namespacing' => ['math' => ['prefix' => '']]]);
        $this->assert($names === ['add', 'top'], "namespacing prefix '' drops the dir prefix");
        $this->removeDir($dir);
    }

    private function testCustomSeparatorBothJoins(): void
    {
        $dir = $this->makeToolsDir();
        $names = $this->scanNames(['tools' => [['path' => $dir, 'prefix' => 'x']], 'separator' => '.']);
        $this->assert($names === ['x.math.add', 'x.top'], 'custom separator applied to both joins');
        $this->removeDir($dir);
    }

    private function testCredentialNs(): void
    {
        $dir = $this->makeToolsDir();
        $tools = (new Scanner(new Config(['tools' => $dir, 'namespacing' => ['math' => ['prefix' => 'm']]])))->scan();
        $this->assert($tools['m_add']->credentialNs === 'math', 'credentialNs is the first directory segment');
        $this->assert($tools['top']->credentialNs === null, 'credentialNs is null for top-level files');
        $this->removeDir($dir);
    }
}

echo "Scanner Tests:\n";
$test = new ScannerTest();
$test->run();
