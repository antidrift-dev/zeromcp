<?php

return [
    'description' => 'Greet a user',
    'arguments' => [
        'name' => 'string',
        'style' => ['description' => 'Greeting style', 'optional' => true],
    ],
    'render' => function (array $args): array {
        $style = $args['style'] ?? 'friendly';
        return [
            ['role' => 'user', 'content' => ['type' => 'text', 'text' => "Say hello to {$args['name']} in a $style way"]],
        ];
    },
];