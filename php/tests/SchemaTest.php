<?php

require_once __DIR__ . '/../src/Schema.php';

use ZeroMcp\Schema;

class SchemaTest
{
    private int $passed = 0;
    private int $failed = 0;

    public function run(): void
    {
        $this->testEmptyInput();
        $this->testSimpleTypes();
        $this->testOptionalField();
        $this->testValidateMissingRequired();
        $this->testValidateWrongType();
        $this->testValidatePasses();

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

    private function testEmptyInput(): void
    {
        $result = Schema::toJsonSchema([]);
        $this->assert($result['type'] === 'object', 'empty input returns object type');
        $this->assert(empty((array)$result['properties']), 'empty input has no properties');
    }

    private function testSimpleTypes(): void
    {
        $result = Schema::toJsonSchema(['name' => 'string', 'age' => 'number']);
        $props = $result['properties'];
        $this->assert($props['name']['type'] === 'string', 'name is string');
        $this->assert($props['age']['type'] === 'number', 'age is number');
        $this->assert(in_array('name', $result['required']), 'name is required');
        $this->assert(in_array('age', $result['required']), 'age is required');
    }

    private function testOptionalField(): void
    {
        $result = Schema::toJsonSchema([
            'name' => ['type' => 'string', 'description' => 'User name'],
            'email' => ['type' => 'string', 'optional' => true],
        ]);
        $this->assert(in_array('name', $result['required']), 'name is required');
        $this->assert(!in_array('email', $result['required']), 'email is optional');
        $this->assert($result['properties']['name']['description'] === 'User name', 'description preserved');
    }

    private function testValidateMissingRequired(): void
    {
        $schema = Schema::toJsonSchema(['name' => 'string']);
        $errors = Schema::validate([], $schema);
        $this->assert(count($errors) === 1, 'missing required field caught');
        $this->assert(str_contains($errors[0], 'Missing required field'), 'error message correct');
    }

    private function testValidateWrongType(): void
    {
        $schema = Schema::toJsonSchema(['age' => 'number']);
        $errors = Schema::validate(['age' => 'not a number'], $schema);
        $this->assert(count($errors) === 1, 'wrong type caught');
        $this->assert(str_contains($errors[0], 'expected number'), 'type error message correct');
    }

    private function testValidatePasses(): void
    {
        $schema = Schema::toJsonSchema(['name' => 'string']);
        $errors = Schema::validate(['name' => 'Alice'], $schema);
        $this->assert(empty($errors), 'valid input passes');
    }
}

echo "Schema Tests:\n";
$test = new SchemaTest();
$test->run();
