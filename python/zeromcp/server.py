"""JSON-RPC 2.0 over stdio MCP server."""

from __future__ import annotations

import asyncio
import base64
import inspect
import json
import re
import sys

from .config import load_config, resolve_icon, resolve_transports
from .scanner import PromptScanner, ResourceScanner, ToolScanner
from .schema import validate


def _build_state(config: dict) -> dict:
    """Build server state from config: scan tools, resources, prompts."""
    all_tools: dict = {}
    scanner = ToolScanner(config)
    try:
        scanner.scan()
        all_tools.update(scanner.tools)
    except Exception:
        _log("No tools directory found")

    all_resources: dict = {}
    all_templates: dict = {}
    resource_scanner = ResourceScanner(config)
    try:
        resource_scanner.scan()
        all_resources.update(resource_scanner.resources)
        all_templates.update(resource_scanner.templates)
    except Exception:
        _log("No resources directory found")

    all_prompts: dict = {}
    prompt_scanner = PromptScanner(config)
    try:
        prompt_scanner.scan()
        all_prompts.update(prompt_scanner.prompts)
    except Exception:
        _log("No prompts directory found")

    icon = resolve_icon(config.get("icon"))

    tool_count = len(all_tools)
    res_count = len(all_resources) + len(all_templates)
    prompt_count = len(all_prompts)
    _log(f"{tool_count} tool(s), {res_count} resource(s), {prompt_count} prompt(s) loaded")

    return {
        "tools": all_tools,
        "resources": all_resources,
        "templates": all_templates,
        "prompts": all_prompts,
        "subscriptions": set(),
        "execute_timeout": config.get("execute_timeout", 30),
        "page_size": config.get("page_size", 0),
        "log_level": "info",
        "icon": icon,
    }


async def create_handler(config_or_path: dict | str | None = None):
    """Create a handler function that processes JSON-RPC requests.

    Returns an async function: (request: dict) -> dict | None

    Usage::

        handler = await create_handler("./tools")
        response = await handler(json_rpc_request)

    Works with any HTTP framework::

        @app.post("/mcp")
        async def mcp(request):
            return await handler(await request.json())
    """
    if isinstance(config_or_path, str):
        config = load_config(config_or_path)
    else:
        config = config_or_path or {}

    state = _build_state(config)

    async def handler(request: dict) -> dict | None:
        return await _handle_request(request, state)

    return handler


async def serve(config_or_path: dict | str | None = None) -> None:
    """Start the MCP server with the given config."""
    if isinstance(config_or_path, str):
        config = load_config(config_or_path)
    else:
        config = config_or_path or {}

    state = _build_state(config)

    # Start transports
    transports = resolve_transports(config)

    tasks = []
    for t in transports:
        if t["type"] == "stdio":
            tasks.append(_start_stdio(state))
        elif t["type"] == "http":
            port = t.get("port", 8080)
            host = t.get("host", "127.0.0.1")
            tasks.append(_start_http(state, host, port))

    if len(tasks) == 1:
        await tasks[0]
    elif tasks:
        await asyncio.gather(*tasks)


async def _start_stdio(state: dict) -> None:
    """Read JSON-RPC requests line-by-line from stdin, write responses to stdout."""
    _log("stdio transport ready")

    loop = asyncio.get_event_loop()
    reader = asyncio.StreamReader(limit=16 * 1024 * 1024)  # 16MB line limit
    protocol = asyncio.StreamReaderProtocol(reader)
    await loop.connect_read_pipe(lambda: protocol, sys.stdin)

    while True:
        try:
            line = await reader.readline()
        except Exception:
            break

        if not line:
            break

        try:
            line_str = line.decode("utf-8").strip()
        except UnicodeDecodeError:
            continue
        if not line_str:
            continue

        try:
            request = json.loads(line_str)
        except (json.JSONDecodeError, ValueError):
            continue

        # Guard against non-dict JSON
        if not isinstance(request, dict):
            continue

        response = await _handle_request(request, state)
        if response is not None:
            out = json.dumps(response) + "\n"
            sys.stdout.write(out)
            sys.stdout.flush()


# ---------------------------------------------------------------------------
# Pagination
# ---------------------------------------------------------------------------


def _encode_cursor(offset: int) -> str:
    return base64.b64encode(str(offset).encode()).decode("ascii")


def _decode_cursor(cursor: str) -> int:
    try:
        decoded = base64.b64decode(cursor).decode("utf-8")
        offset = int(decoded)
        return max(offset, 0)
    except Exception:
        return 0


def _paginate(items: list, cursor: str | None, page_size: int) -> tuple[list, str | None]:
    """Stateless cursor-based pagination. Returns (page, next_cursor)."""
    if not page_size or page_size <= 0:
        return items, None
    offset = _decode_cursor(cursor) if cursor else 0
    page = items[offset : offset + page_size]
    has_more = offset + page_size < len(items)
    next_cursor = _encode_cursor(offset + page_size) if has_more else None
    return page, next_cursor


# ---------------------------------------------------------------------------
# Template matching
# ---------------------------------------------------------------------------


def _match_template(template: str, uri: str) -> dict[str, str] | None:
    """Match a URI against a URI template with {param} placeholders."""
    pattern = re.sub(r"\{(\w+)\}", r"(?P<\1>[^/]+)", template)
    m = re.fullmatch(pattern, uri)
    return dict(m.groupdict()) if m else None


# ---------------------------------------------------------------------------
# Request dispatch
# ---------------------------------------------------------------------------


async def _handle_request(request: dict, state: dict) -> dict | None:
    req_id = request.get("id")
    method = request.get("method", "")
    params = request.get("params", {})
    if params is None:
        params = {}

    tools = state["tools"]
    resources = state["resources"]
    templates = state["templates"]
    prompts = state["prompts"]
    page_size = state["page_size"]
    icon = state.get("icon")
    execute_timeout = state["execute_timeout"]

    # --- Notifications (no id, no response) ---
    if req_id is None:
        if method == "notifications/initialized":
            return None
        if method == "notifications/roots/list_changed":
            return None
        return None

    # --- initialize ---
    if method == "initialize":
        capabilities: dict = {"tools": {"listChanged": True}}
        if resources or templates:
            capabilities["resources"] = {"subscribe": True, "listChanged": True}
        if prompts:
            capabilities["prompts"] = {"listChanged": True}
        capabilities["logging"] = {}
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": capabilities,
                "serverInfo": {"name": "zeromcp", "version": "0.2.0"},
            },
        }

    if method == "ping":
        return {"jsonrpc": "2.0", "id": req_id, "result": {}}

    # --- tools/list ---
    if method == "tools/list":
        cursor = params.get("cursor")
        tool_list = []
        for name, tool in tools.items():
            entry: dict = {
                "name": name,
                "description": tool["description"],
                "inputSchema": tool["_cached_schema"],
            }
            if icon:
                entry["icons"] = [{"uri": icon}]
            tool_list.append(entry)
        items, next_cursor = _paginate(tool_list, cursor, page_size)
        result: dict = {"tools": items}
        if next_cursor:
            result["nextCursor"] = next_cursor
        return {"jsonrpc": "2.0", "id": req_id, "result": result}

    # --- tools/call ---
    if method == "tools/call":
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": await _call_tool(tools, params, execute_timeout),
        }

    # --- resources/list ---
    if method == "resources/list":
        cursor = params.get("cursor")
        res_list = []
        for _, res in resources.items():
            entry = {
                "uri": res["uri"],
                "name": res["name"],
                "description": res.get("description"),
                "mimeType": res["mime_type"],
            }
            if icon:
                entry["icons"] = [{"uri": icon}]
            res_list.append(entry)
        items, next_cursor = _paginate(res_list, cursor, page_size)
        result = {"resources": items}
        if next_cursor:
            result["nextCursor"] = next_cursor
        return {"jsonrpc": "2.0", "id": req_id, "result": result}

    # --- resources/read ---
    if method == "resources/read":
        uri = params.get("uri", "")

        # Check static/dynamic resources
        for _, res in resources.items():
            if res["uri"] == uri:
                try:
                    text = await _call_read(res["read"])
                    return {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {"contents": [{"uri": uri, "mimeType": res["mime_type"], "text": text}]},
                    }
                except Exception as exc:
                    return {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "error": {"code": -32603, "message": f"Error reading resource: {exc}"},
                    }

        # Check templates
        for _, tmpl in templates.items():
            match = _match_template(tmpl["uri_template"], uri)
            if match:
                try:
                    text = await _call_read(tmpl["read"], match)
                    return {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "result": {"contents": [{"uri": uri, "mimeType": tmpl["mime_type"], "text": text}]},
                    }
                except Exception as exc:
                    return {
                        "jsonrpc": "2.0",
                        "id": req_id,
                        "error": {"code": -32603, "message": f"Error reading resource: {exc}"},
                    }

        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32002, "message": f"Resource not found: {uri}"},
        }

    # --- resources/subscribe ---
    if method == "resources/subscribe":
        uri = params.get("uri")
        if uri:
            state["subscriptions"].add(uri)
        return {"jsonrpc": "2.0", "id": req_id, "result": {}}

    # --- resources/templates/list ---
    if method == "resources/templates/list":
        cursor = params.get("cursor")
        tmpl_list = []
        for _, tmpl in templates.items():
            entry = {
                "uriTemplate": tmpl["uri_template"],
                "name": tmpl["name"],
                "description": tmpl.get("description"),
                "mimeType": tmpl["mime_type"],
            }
            if icon:
                entry["icons"] = [{"uri": icon}]
            tmpl_list.append(entry)
        items, next_cursor = _paginate(tmpl_list, cursor, page_size)
        result = {"resourceTemplates": items}
        if next_cursor:
            result["nextCursor"] = next_cursor
        return {"jsonrpc": "2.0", "id": req_id, "result": result}

    # --- prompts/list ---
    if method == "prompts/list":
        cursor = params.get("cursor")
        prompt_list = []
        for _, prompt in prompts.items():
            entry: dict = {"name": prompt["name"]}
            if prompt.get("description"):
                entry["description"] = prompt["description"]
            if prompt.get("arguments"):
                entry["arguments"] = prompt["arguments"]
            if icon:
                entry["icons"] = [{"uri": icon}]
            prompt_list.append(entry)
        items, next_cursor = _paginate(prompt_list, cursor, page_size)
        result = {"prompts": items}
        if next_cursor:
            result["nextCursor"] = next_cursor
        return {"jsonrpc": "2.0", "id": req_id, "result": result}

    # --- prompts/get ---
    if method == "prompts/get":
        name = params.get("name", "")
        args = params.get("arguments", {})
        prompt = prompts.get(name)
        if not prompt:
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32002, "message": f"Prompt not found: {name}"},
            }
        try:
            render_fn = prompt["render"]
            if inspect.iscoroutinefunction(render_fn):
                messages = await render_fn(args)
            else:
                messages = render_fn(args)
            return {"jsonrpc": "2.0", "id": req_id, "result": {"messages": messages}}
        except Exception as exc:
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32603, "message": f"Error rendering prompt: {exc}"},
            }

    # --- logging/setLevel ---
    if method == "logging/setLevel":
        level = params.get("level")
        if level:
            state["log_level"] = level
        return {"jsonrpc": "2.0", "id": req_id, "result": {}}

    # --- completion/complete ---
    if method == "completion/complete":
        return {"jsonrpc": "2.0", "id": req_id, "result": {"completion": {"values": []}}}

    # Unknown method
    return {
        "jsonrpc": "2.0",
        "id": req_id,
        "error": {"code": -32601, "message": f"Method not found: {method}"},
    }


async def _call_read(read_fn, *args):
    """Call a read function, handling both sync and async."""
    if inspect.iscoroutinefunction(read_fn):
        return await read_fn(*args)
    return read_fn(*args)


async def _call_tool(tools: dict, params: dict, execute_timeout: float = 30) -> dict:
    name = params.get("name", "") if isinstance(params, dict) else ""
    args = params.get("arguments") if isinstance(params, dict) else None
    if args is None:
        args = {}

    tool = tools.get(name)
    if not tool:
        return {
            "content": [{"type": "text", "text": f"Unknown tool: {name}"}],
            "isError": True,
        }

    errors = validate(args, tool["_cached_schema"])
    if errors:
        return {
            "content": [{"type": "text", "text": "Validation errors:\n" + "\n".join(errors)}],
            "isError": True,
        }

    # Tool-level timeout overrides config default
    perms = tool.get("permissions") or {}
    timeout = perms.get("execute_timeout", execute_timeout)

    try:
        result = await asyncio.wait_for(tool["execute"](args), timeout=timeout)
        if isinstance(result, str):
            text = result
        else:
            text = json.dumps(result, default=str)
        return {"content": [{"type": "text", "text": text}]}
    except asyncio.TimeoutError:
        return {
            "content": [{"type": "text", "text": f'Error: Tool "{name}" timed out after {timeout}s'}],
            "isError": True,
        }
    except Exception as exc:
        return {
            "content": [{"type": "text", "text": f"Error: {exc}"}],
            "isError": True,
        }


def _match_route_path(pattern: str, pathname: str) -> dict[str, str] | None:
    """Match a URL pathname against a route pattern with :param segments."""
    # Split on :param tokens, escape static segments, replace params with named groups
    parts = re.split(r"(:\w+)", pattern)
    regex_parts = []
    for part in parts:
        if re.match(r":\w+", part):
            param_name = part[1:]
            regex_parts.append(f"(?P<{param_name}>[^/]+)")
        else:
            regex_parts.append(re.escape(part))
    regex = "".join(regex_parts)
    m = re.fullmatch(regex, pathname)
    return dict(m.groupdict()) if m else None


async def _handle_http_route(tool: dict, path_params: dict, method: str, body: bytes, query_string: str) -> tuple[int, dict]:
    """Dispatch an HTTP request to a tool and return (status, response_dict)."""
    import urllib.parse
    args: dict = dict(path_params)
    if method == "GET":
        qs = urllib.parse.parse_qs(query_string, keep_blank_values=True)
        for k, v in qs.items():
            args[k] = v[0] if len(v) == 1 else v
    else:
        if body:
            try:
                body_data = json.loads(body)
                if isinstance(body_data, dict):
                    args.update(body_data)
            except (json.JSONDecodeError, ValueError):
                pass
    try:
        result = await asyncio.wait_for(tool["execute"](args), timeout=30)
        if isinstance(result, str):
            payload = result
        else:
            payload = json.dumps(result, default=str)
        return 200, {"ok": True, "result": payload}
    except Exception as exc:
        return 500, {"ok": False, "error": str(exc)}


async def _start_http(state: dict, host: str, port: int) -> None:
    """Start a minimal HTTP server that handles /mcp (JSON-RPC) and tool routes."""
    import urllib.parse

    _log(f"http transport ready on {host}:{port}")

    async def handle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        try:
            raw = await reader.read(65536)
        except Exception:
            writer.close()
            return

        try:
            header_part, _, body = raw.partition(b"\r\n\r\n")
            header_lines = header_part.decode("utf-8", errors="replace").splitlines()
            if not header_lines:
                writer.close()
                return
            request_line = header_lines[0]
            parts = request_line.split(" ")
            if len(parts) < 2:
                writer.close()
                return
            req_method = parts[0].upper()
            raw_path = parts[1]
            parsed = urllib.parse.urlparse(raw_path)
            pathname = parsed.path
            query_string = parsed.query

            content_length = 0
            for h in header_lines[1:]:
                if h.lower().startswith("content-length:"):
                    try:
                        content_length = int(h.split(":", 1)[1].strip())
                    except ValueError:
                        pass

            body = body[:content_length] if content_length else body

            # /mcp — JSON-RPC handler
            if pathname == "/mcp" and req_method == "POST":
                try:
                    request = json.loads(body)
                except (json.JSONDecodeError, ValueError):
                    _http_respond(writer, 400, {"error": "invalid JSON"})
                    return
                response = await _handle_request(request, state)
                _http_respond(writer, 200, response)
                return

            # Route-based tool dispatch
            tools = state["tools"]
            for tool in tools.values():
                route = tool.get("route")
                if not route:
                    continue
                if route["method"] != req_method:
                    continue
                path_params = _match_route_path(route["path"], pathname)
                if path_params is None:
                    continue
                status, resp = await _handle_http_route(tool, path_params, req_method, body, query_string)
                _http_respond(writer, status, resp)
                return

            _http_respond(writer, 404, {"error": "not found"})
        except Exception as exc:
            _http_respond(writer, 500, {"error": str(exc)})
        finally:
            try:
                writer.close()
            except Exception:
                pass

    server = await asyncio.start_server(handle, host, port)
    async with server:
        await server.serve_forever()


def _http_respond(writer: asyncio.StreamWriter, status: int, body: object) -> None:
    """Write a minimal HTTP/1.1 JSON response."""
    status_text = {200: "OK", 400: "Bad Request", 404: "Not Found", 500: "Internal Server Error"}.get(status, "OK")
    payload = json.dumps(body).encode("utf-8")
    response = (
        f"HTTP/1.1 {status} {status_text}\r\n"
        f"Content-Type: application/json\r\n"
        f"Content-Length: {len(payload)}\r\n"
        f"Connection: close\r\n"
        f"\r\n"
    ).encode("utf-8") + payload
    writer.write(response)


def _log(msg: str) -> None:
    print(f"[zeromcp] {msg}", file=sys.stderr)
