"""Connect to remote MCP servers over HTTP and expose their tools locally."""

from __future__ import annotations

import asyncio
import json
import sys
import time
import urllib.error
import urllib.request

from .config import resolve_auth
from .schema import to_json_schema


class RemoteManager:
    def __init__(self) -> None:
        self.connections: dict = {}

    async def connect(self, servers: list[dict]) -> dict[str, dict]:
        """Connect to each server and return its tools namespaced as ``<server>.<tool>``.

        A server that fails to connect is logged and skipped.
        """
        all_tools: dict[str, dict] = {}
        for server in servers:
            try:
                tools = await self._connect_one(server)
                for tool_name, tool in tools.items():
                    namespaced = f"{server['name']}.{tool_name}"
                    all_tools[namespaced] = tool
                    _log(f"Remote tool: {namespaced}")
            except Exception as exc:
                _log(f"Failed to connect to {server.get('name')}: {exc}")
        return all_tools

    async def _connect_one(self, server: dict) -> dict[str, dict]:
        url = server["url"]
        if not (url.startswith("http://") or url.startswith("https://")):
            raise ValueError(f'Remote server "{server["name"]}" must have an HTTP/HTTPS URL, got: {url}')

        auth = resolve_auth(server.get("auth"))

        await _http_rpc(url, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}, auth)
        list_res = await _http_rpc(url, {"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}}, auth)

        remote_tools = ((list_res or {}).get("result") or {}).get("tools") or []
        allowed = server.get("tools")
        if allowed is not None:
            remote_tools = [t for t in remote_tools if t.get("name") in allowed]

        tools: dict[str, dict] = {}
        for rt in remote_tools:
            input_schema = _schema_to_input(rt.get("inputSchema"))
            tools[rt["name"]] = {
                "description": rt.get("description"),
                "input": input_schema,
                "_cached_schema": to_json_schema(input_schema),
                "execute": _make_execute(url, rt["name"], auth),
            }

        _log(f"Connected to {server['name']} (HTTP): {len(tools)} tool(s)")
        return tools

    def stop(self) -> None:
        self.connections.clear()


def _make_execute(url: str, tool_name: str, auth: str | None):
    async def execute(args: dict):
        call_res = await _http_rpc(url, {
            "jsonrpc": "2.0",
            "id": int(time.time() * 1000),
            "method": "tools/call",
            "params": {"name": tool_name, "arguments": args},
        }, auth)
        result = (call_res or {}).get("result")
        content = (result or {}).get("content") if isinstance(result, dict) else None
        if content and isinstance(content[0], dict) and content[0].get("text"):
            return content[0]["text"]
        return result

    return execute


async def _http_rpc(url: str, body: dict, auth: str | None) -> dict:
    headers = {"Content-Type": "application/json"}
    if auth:
        headers["Authorization"] = f"Bearer {auth}"
    data = json.dumps(body).encode("utf-8")

    def post() -> dict:
        req = urllib.request.Request(url, data=data, headers=headers, method="POST")
        try:
            with urllib.request.urlopen(req) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as exc:
            raise RuntimeError(f"HTTP {exc.code}") from None

    return await asyncio.to_thread(post)


def _schema_to_input(schema: dict | None) -> dict:
    """Convert a remote tool's JSON Schema back to the simplified input form."""
    input_schema: dict = {}
    if not schema or not schema.get("properties"):
        return input_schema

    required = schema.get("required") or []
    for key, prop in schema["properties"].items():
        prop = prop or {}
        type_name = prop.get("type") or "string"
        is_required = key in required
        description = prop.get("description")

        if description or not is_required:
            entry: dict = {"type": type_name}
            if description:
                entry["description"] = description
            if not is_required:
                entry["optional"] = True
            input_schema[key] = entry
        else:
            input_schema[key] = type_name

    return input_schema


def _log(msg: str) -> None:
    print(f"[mcp] {msg}", file=sys.stderr)
