<?php

return [
    'description' => 'Tool that tries a domain NOT in allowlist',
    'input' => [],
    'permissions' => ['network' => ['only-this-domain.test']],
    'execute' => function ($args, $ctx) {
        if (\ZeroMcp\Sandbox::checkNetworkAccess($ctx->toolName, 'localhost', $ctx->permissions, $ctx->bypass)) {
            return ['bypassed' => true];
        }
        return ['bypassed' => false, 'blocked' => true];
    },
];
