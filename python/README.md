# ZeroMCP &mdash; Python

Drop a `.py` file in a folder, get a sandboxed MCP server. Stdio out of the box, mount it in your own HTTP server, zero dependencies.

## Getting started

```python
# tools/hello.py — this is a complete MCP server
tool = {
    "description": "Say hello to someone",
    "input": {"name": "string"},
}

async def execute(args, ctx):
    return f"Hello, {args['name']}!"
```

```sh
python3 -m zeromcp serve ./tools
```

That's it. Stdio transport works immediately. Drop another `.py` file to add another tool. Delete a file to remove one. No server object, no decorators, no main block.

## vs. the official SDK

The official Python SDK (FastMCP) requires a server object, decorators, and a `__main__` block. Adding a tool means editing server code and restarting. ZeroMCP is file-based &mdash; each tool is its own file, discovered automatically.

In benchmarks, ZeroMCP Python handles 12,936 requests/second over stdio versus the official SDK's 1,018 &mdash; 12.7x faster with 59% less memory. Over HTTP (Starlette), ZeroMCP serves 2,623 rps at 27 MB versus the official SDK's 635 rps at 80-87 MB. ZeroMCP uses only the standard library. The official SDK pulls in pydantic, httpx, uvicorn, and starlette just for stdio.

Python passes all 10 conformance suites and survives 21/22 chaos monkey attacks.

The official SDK has **no sandbox**. ZeroMCP enforces per-tool network allowlists and credential isolation at runtime, plus static auditing for filesystem and exec access.

## HTTP / Streamable HTTP

ZeroMCP doesn't own the HTTP layer, and the package ships no HTTP server. `python3 -m zeromcp serve` is stdio only; a config with `"transport": {"type": "http"}` exits at startup with an error pointing here. You bring your own framework and mount one of two entry points in it.

### `create_handler`: one MCP endpoint

An async handler that takes a JSON-RPC dict and returns a response dict (or `None` for notifications). It loads tools from a directory or config, the same way `serve` does.

```python
from zeromcp import create_handler

handler = await create_handler("./tools")
# handler(request: dict) -> dict | None
```

**Flask**

```python
from flask import Flask, request, jsonify

app = Flask(__name__)

@app.route("/mcp", methods=["POST"])
async def mcp():
    response = await handler(request.get_json())
    if response is None:
        return "", 204
    return jsonify(response)
```

**FastAPI**

```python
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

app = FastAPI()

@app.post("/mcp")
async def mcp(req: Request):
    response = await handler(await req.json())
    if response is None:
        return JSONResponse(status_code=204, content=None)
    return response
```

### `create_registry`: REST routes, OpenAPI and MCP from one tools dict

`create_registry` takes tools you've already built (no directory scan) and returns plain data: `registry.routes` (one `RouteDefinition` per tool with a `route`), `registry.openapi` (an OpenAPI 3.0 dict) and `registry.mcp` (the same JSON-RPC handler as above). Each tool's `execute(args, env)` takes two arguments. The registry does no HTTP routing; your framework matches the paths.

```python
import asyncio, re
from fastapi import FastAPI, Request
from zeromcp import create_registry

async def greet(args, env):
    return f"Hello, {args['name']}!"

tools = {
    "greet": {
        "description": "Greet someone by name",
        "input": {"name": "string"},
        "route": {"method": "GET", "path": "/greet/:name"},
        "execute": greet,
    },
}

def get_env():
    return {"tenant": "acme"}

registry = asyncio.run(create_registry(tools, get_env=get_env))

app = FastAPI(openapi_url=None)  # serve ZeroMCP's spec instead of FastAPI's

@app.get("/openapi.json")
async def openapi():
    return registry.openapi

@app.post("/mcp")
async def mcp(req: Request):
    return await registry.mcp(await req.json())

def mount(route):
    async def endpoint(req: Request):
        args = dict(req.path_params)
        if route.method == "GET":
            args.update(req.query_params)
        else:
            args.update(await req.json())
        return {"ok": True, "result": await route.tool["execute"](args, get_env())}
    # ":name" -> "{name}" for FastAPI's path syntax
    app.add_api_route(re.sub(r":(\w+)", r"{\1}", route.path), endpoint, methods=[route.method])

for route in registry.routes:
    mount(route)
```

`create_registry` also takes `title`, `version` (for the OpenAPI `info`), `execute_timeout` (seconds, default 30) and `remote` (see [Remote servers](#remote-servers)).

## Runtime context

Tools often need per-request data such as the current user or tenant. Both HTTP entry points take a callable that is invoked on every tool call:

- `create_handler(config, get_runtime=fn)`: file-based tools read the return value as `ctx.runtime`.
- `create_registry(tools, get_env=fn)`: the return value is passed as `env`, the second argument of `execute(args, env)`, for calls through `registry.mcp`. Route handlers you mount yourself pass `env` explicitly, as above.

```python
# tools/whoami.py
tool = {"description": "Who is calling", "input": {}}

async def execute(args, ctx):
    return {"user": ctx.runtime["user"]}
```

```python
handler = await create_handler("./tools", get_runtime=lambda: {"user": current_user()})
```

## Remote servers

Federate tools from other MCP servers over HTTP. Each remote's tools appear as `<name>.<tool>`; a local tool with the same name wins. `auth` is sent as `Authorization: Bearer <auth>` and accepts `env:VAR`. `tools` is an optional allowlist of upstream tool names.

```json
{
  "tools": "./tools",
  "remote": [
    { "name": "probeo", "url": "https://mcp.example.com/mcp", "auth": "env:PROBEO_TOKEN", "tools": ["list_pages"] }
  ]
}
```

This works in `serve`, `create_handler`, and `create_registry(tools, remote=[...])`. A server that fails to connect is logged and skipped.

## Autoload

Set `"autoload_tools": true` in the config and `serve` watches the tool directories: when a `.py` file is added or changed it rescans, updates the tool list and sends `notifications/tools/list_changed`. A deleted file's tool stays listed until restart. The standard library has no recursive file watcher, so it polls mtimes every 0.5s.

## Requirements

- Python 3.10+
- No external dependencies (stdlib only)

## Install

```sh
pip install -e .
```

## Defining tools

```python
# tools/add.py
tool = {
    "description": "Add two numbers together",
    "input": {"a": "number", "b": "number"},
}

async def execute(args, ctx):
    return {"sum": args["a"] + args["b"]}
```

### Input types

Shorthand strings: `"string"`, `"number"`, `"boolean"`, `"object"`, `"array"`.

### Returning values

Return a string or a dict. ZeroMCP wraps it in the MCP content envelope for you.

## Sandbox

The Python implementation sandboxes network access at runtime and audits filesystem/exec access statically.

### Network allowlists

```python
tool = {
    "description": "Fetch from our API",
    "input": {"endpoint": "string"},
    "permissions": {
        "network": ["api.example.com", "*.internal.dev"],
    },
}

async def execute(args, ctx):
    res = await ctx.fetch(f"https://api.example.com/{args['endpoint']}")
    return res["body"]
```

`ctx.fetch` validates the hostname against the allowlist. Unlisted domains are blocked and logged.

### Credential injection

Tools receive secrets via `ctx.credentials`, configured per namespace. Tools never call `os.environ` directly.

### Filesystem and exec control

Declaring `fs` or `exec` in a tool's `permissions` gets logged as an elevated-permission request when the tool loads. Enforcement is static, not runtime: `python3 -m zeromcp audit ./tools` scans tool files for raw `open()`, `subprocess`, `os.system`, `os.popen`, and `os.environ` calls and reports them as violations. Unlike `ctx.fetch`, there's no sandboxed proxy for filesystem or exec access — route network calls through `ctx.fetch` and keep filesystem/exec code auditable.

## Directory structure

Tools are discovered recursively. Subdirectory names become namespace prefixes:

```
tools/
  hello.py          -> tool "hello"
  math/
    add.py          -> tool "math_add"
```

## Configuration

Optional `zeromcp.config.json` in the working directory. See the [root README](../README.md#configuration) for the full schema.

## Testing

```sh
python3 -m pytest
```
