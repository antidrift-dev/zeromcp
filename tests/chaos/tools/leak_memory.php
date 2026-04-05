<?php
$GLOBALS['leaks'] = $GLOBALS['leaks'] ?? [];

return [
    'description' => 'Tool that leaks memory',
    'input' => [],
    'execute' => function ($args, $ctx) {
        $GLOBALS['leaks'][] = str_repeat("\0", 1024 * 1024);
        return ['leaked_buffers' => count($GLOBALS['leaks']), 'total_mb' => count($GLOBALS['leaks'])];
    },
];
