"""A fake remote MCP server for remote-federation tests (mirrors nodejs/test/handler-remote.test.js)."""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOOLS = [
    {
        "name": "list_pages",
        "description": "Lists pages.",
        "inputSchema": {"type": "object", "properties": {"domain": {"type": "string"}}, "required": ["domain"]},
    },
    {
        "name": "get_page",
        "description": "Gets a page.",
        "inputSchema": {"type": "object", "properties": {"url": {"type": "string"}}, "required": ["url"]},
    },
]


class FakeUpstream:
    """Serves initialize, tools/list and tools/call on 127.0.0.1:<random port>.

    ``status`` forces every response to that HTTP status. ``requests`` records
    (method, Authorization header, params) for each call.
    """

    def __init__(self, status: int = 200, tools: list[dict] | None = None):
        self.status = status
        self.tools = TOOLS if tools is None else tools
        self.requests: list[tuple[str, str | None, dict]] = []
        upstream = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                upstream.requests.append((body["method"], self.headers.get("Authorization"), body.get("params")))
                payload = json.dumps({"jsonrpc": "2.0", "id": body.get("id"), **upstream._respond(body)}).encode()
                self.send_response(upstream.status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *args):
                pass

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self._server.server_address[1]}"
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)

    def _respond(self, body: dict) -> dict:
        method = body["method"]
        if method == "initialize":
            return {"result": {"protocolVersion": "2025-03-26", "capabilities": {}, "serverInfo": {"name": "probeo", "version": "test"}}}
        if method == "tools/list":
            return {"result": {"tools": self.tools}}
        if method == "tools/call":
            return {"result": {"content": [{"type": "text", "text": json.dumps({"pages": [], "args": body["params"]["arguments"]})}]}}
        return {"error": {"message": f"Unexpected method: {method}"}}

    def __enter__(self) -> "FakeUpstream":
        self._thread.start()
        return self

    def __exit__(self, *exc) -> None:
        self._server.shutdown()
        self._server.server_close()
