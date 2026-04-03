<?php

namespace ZeroMcp;

class Schema
{
    private const TYPE_MAP = [
        'string'  => ['type' => 'string'],
        'number'  => ['type' => 'number'],
        'boolean' => ['type' => 'boolean'],
        'object'  => ['type' => 'object'],
        'array'   => ['type' => 'array'],
    ];

    public static function toJsonSchema(array $input): array
    {
        if (empty($input)) {
            return ['type' => 'object', 'properties' => new \stdClass(), 'required' => []];
        }

        $properties = [];
        $required = [];

        foreach ($input as $key => $value) {
            if (is_string($value)) {
                if (!isset(self::TYPE_MAP[$value])) {
                    throw new \InvalidArgumentException("Unknown type \"$value\" for field \"$key\"");
                }
                $properties[$key] = self::TYPE_MAP[$value];
                $required[] = $key;
            } elseif (is_array($value)) {
                $type = $value['type'] ?? null;
                if (!$type || !isset(self::TYPE_MAP[$type])) {
                    throw new \InvalidArgumentException("Unknown type \"$type\" for field \"$key\"");
                }
                $prop = self::TYPE_MAP[$type];
                if (isset($value['description'])) {
                    $prop['description'] = $value['description'];
                }
                $properties[$key] = $prop;
                if (empty($value['optional'])) {
                    $required[] = $key;
                }
            }
        }

        return [
            'type' => 'object',
            'properties' => empty($properties) ? new \stdClass() : $properties,
            'required' => $required,
        ];
    }

    public static function validate(array $input, array $schema): array
    {
        $errors = [];

        foreach ($schema['required'] ?? [] as $key) {
            if (!isset($input[$key]) && !array_key_exists($key, $input)) {
                $errors[] = "Missing required field: $key";
            }
        }

        $properties = (array)($schema['properties'] ?? []);
        foreach ($input as $key => $value) {
            if (!isset($properties[$key])) {
                continue;
            }
            $expectedType = $properties[$key]['type'];
            $actualType = self::getType($value);
            if ($actualType !== $expectedType) {
                $errors[] = "Field \"$key\" expected $expectedType, got $actualType";
            }
        }

        return $errors;
    }

    private static function getType($value): string
    {
        if (is_array($value)) {
            // Check if sequential array
            if (array_values($value) === $value) {
                return 'array';
            }
            return 'object';
        }
        if (is_string($value)) return 'string';
        if (is_int($value) || is_float($value)) return 'number';
        if (is_bool($value)) return 'boolean';
        if (is_object($value)) return 'object';
        return 'string';
    }
}
