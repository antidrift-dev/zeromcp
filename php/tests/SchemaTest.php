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
        $this->testAllTypeMap();
        $this->testUnknownTypeThrows();
        $this->testUnknownTypeInArrayThrows();
        $this->testValidateMultipleErrors();
        $this->testValidateOptionalFieldNotRequired();
        $this->testValidateBooleanType();
        $this->testValidateArrayType();
        $this->testValidateObjectType();
        $this->testValidateIgnoresUnknownFields();

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

    private function testAllTypeMap(): void
    {
        $result = Schema::toJsonSchema([
            'a' => 'string',
            'b' => 'number',
            'c' => 'boolean',
            'd' => 'object',
            'e' => 'array',
        ]);
        $props = $result['properties'];
        $this->assert($props['a']['type'] === 'string', 'string type maps');
        $this->assert($props['b']['type'] === 'number', 'number type maps');
        $this->assert($props['c']['type'] === 'boolean', 'boolean type maps');
        $this->assert($props['d']['type'] === 'object', 'object type maps');
        $this->assert($props['e']['type'] === 'array', 'array type maps');
        $this->assert(count($result['required']) === 5, 'all 5 fields required');
    }

    private function testUnknownTypeThrows(): void
    {
        $threw = false;
        try {
            Schema::toJsonSchema(['x' => 'bigint']);
        } catch (\InvalidArgumentException $e) {
            $threw = true;
        }
        $this->assert($threw, 'unknown simple type throws');
    }

    private function testUnknownTypeInArrayThrows(): void
    {
        $threw = false;
        try {
            Schema::toJsonSchema(['x' => ['type' => 'bigint']]);
        } catch (\InvalidArgumentException $e) {
            $threw = true;
        }
        $this->assert($threw, 'unknown array type throws');
    }

    private function testValidateMultipleErrors(): void
    {
        $schema = Schema::toJsonSchema(['name' => 'string', 'age' => 'number']);
        $errors = Schema::validate([], $schema);
        $this->assert(count($errors) === 2, 'two missing required fields caught');
    }

    private function testValidateOptionalFieldNotRequired(): void
    {
        $schema = Schema::toJsonSchema([
            'name' => 'string',
            'bio' => ['type' => 'string', 'optional' => true],
        ]);
        $errors = Schema::validate(['name' => 'Alice'], $schema);
        $this->assert(empty($errors), 'optional field not flagged as missing');
    }

    private function testValidateBooleanType(): void
    {
        $schema = Schema::toJsonSchema(['flag' => 'boolean']);
        $errors = Schema::validate(['flag' => true], $schema);
        $this->assert(empty($errors), 'boolean value passes');
        $errors = Schema::validate(['flag' => 'yes'], $schema);
        $this->assert(count($errors) === 1, 'string rejected for boolean field');
    }

    private function testValidateArrayType(): void
    {
        $schema = Schema::toJsonSchema(['items' => 'array']);
        $errors = Schema::validate(['items' => [1, 2, 3]], $schema);
        $this->assert(empty($errors), 'sequential array passes');
        $errors = Schema::validate(['items' => 'not-array'], $schema);
        $this->assert(count($errors) === 1, 'string rejected for array field');
    }

    private function testValidateObjectType(): void
    {
        $schema = Schema::toJsonSchema(['data' => 'object']);
        // Associative array = object
        $errors = Schema::validate(['data' => ['key' => 'val']], $schema);
        $this->assert(empty($errors), 'assoc array passes as object');
    }

    private function testValidateIgnoresUnknownFields(): void
    {
        $schema = Schema::toJsonSchema(['name' => 'string']);
        $errors = Schema::validate(['name' => 'Alice', 'extra' => 123], $schema);
        $this->assert(empty($errors), 'unknown fields are ignored');
    }
}

echo "Schema Tests:\n";
$test = new SchemaTest();
$test->run();
