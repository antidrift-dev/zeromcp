<?php
return [
    'description' => 'Greeting prompt',
    'arguments' => [
        'name' => 'string',
        'tone' => ['type' => 'string', 'optional' => true, 'description' => 'formal or casual'],
    ],
    'render' => function($args) {
        $name = $args['name'] ?? 'world';
        $tone = $args['tone'] ?? 'casual';
        return [
            ['role' => 'user', 'content' => ['type' => 'text', 'text' => "Greet {$name} in a {$tone} tone"]],
        ];
    },
];
