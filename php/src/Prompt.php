<?php

namespace ZeroMcp;

class Prompt
{
    public string $name;
    public string $description;
    /** @var array<array{name:string, description?:string, required?:bool}> */
    public array $arguments;
    /** @var callable(array<string,mixed>): array */
    public $render;

    public function __construct(
        string $name,
        string $description = '',
        array $arguments = [],
        ?callable $render = null
    ) {
        $this->name = $name;
        $this->description = $description;
        $this->arguments = $arguments;
        $this->render = $render;
    }
}
