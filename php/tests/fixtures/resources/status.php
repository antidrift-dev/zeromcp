<?php

return [
    'description' => 'Current server status',
    'mimeType' => 'application/json',
    'read' => function (): string {
        return json_encode(['status' => 'ok', 'uptime' => 12345]);
    },
];