<?php
return [
    'description' => 'Tool that hangs forever',
    'input' => [],
    'execute' => function ($args, $ctx) {
        while (true) { sleep(1); }
    },
];
