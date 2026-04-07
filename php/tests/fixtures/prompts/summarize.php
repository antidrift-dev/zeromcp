<?php

return [
    'description' => 'Summarize text',
    'arguments' => [
        'text' => 'string',
    ],
    'render' => function (array $args): array {
        return [
            ['role' => 'user', 'content' => ['type' => 'text', 'text' => "Summarize: {$args['text']}"]],
        ];
    },
];