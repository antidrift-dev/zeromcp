<?php
return [
    'description' => 'Dynamic test resource',
    'mimeType' => 'application/json',
    'read' => function() {
        return '{"dynamic": true, "timestamp": "test"}';
    },
];
