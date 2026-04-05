<?php
return [
    'description' => 'Beta tool from dir B',
    'input' => [],
    'execute' => function ($args, $ctx) {
        return ['source' => 'dir-b', 'tool' => 'beta'];
    },
];
