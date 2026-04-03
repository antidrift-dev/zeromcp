<?php

return [
    'description' => 'Add two numbers together',
    'input' => ['a' => 'number', 'b' => 'number'],
    'execute' => function ($args, $ctx) {
        return ['sum' => $args['a'] + $args['b']];
    },
];
