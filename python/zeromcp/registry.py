"""Framework-neutral tool registry for MCP, REST adapters, and OpenAPI adapters."""

from __future__ import annotations

import sys
from dataclasses import dataclass
from typing import Any, Awaitable, Callable, Literal

from .remote import RemoteManager
from .schema import to_json_schema
from .server import build_openapi, handle_request

RouteMethod = Literal["GET", "POST", "PUT", "PATCH", "DELETE"]

# A JSON-RPC request/response round trip — same shape handle_request uses.
McpHandler = Callable[[dict], Awaitable["dict | None"]]


@dataclass(frozen=True)
class RouteDefinition:
    """One route-tagged tool, exposed as plain data. No HTTP routing/param-extraction here."""

    name: str
    method: RouteMethod
    path: str
    tool: dict  # the original caller-supplied tool dict, with its two-arg execute(args, env)


@dataclass(frozen=True)
class ToolRegistry:
    routes: list[RouteDefinition]
    openapi: dict
    mcp: McpHandler


async def create_registry(
    tools: dict[str, dict],
    *,
    get_env: Callable[[], Any] | None = None,
    title: str | None = None,
    version: str | None = None,
    execute_timeout: float | None = None,
    remote: list[dict] | None = None,
) -> ToolRegistry:
    """Build routes, an OpenAPI document and an MCP handler from an already-built tools dict.

    Each tool's ``execute(args, env)`` receives ``get_env()`` as ``env``.
    ``execute_timeout`` is in seconds (default 30). ``remote`` federates remote
    MCP servers the same way the ``remote`` config does: their tools appear in
    ``mcp`` as ``<server>.<tool>``, and a local tool with the same name wins.
    """
    env_fn = get_env or (lambda: {})

    internal: dict[str, dict] = {}
    if remote:
        internal.update(await RemoteManager().connect(remote))

    for name, tool in tools.items():
        if name in internal:
            _log(f'Local tool "{name}" overrides remote')
        entry: dict = {
            "description": tool.get("description", ""),
            "input": tool.get("input", {}),
            "_cached_schema": to_json_schema(tool.get("input", {})),
            "permissions": tool.get("permissions"),
            "execute": _bind_env(tool["execute"], env_fn),
        }
        if tool.get("route"):
            entry["route"] = tool["route"]
        internal[name] = entry

    routes: list[RouteDefinition] = []
    route_counts: dict[str, int] = {}
    for name, tool in tools.items():
        route = tool.get("route")
        if not route:
            continue
        key = f"{route['method']} {route['path']}"
        route_counts[key] = route_counts.get(key, 0) + 1
        routes.append(RouteDefinition(name=name, method=route["method"], path=route["path"], tool=tool))
    for key, count in route_counts.items():
        if count > 1:
            _log(
                f'{count} tools registered the same route "{key}" — only your own router\'s '
                "route matching, not this registry, decides which one runs"
            )

    state = {
        "tools": internal,
        "resources": {},
        "templates": {},
        "prompts": {},
        "subscriptions": set(),
        "execute_timeout": execute_timeout if execute_timeout is not None else 30,
        "page_size": 0,
        "log_level": "info",
        "icon": None,
        "title": title or "ZeroMCP",
        "version": version or "1.0.0",
    }

    async def mcp(request: dict) -> dict | None:
        return await handle_request(request, state)

    return ToolRegistry(routes=routes, openapi=build_openapi(state), mcp=mcp)


def _bind_env(execute: Callable[[dict, Any], Awaitable[Any]], get_env: Callable[[], Any]):
    def bound(args: dict):
        return execute(args, get_env())

    return bound


def _log(msg: str) -> None:
    print(f"[zeromcp] {msg}", file=sys.stderr)
