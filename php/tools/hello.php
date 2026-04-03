<?php

return [
    'description' => 'Say hello to someone',
    'input' => ['name' => 'string'],
    'execute' => function ($args, $ctx) {
        return "Hello, {$args['name']}!";
    },
];
