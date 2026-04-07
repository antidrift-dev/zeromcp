<?php

return [
    'uriTemplate' => 'resource:///users/{id}',
    'description' => 'User by ID',
    'mimeType' => 'application/json',
    'read' => function (array $params): string {
        return json_encode(['id' => $params['id'], 'name' => 'User ' . $params['id']]);
    },
];