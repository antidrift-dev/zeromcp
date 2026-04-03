"""JSON-RPC 2.0 over stdio MCP server."""

from __future__ import annotations

import asyncio
import json
import sys

from .config import load_config, resolve_transports
from .scanner import ToolScanner
from .schema import to_json_schema, validate


async def serve(config_or_path: dict | str | None = None) -> None:
    """Start the MCP server with the given config."""
    if isinstance(config_or_path, str):
        config = load_config(config_or_path)
    else:
        config = config_or_path or {}

    all_tools: dict = {}

    # Load local tools
    scanner = ToolScanner(config)
    try:
        scanner.scan()
        all_tools.update(scanner.tools)
    except Exception:
        _log("No tools directory found")

    tool_count = len(all_tools)
    _log(f"{tool_count} tool(s) loaded")

    # Start transports
    transports = resolve_transports(config)
    for t in transports:
        if t["type"] == "stdio":
            await _start_stdio(all_tools)


async def _start_stdio(tools: dict) -> None:
    """Read JSON-RPC requests line-by-line from stdin, write responses to stdout."""
    _log("stdio transport ready")

    loop = asyncio.get_event_loop()
    reader = asyncio.StreamReader()
    protocol = asyncio.StreamReaderProtocol(reader)
    await loop.connect_read_pipe(lambda: protocol, sys.stdin)

    while True:
        try:
            line = await reader.readline()
        except Exception:
            break

        if not line:
            break

        line_str = line.decode("utf-8").strip()
        if not line_str:
            continue

        try:
            request = json.loads(line_str)
        except json.JSONDecodeError:
            continue

        response = await _handle_request(request, tools)
        if response is not None:
            out = json.dumps(response) + "\n"
            sys.stdout.write(out)
            sys.stdout.flush()


async def _handle_request(request: dict, tools: dict) -> dict | None:
    req_id = request.get("id")
    method = request.get("method", "")
    params = request.get("params", {})

    # Notification — no id, no response
    if req_id is None and method == "notifications/initialized":
        return None

    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {"listChanged": True}},
                "serverInfo": {"name": "zeromcp", "version": "0.1.0"},
            },
        }

    if method == "tools/list":
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {"tools": _build_tool_list(tools)},
        }

    if method == "tools/call":
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": await _call_tool(tools, params),
        }

    if method == "ping":
        return {"jsonrpc": "2.0", "id": req_id, "result": {}}

    # Unknown method
    if req_id is None:
        return None
    return {
        "jsonrpc": "2.0",
        "id": req_id,
        "error": {"code": -32601, "message": f"Method not found: {method}"},
    }


def _build_tool_list(tools: dict) -> list[dict]:
    result = []
    for name, tool in tools.items():
        result.append({
            "name": name,
            "description": tool["description"],
            "inputSchema": to_json_schema(tool["input"]),
        })
    return result


async def _call_tool(tools: dict, params: dict) -> dict:
    name = params.get("name", "")
    args = params.get("arguments", {})

    tool = tools.get(name)
    if not tool:
        return {
            "content": [{"type": "text", "text": f"Unknown tool: {name}"}],
            "isError": True,
        }

    schema = to_json_schema(tool["input"])
    errors = validate(args, schema)
    if errors:
        return {
            "content": [{"type": "text", "text": "Validation errors:\n" + "\n".join(errors)}],
            "isError": True,
        }

    try:
        result = await tool["execute"](args)
        if isinstance(result, str):
            text = result
        else:
            text = json.dumps(result, indent=2, default=str)
        return {"content": [{"type": "text", "text": text}]}
    except Exception as exc:
        return {
            "content": [{"type": "text", "text": f"Error: {exc}"}],
            "isError": True,
        }


def _log(msg: str) -> None:
    print(f"[zeromcp] {msg}", file=sys.stderr)
