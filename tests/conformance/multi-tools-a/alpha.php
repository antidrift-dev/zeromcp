<?php
return [
    'description' => 'Alpha tool from dir A',
    'input' => [],
    'execute' => function ($args, $ctx) {
        return ['source' => 'dir-a', 'tool' => 'alpha'];
    },
];
