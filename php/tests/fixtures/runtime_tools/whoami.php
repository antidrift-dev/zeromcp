<?php

return [
    'description' => 'Return ctx->runtime',
    'input' => [],
    'execute' => function ($args, $ctx) {
        return ['runtime' => $ctx->runtime];
    },
];
