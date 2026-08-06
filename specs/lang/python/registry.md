# Framework-neutral tool registry — Python

## Status

**Spec — not yet implemented.** This document is the Python port design for the framework-neutral registry shipped in Node.js (`nodejs/src/registry.ts`, see `specs/lang/nodejs/registry.md`). No code has been written yet; the module/function/class names below are the target design, not existing API.

## Motivation

`python/zeromcp/server.py` already has two entry points that do JSON-RPC dispatch:

- `serve(config_or_path)` (`server.py:95-119`) — scans tools/resources/prompts via `_build_state` (`server.py:17-63`) and starts stdio and/or HTTP transports. `_start_http` (`server.py:596-693`) is a hand-rolled `asyncio` HTTP server that internally handles `/mcp` (JSON-RPC), `/openapi.json`, `/docs` (Swagger UI), and route-tagged tool dispatch (matching each tool's `route` field against the incoming path via `_match_route_path`, `server.py:485-498`), all in one function.
- `create_handler(config_or_path)` (`server.py:66-92`) — Python already has a framework-neutral MCP handler factory today. Its own docstring shows the intended use: `handler = await create_handler("./tools")` then `await handler(json_rpc_request)`, with an example of mounting it at `POST /mcp` on an arbitrary framework. This is the closest existing precedent for the registry.

`create_handler` gets most of the way there but has two gaps relative to what Node's `registry.ts` provides:

1. It still scans a directory (or takes a config dict) and builds tools itself via `_build_state`/`ToolScanner` — it doesn't accept an already-assembled tools dict from the caller. A consumer who has already loaded/constructed tool definitions in code (not from `.py` files on disk) has no entry point that skips scanning.
2. It only returns the `mcp` handler — there is no way to get the route list or an OpenAPI document out of it. Both of those only exist today buried inside `_start_http` (route dispatch) and `_build_openapi` (`server.py:528-577`, called from `_start_http`'s `/openapi.json` branch).

This spec adds `create_registry`, a second, additive factory in a new `python/zeromcp/registry.py` module, that takes an already-built `tools` dict (no scanning) and hands back all three ingredients — `routes`, `openapi`, `mcp` — as plain data/callables, so a caller can wire them into FastAPI, Flask, Django, an AWS Lambda handler, or anything else. `serve()`, `_start_http`, and `create_handler` are unchanged; ZeroMCP's file-scanning path (`ToolScanner` in `scanner.py`) is untouched and remains the only way to go from `.py` files on disk to a tools dict — `create_registry` picks up *after* that step (or after any other way of assembling a tools dict), same relationship Node's `createRegistry` has to Node's file-based tool loading.

## Public API

New file: `python/zeromcp/registry.py`.

```python
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Awaitable, Callable, Literal

RouteMethod = Literal["GET", "POST", "PUT", "PATCH", "DELETE"]

# A JSON-RPC request/response round trip — same shape _handle_request already uses.
McpHandler = Callable[[dict], Awaitable[dict | None]]


@dataclass(frozen=True)
class RouteDefinition:
    """One route-tagged tool, exposed as plain data. No HTTP routing/param-extraction here."""
    name: str
    method: RouteMethod
    path: str
    tool: dict  # the original caller-supplied tool dict (see Tool shape below)


@dataclass(frozen=True)
class ToolRegistry:
    routes: list[RouteDefinition]
    openapi: dict
    mcp: McpHandler


def create_registry(
    tools: dict[str, dict],
    *,
    get_env: Callable[[], Any] | None = None,
) -> ToolRegistry:
    ...
```

**Tool shape accepted by `create_registry`** — a plain `dict`, matching the field names already used everywhere else in this codebase (`tool_meta` in `scanner.py:100-127`, the entries `ToolScanner.tools` produces, the dicts `_handle_request`/`_call_tool`/`_build_openapi` read):

```python
{
    "description": str,
    "input": dict,                                   # simplified schema, same shape schema.to_json_schema() accepts
    "route": {"method": "GET", "path": "/greet/:name"},  # optional
    "permissions": dict | None,                       # optional, same shape sandbox.validate_permissions() expects
    "execute": Callable[[dict, Any], Awaitable[Any]],  # two-arg: (args, env) -> result — see Behavior below
}
```

Usage:

```python
from zeromcp.registry import create_registry

async def greet_execute(args: dict, env: dict) -> str:
    return f"Hello, {args['name']}!"

tools = {
    "greet": {
        "description": "Greet someone by name",
        "input": {"name": "string"},
        "route": {"method": "GET", "path": "/greet/:name"},
        "execute": greet_execute,
    },
}

registry = create_registry(tools, get_env=lambda: {"db": my_db_pool})

# registry.routes  -> list[RouteDefinition], wire into FastAPI/Flask/Django routing yourself
# registry.openapi -> dict, serve as static JSON at your own /openapi.json
# registry.mcp     -> async def mcp(request: dict) -> dict | None, call from your own POST /mcp
```

### Behavior

- `tools` is a plain `name -> tool dict` map, the same shape used elsewhere in the codebase, **except** for `execute`. Every other place in this codebase that consumes a tools dict (`_call_tool`, `_handle_http_route`, `_handle_request`'s `tools/list`) expects `execute` to already be a **one-argument** callable — `execute(args) -> Awaitable[Any]` — because by the time a tool reaches that dict, `ToolScanner._load_tool` (`scanner.py:107-114`) has already closed over per-tool credentials/sandboxing and wrapped the source file's two-argument `execute(args, ctx)` into a zero-ctx-visible-to-the-dispatcher `wrapped_execute(args)`. `create_registry`'s input tools do the analogous thing but with a **caller-supplied `env`** instead of scanner-resolved credentials: registry tools declare `execute(args, env)`, and `create_registry` closes over `get_env()` to produce the one-argument closure the dispatcher needs internally (see below) — this mirrors exactly how `ToolScanner` already collapses a two-arg `execute` into a one-arg one, just with `env` (an arbitrary caller-supplied value, e.g. a DB pool, a Flask `g`, request-scoped auth) standing in for `ctx`.
- `get_env` supplies that second argument on every `execute` call made through `registry.mcp` or through a caller iterating `registry.routes` and invoking `route.tool["execute"](args, get_env())` directly. Defaults to `lambda: {}` if omitted, matching Node's default.
- `create_registry` builds an internal state dict shaped exactly like `_build_state`'s return value (`server.py:52-63`: `tools`, `resources`, `templates`, `prompts`, `subscriptions`, `execute_timeout`, `page_size`, `log_level`, `icon`, `title`) but with `resources`/`templates`/`prompts` left empty (`create_registry` never scans — it has no resource/prompt sources), `execute_timeout=30` and `page_size=0` (the same defaults `_build_state` uses when no config sets them), and `tools` populated from the caller's `tools` dict, transformed as follows:
  - `description`, `input`, `route`, `permissions` are carried over as-is.
  - `_cached_schema` is computed by calling `schema.to_json_schema(tool["input"])` — the exact function `ToolScanner._load_tool` already calls at load time (`scanner.py:120`) to pre-cache each tool's JSON Schema so `tools/list` and validation don't rebuild it per request. `create_registry` reuses `to_json_schema` directly; it does not reimplement schema conversion.
  - `execute` is replaced with a one-arg closure `lambda args: original_execute(args, get_env())`, matching the wrapping pattern `scanner.py:111-114` already uses for `ctx`.
- `registry.mcp` is `async def mcp(request: dict) -> dict | None: return await handle_request(request, state)`, where `handle_request` is the same JSON-RPC dispatcher `server.py` already uses for both stdio (`_start_stdio`, `server.py:122-160`) and the built-in HTTP server's `/mcp` route (`server.py:656-664`). **This requires one small visibility change to `server.py`**: `_handle_request` (`server.py:209-432`) is currently module-private (leading underscore, per this codebase's convention that a leading underscore marks "not meant to be imported from another module" — e.g. `scanner.py`/`config.py` only ever import each other's non-underscore names). Since `registry.py` now needs to import it, this port renames `_handle_request` to `handle_request` (and updates the three in-module call sites: `_start_stdio`, `create_handler`'s inner `handler`, and `_start_http`'s `/mcp` branch). No behavior changes — this is a rename only.
- `registry.openapi` reuses `_build_openapi(state)` (`server.py:528-577`) verbatim, called once against the internal state described above, and cached in the returned `ToolRegistry` — not regenerated per access. This matches Node's "generated once … ready to serve statically" behavior, and is *tighter* than `_start_http`'s own `/openapi.json` branch, which currently calls `_build_openapi(state)` fresh on every GET (`server.py:637-639`) — that's existing, unrelated behavior and out of scope here. Like `handle_request`, `_build_openapi` is renamed to `build_openapi` (drop the leading underscore) as part of this port, for the same cross-module-reuse reason, with its three current call sites (`_start_http`'s `/openapi.json` branch being the only one) updated to match.
- `registry.routes` is built by filtering the **original** (caller-supplied, two-arg-`execute`) `tools` dict down to entries with a truthy `route`, in `tools.items()` order (Python `dict`s preserve insertion order, same guarantee Node relies on for `Object.entries`), projecting each into `RouteDefinition(name=name, method=tool["route"]["method"], path=tool["route"]["path"], tool=tool)`. `RouteDefinition.tool` is the **original** tool dict (two-arg `execute`), not the internal one-arg-wrapped copy — this lets a caller mounting a route in their own framework extract path/query params themselves and call `route.tool["execute"](args, their_own_env)` directly, without going through `registry.mcp`'s dispatch machinery, and without being forced to use whatever `get_env()` was configured at `create_registry` time. This is the same design Node's `RouteDefinition<TEnv> = { name, method, path, tool }` uses. No path matching (`_match_route_path`, `server.py:485-498`), query-string parsing, or body parsing is done by `create_registry` or `RouteDefinition` — that stays entirely the caller's framework's job, same as every other language's port.
- No auth hook — auth is the caller's framework's concern, matching Node.

### Non-goals

- Does not replace or call into `serve()` / `_start_http`'s built-in `asyncio` HTTP server.
- Does not scan directories. `ToolScanner` (`scanner.py`) is unchanged and is the only file-based loading path; `create_registry` only ever accepts an already-built `tools` dict, whether that dict came from `ToolScanner().scan()`, was hand-written, or came from anywhere else.
- Does not do any HTTP request/response handling, routing, or body parsing — `routes` is data (`RouteDefinition` dataclasses), not wired handlers.
- Does not depend on any HTTP framework (no FastAPI, Flask, Starlette, etc. imports).

## Packaging

- New source file: `python/zeromcp/registry.py`.
- Visibility changes required in `python/zeromcp/server.py`: rename `_handle_request` → `handle_request` (`server.py:209`) and `_build_openapi` → `build_openapi` (`server.py:528`), updating their in-module call sites (`_start_stdio`, `create_handler`, `_start_http`). Both remain regular module-level functions — no new class, no change to their signatures or behavior.
- `python/zeromcp/__init__.py` currently exports only `create_handler, serve` (`__init__.py:5`). Add `create_registry` to the same re-export line (`from .registry import create_registry  # noqa: F401`) for parity with `create_handler`/`serve`, so `from zeromcp import create_registry` works alongside the existing `from zeromcp import serve`. This is a judgment call, not a strict Node port: Node deliberately keeps `registry.ts` behind a *separate* subpath export (`@antidrift/zeromcp/registry`, not re-exported from the package root) via `package.json`'s `exports` map. Python's package system has no equivalent friction — `from zeromcp.registry import create_registry` already works for any submodule with zero extra packaging, `pyproject.toml`'s `[tool.setuptools.packages.find] include = ["zeromcp*"]` picks up `registry.py` automatically — so there's no packaging reason to withhold it from the top-level `__init__.py` the way Node withholds it from the root `package.json` export. Both import spellings work either way.
- No new PyPI dependency. `python/pyproject.toml` currently declares no runtime dependencies at all (stdlib only); `registry.py` only needs `dataclasses`, `typing`, and imports from `.schema` and `.server`, all already present.
- Consumers install the existing `antidrift-zeromcp` package and use either `from zeromcp import create_registry` or `from zeromcp.registry import create_registry`.
- Suggested conformance/example: a Python sibling to `tests/conformance/route-tools/*.py`, e.g. `tests/conformance/registry-tools/*.py` plus a small harness (mirroring `tests/conformance/run-route.js`'s Python entry, which currently launches `python -m zeromcp serve --config route-config-python.json`) that instead imports `create_registry` directly, builds a `tools` dict in-process, and asserts on `registry.routes`, `registry.openapi`, and `await registry.mcp(request)` without spawning `zeromcp serve` at all — this is the one language where the registry can be exercised as a plain library call rather than a subprocess, since `tests/conformance/run-route.js` already shells out to `python -m zeromcp`.

## Porting notes

Judgment calls made for this Python port:

1. **`env` via a two-arg `execute(args, env)`, collapsed to one-arg internally — new pattern, but modeled directly on an existing one.** Every tools dict Python's dispatcher (`handle_request`/`_call_tool`/`_handle_http_route`) actually consumes today has one-arg `execute(args)` — `ctx` (credentials, sandboxed `fetch`) is resolved and closed over by `ToolScanner._load_tool` (`scanner.py:107-114`) *before* the tool ever reaches that dict, using the module-private `_ToolContext` class (`scanner.py:132-137`). Reusing `_ToolContext` for the registry would be wrong — it's shaped around file-based credential/sandbox resolution (`credentials`, `fetch`), which has no meaning for a caller assembling tools in code. Instead, `create_registry` introduces `env: Any` as a fully caller-defined opaque value (Node's `TEnv`, but untyped since Python has no need for a generic parameter here) and performs the exact same "close over the second arg, expose one-arg to the dispatcher" transform `scanner.py` already does for `ctx`. This was a real design choice, not a mechanical port — flag it in review as new plumbing, not a straight copy.
2. **`_handle_request` → `handle_request`, `_build_openapi` → `build_openapi` (drop leading underscore).** This codebase's own convention is that cross-module-reusable functions don't have a leading underscore (`scanner.py` imports `resolve_credentials`, `resolve_sources`, `resolve_tool_sources` from `config.py` — all public names). `_handle_request`/`_build_openapi` were private only because, until now, nothing outside `server.py` needed them. This is a straightforward rename, not a redesign; call it out in review as touching `server.py`'s existing (unchanged-behavior) code, not just adding a new file.
3. **`openapi` is cached once at `create_registry` time, not rebuilt per access** — deliberately tighter than `_start_http`'s `/openapi.json` branch, which rebuilds on every request today (`server.py:637-639`). Matches the Node spec's stated behavior and the Java/C# ports' same judgment call. If tools are added after `create_registry` returns, `registry.openapi` will not reflect them — there is no live/mutable registry in this design, matching Node.

## Fixed: existing `_build_openapi` had the same non-GET path-param bug as Node

Auditing all 10 languages for the Node bug (see `specs/lang/nodejs/registry.md`'s "Fixed since the original as-built version" section, and the equivalent Swift finding at the end of `specs/lang/swift/registry.md`) found the exact same bug already shipped in Python's own `_build_openapi(state)` (`server.py:528-577`, pre-dating this registry spec entirely — it's used by `_start_http`'s `/openapi.json` route today, `server.py:637-639`). For a non-GET route with a `:param` segment (e.g. `PUT /items/:id`), the `else` branch (`server.py:566-569`, prior to this fix) set `requestBody`'s schema to the *entire* `cached_schema` — including path-param properties — and never emitted a `"parameters"` list for path segments at all. `id` was documented only as a JSON body property, never as a path parameter; the GET branch (`server.py:551-565`), which already splits `properties` into `path` vs `query` via `param in path_param_names`, was unaffected.

**Fixed directly** (not just specified) in `server.py`'s `else` branch (`server.py:566-580` post-fix): `properties` and `cached_schema["required"]` are now filtered to exclude `path_param_names` before being wrapped into the `requestBody` schema (`{"type": "object", "properties": ..., "required": ...}`, with `"required"` included only when non-empty, matching this file's existing convention e.g. `scanner.py`/`to_json_schema`'s empty-list handling), `requestBody` itself gained `"required": True`, and — when `path_param_names` is non-empty — a `"parameters"` list is added alongside `requestBody`, one entry per path param: `{"name": name, "in": "path", "required": True, "schema": {"type": "string"}}`. This matches the GET branch's existing path-parameter shape and the fixes already applied in `nodejs/src/openapi.ts` and `swift/Sources/ZeroMcp/HttpServer.swift`.

Verified with `python3 -m unittest discover -s tests -q` (153 tests, all passing — `pytest` itself is not installed in this environment's Python; `unittest discover` runs the identical `unittest.TestCase`-based suite `pytest tests/` would collect). New coverage added in `python/tests/test_openapi.py`: a `PUT /items/:id` case asserting the path param appears in `parameters` and is excluded from the body schema's `properties`/`required`, a `POST /items` case (no path param) asserting no `parameters` key is added, a case asserting the `required` key is omitted from the body schema when no non-path fields are required, and a `GET /items/:id` case confirming that branch's pre-existing behavior is unchanged.

This means the Python port's planned reuse of `_build_openapi`/`build_openapi` for `registry.openapi` (see "Behavior" above) gets the corrected behavior for free — no divergent logic for the registry to carry, same conclusion the Swift spec reached for `buildOpenApiSpec()`.
4. **`create_registry` does not swallow schema errors.** `scanner.py`'s directory scan wraps `ToolScanner.scan()` in a broad `try/except Exception` inside `_build_state` (`server.py:20-25`), so a tool with a malformed `input` schema (an unknown type string, caught by `schema.to_json_schema`'s `ValueError`) is currently silently dropped along with everything else, logged only as "No tools directory found." `create_registry` does not replicate that swallowing: a bad `input` schema raises `ValueError` directly out of `create_registry`, since it's an explicit factory call over caller-provided data, not a best-effort directory scan. This is a deliberate behavior difference from the scanning path, not an oversight — flag if a reviewer expects registry errors to be silent the way scan errors currently are.
