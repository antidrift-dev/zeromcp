<?php

/**
 * Tests for the Server::paginate() and Server::matchTemplate() private static methods.
 * We use reflection to access them since they are private.
 */

require_once __DIR__ . '/../src/Schema.php';
require_once __DIR__ . '/../src/Config.php';
require_once __DIR__ . '/../src/Tool.php';
require_once __DIR__ . '/../src/Resource.php';
require_once __DIR__ . '/../src/Prompt.php';
require_once __DIR__ . '/../src/Scanner.php';
require_once __DIR__ . '/../src/Sandbox.php';
require_once __DIR__ . '/../src/Server.php';

use ZeroMcp\Server;

class PaginationTest
{
    private int $passed = 0;
    private int $failed = 0;
    private \ReflectionMethod $paginate;
    private \ReflectionMethod $matchTemplate;

    public function __construct()
    {
        $this->paginate = new \ReflectionMethod(Server::class, 'paginate');
        $this->paginate->setAccessible(true);

        $this->matchTemplate = new \ReflectionMethod(Server::class, 'matchTemplate');
        $this->matchTemplate->setAccessible(true);
    }

    public function run(): void
    {
        $this->testPaginateNoLimit();
        $this->testPaginateFirstPage();
        $this->testPaginateSecondPage();
        $this->testPaginateLastPage();
        $this->testPaginateEmptyItems();
        $this->testPaginateCursorBeyondEnd();
        $this->testPaginateInvalidCursor();
        $this->testCursorEncodeDecode();
        $this->testMatchTemplateSimple();
        $this->testMatchTemplateMultipleParams();
        $this->testMatchTemplateNoMatch();
        $this->testMatchTemplateLiteralPrefix();
        $this->testMatchTemplateNoPlaceholders();

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

    private function paginate(array $items, ?string $cursor, int $pageSize): array
    {
        return $this->paginate->invoke(null, $items, $cursor, $pageSize);
    }

    private function matchTemplate(string $template, string $uri): ?array
    {
        return $this->matchTemplate->invoke(null, $template, $uri);
    }

    // --- Pagination ---

    private function testPaginateNoLimit(): void
    {
        $items = ['a', 'b', 'c'];
        $result = $this->paginate($items, null, 0);
        $this->assert($result['items'] === $items, 'pageSize 0 returns all items');
        $this->assert(!isset($result['nextCursor']), 'no cursor when no pagination');
    }

    private function testPaginateFirstPage(): void
    {
        $items = ['a', 'b', 'c', 'd', 'e'];
        $result = $this->paginate($items, null, 2);
        $this->assert($result['items'] === ['a', 'b'], 'first page has first 2 items');
        $this->assert(isset($result['nextCursor']), 'first page has nextCursor');
        // Cursor should encode offset 2
        $decoded = base64_decode($result['nextCursor']);
        $this->assert($decoded === '2', 'cursor encodes offset 2');
    }

    private function testPaginateSecondPage(): void
    {
        $items = ['a', 'b', 'c', 'd', 'e'];
        $cursor = base64_encode('2');
        $result = $this->paginate($items, $cursor, 2);
        $this->assert($result['items'] === ['c', 'd'], 'second page has items 3-4');
        $this->assert(isset($result['nextCursor']), 'second page has nextCursor');
    }

    private function testPaginateLastPage(): void
    {
        $items = ['a', 'b', 'c', 'd', 'e'];
        $cursor = base64_encode('4');
        $result = $this->paginate($items, $cursor, 2);
        $this->assert($result['items'] === ['e'], 'last page has remaining item');
        $this->assert(!isset($result['nextCursor']), 'last page has no nextCursor');
    }

    private function testPaginateEmptyItems(): void
    {
        $result = $this->paginate([], null, 10);
        $this->assert($result['items'] === [], 'empty items returns empty');
        $this->assert(!isset($result['nextCursor']), 'no cursor for empty');
    }

    private function testPaginateCursorBeyondEnd(): void
    {
        $items = ['a', 'b'];
        $cursor = base64_encode('100');
        $result = $this->paginate($items, $cursor, 2);
        $this->assert($result['items'] === [], 'cursor beyond end returns empty');
        $this->assert(!isset($result['nextCursor']), 'no cursor when beyond end');
    }

    private function testPaginateInvalidCursor(): void
    {
        $items = ['a', 'b', 'c'];
        // Invalid base64 that decodes to non-numeric
        $result = $this->paginate($items, '!!!invalid!!!', 2);
        $this->assert(count($result['items']) === 2, 'invalid cursor starts from beginning');
    }

    private function testCursorEncodeDecode(): void
    {
        // Verify the cursor round-trips correctly
        $items = range(1, 20);
        $result1 = $this->paginate($items, null, 5);
        $cursor1 = $result1['nextCursor'];

        $result2 = $this->paginate($items, $cursor1, 5);
        $this->assert($result2['items'] === [6, 7, 8, 9, 10], 'cursor round-trip gives correct page');

        $cursor2 = $result2['nextCursor'];
        $result3 = $this->paginate($items, $cursor2, 5);
        $this->assert($result3['items'] === [11, 12, 13, 14, 15], 'second cursor round-trip correct');
    }

    // --- Template matching ---

    private function testMatchTemplateSimple(): void
    {
        $result = $this->matchTemplate('resource:///users/{id}', 'resource:///users/42');
        $this->assert($result !== null, 'simple template matches');
        $this->assert($result['id'] === '42', 'extracts id parameter');
    }

    private function testMatchTemplateMultipleParams(): void
    {
        $result = $this->matchTemplate(
            'resource:///orgs/{org}/repos/{repo}',
            'resource:///orgs/antidrift/repos/zeromcp'
        );
        $this->assert($result !== null, 'multi-param template matches');
        $this->assert($result['org'] === 'antidrift', 'extracts org parameter');
        $this->assert($result['repo'] === 'zeromcp', 'extracts repo parameter');
    }

    private function testMatchTemplateNoMatch(): void
    {
        $result = $this->matchTemplate('resource:///users/{id}', 'resource:///posts/42');
        $this->assert($result === null, 'non-matching URI returns null');
    }

    private function testMatchTemplateLiteralPrefix(): void
    {
        $result = $this->matchTemplate('file:///docs/{name}.txt', 'file:///docs/readme.txt');
        $this->assert($result !== null, 'template with literal suffix matches');
        $this->assert($result['name'] === 'readme', 'extracts name before suffix');
    }

    private function testMatchTemplateNoPlaceholders(): void
    {
        $result = $this->matchTemplate('resource:///health', 'resource:///health');
        $this->assert($result !== null, 'exact match with no placeholders');
        $this->assert(empty($result), 'no params extracted');

        $result2 = $this->matchTemplate('resource:///health', 'resource:///other');
        $this->assert($result2 === null, 'different URI does not match');
    }
}

echo "Pagination & Template Tests:\n";
$test = new PaginationTest();
$test->run();
