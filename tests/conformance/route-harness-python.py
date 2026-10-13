"""Route conformance harness for Python (test-only).

ZeroMCP for Python ships no HTTP server. This mounts zeromcp.create_registry on the
stdlib ThreadingHTTPServer the way a user would mount it in their own server.
"""

from __future__ import annotations

import asyncio
import importlib.util
import json
import re
import sys
import threading
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent.parent / "python"))

from zeromcp import create_registry  # noqa: E402

PORT = 14251

DOCS_HTML = """<!DOCTYPE html>
<html>
<head>
  <title>ZeroMCP API</title>
  <meta charset="utf-8"/>
  <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist/swagger-ui.css">
</head>
<body>
<div id="swagger-ui"></div>
<script src="https://unpkg.com/swagger-ui-dist/swagger-ui-bundle.js"></script>
<script>SwaggerUIBundle({ url: '/openapi.json', dom_id: '#swagger-ui' })</script>
</body>
</html>"""


def load_tools(directory: Path) -> dict:
    tools: dict = {}
    for path in sorted(directory.glob("*.py")):
        spec = importlib.util.spec_from_file_location(f"route_tool_{path.stem}", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        tool = module.tool
        entry = {
            "description": tool.get("description", ""),
            "input": tool.get("input", {}),
            "execute": module.execute,
        }
        if tool.get("route"):
            entry["route"] = tool["route"]
        tools[path.stem] = entry
    return tools


def match_path(pattern: str, pathname: str) -> dict | None:
    regex = "".join(
        f"(?P<{part[1:]}>[^/]+)" if re.fullmatch(r":\w+", part) else re.escape(part)
        for part in re.split(r"(:\w+)", pattern)
    )
    m = re.fullmatch(regex, pathname)
    return m.groupdict() if m else None


loop = asyncio.new_event_loop()
threading.Thread(target=loop.run_forever, daemon=True).start()


def run(coro):
    return asyncio.run_coroutine_threadsafe(coro, loop).result()


registry = run(create_registry(load_tools(HERE / "route-tools")))


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def _send(self, status: int, body, content_type: str = "application/json") -> None:
        data = body.encode("utf-8") if isinstance(body, str) else json.dumps(body).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _body(self) -> bytes:
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def _dispatch(self, method: str) -> None:
        parsed = urllib.parse.urlparse(self.path)
        pathname = parsed.path
        body = self._body() if method != "GET" else b""

        if method == "GET" and pathname == "/health":
            return self._send(200, {"ok": True})
        if method == "GET" and pathname == "/openapi.json":
            return self._send(200, registry.openapi)
        if method == "GET" and pathname == "/docs":
            return self._send(200, DOCS_HTML, "text/html; charset=utf-8")
        if method == "POST" and pathname == "/mcp":
            try:
                request = json.loads(body)
            except ValueError:
                return self._send(400, {"error": "invalid JSON"})
            return self._send(200, run(registry.mcp(request)))

        for route in registry.routes:
            if route.method != method:
                continue
            params = match_path(route.path, pathname)
            if params is None:
                continue
            args = dict(params)
            if method == "GET":
                for k, v in urllib.parse.parse_qs(parsed.query, keep_blank_values=True).items():
                    args[k] = v[0] if len(v) == 1 else v
            elif body:
                try:
                    data = json.loads(body)
                    if isinstance(data, dict):
                        args.update(data)
                except ValueError:
                    pass
            try:
                result = run(route.tool["execute"](args, {}))
            except Exception as exc:
                return self._send(500, {"ok": False, "error": str(exc)})
            return self._send(200, {"ok": True, "result": result})

        self._send(404, {"error": "not found"})

    def do_GET(self):
        self._dispatch("GET")

    def do_POST(self):
        self._dispatch("POST")

    def do_PUT(self):
        self._dispatch("PUT")

    def do_PATCH(self):
        self._dispatch("PATCH")

    def do_DELETE(self):
        self._dispatch("DELETE")


if __name__ == "__main__":
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
