<?php

namespace ZeroMcp;

class Resource
{
    public string $uri;
    public string $name;
    public string $description;
    public string $mimeType;
    /** @var callable(): string */
    public $read;

    public function __construct(
        string $uri,
        string $name,
        string $description = '',
        string $mimeType = 'text/plain',
        ?callable $read = null
    ) {
        $this->uri = $uri;
        $this->name = $name;
        $this->description = $description;
        $this->mimeType = $mimeType;
        $this->read = $read;
    }
}

class ResourceTemplate
{
    public string $uriTemplate;
    public string $name;
    public string $description;
    public string $mimeType;
    /** @var callable(array<string,string>): string */
    public $read;

    public function __construct(
        string $uriTemplate,
        string $name,
        string $description = '',
        string $mimeType = 'text/plain',
        ?callable $read = null
    ) {
        $this->uriTemplate = $uriTemplate;
        $this->name = $name;
        $this->description = $description;
        $this->mimeType = $mimeType;
        $this->read = $read;
    }
}
