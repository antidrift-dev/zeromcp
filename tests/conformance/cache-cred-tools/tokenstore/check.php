<?php

return [
    'description' => 'Return the current token from credentials',
    'input' => [],
    'execute' => function ($args, $ctx) {
        $creds = $ctx->credentials;
        return [
            'token' => is_array($creds) ? ($creds['token'] ?? null) : null,
        ];
    },
];
