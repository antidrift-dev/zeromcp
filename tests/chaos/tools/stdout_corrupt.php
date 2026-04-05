<?php
return [
    'description' => 'Tool that writes to stdout',
    'input' => [],
    'execute' => function ($args, $ctx) {
        fwrite(STDOUT, "CORRUPTED OUTPUT\n");
        fflush(STDOUT);
        return ['status' => 'ok'];
    },
];
