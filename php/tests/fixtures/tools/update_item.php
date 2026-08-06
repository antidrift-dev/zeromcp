<?php

return [
    'description' => 'Update an item by id',
    'input' => ['id' => 'string', 'name' => 'string'],
    'route' => ['method' => 'PUT', 'path' => '/items/:id'],
    'execute' => function ($args, $ctx) {
        return ['id' => $args['id'], 'name' => $args['name']];
    },
];
