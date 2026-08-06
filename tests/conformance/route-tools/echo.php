<?php

return [
    'description' => 'Echo a message',
    'input' => ['message' => 'string'],
    'route' => ['method' => 'POST', 'path' => '/echo'],
    'execute' => function ($args, $ctx) {
        return ['message' => $args['message'], 'echoed' => true];
    },
];
