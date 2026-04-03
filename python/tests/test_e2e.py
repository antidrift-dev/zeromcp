"""End-to-end test: spawn the server, send JSON-RPC requests over stdio."""

import asyncio
import json
import os
import sys
import unittest
from pathlib import Path

TOOLS_DIR = str(Path(__file__).parent.parent / "examples" / "tools")
PROJECT_DIR = str(Path(__file__).parent.parent)


class TestE2E(unittest.TestCase):
    def test_initialize_list_and_call(self):
        asyncio.run(self._run_e2e())

    async def _run_e2e(self):
        proc = await asyncio.create_subprocess_exec(
            sys.executable, "-m", "zeromcp", "serve", TOOLS_DIR,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=PROJECT_DIR,
        )

        async def send_request(request: dict) -> dict:
            line = json.dumps(request) + "\n"
            proc.stdin.write(line.encode())
            await proc.stdin.drain()
            resp_line = await asyncio.wait_for(proc.stdout.readline(), timeout=5.0)
            return json.loads(resp_line.decode().strip())

        try:
            # Give the server a moment to load
            await asyncio.sleep(0.5)

            # Initialize
            init_res = await send_request({
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "test", "version": "1.0"},
                },
            })
            self.assertEqual(init_res["result"]["protocolVersion"], "2024-11-05")
            self.assertEqual(init_res["result"]["serverInfo"]["name"], "zeromcp")

            # Send initialized notification (no response expected)
            notif = json.dumps({"jsonrpc": "2.0", "method": "notifications/initialized"}) + "\n"
            proc.stdin.write(notif.encode())
            await proc.stdin.drain()

            # List tools
            list_res = await send_request({
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/list",
                "params": {},
            })
            tool_names = sorted(t["name"] for t in list_res["result"]["tools"])
            self.assertIn("hello", tool_names)
            self.assertIn("add", tool_names)
            self.assertIn("create_invoice", tool_names)

            # Call hello tool
            call_res = await send_request({
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": {"name": "hello", "arguments": {"name": "World"}},
            })
            self.assertEqual(call_res["result"]["content"][0]["text"], "Hello, World!")

            # Call add tool
            add_res = await send_request({
                "jsonrpc": "2.0",
                "id": 4,
                "method": "tools/call",
                "params": {"name": "add", "arguments": {"a": 3, "b": 4}},
            })
            result = json.loads(add_res["result"]["content"][0]["text"])
            self.assertEqual(result["sum"], 7)

            # Validation error
            err_res = await send_request({
                "jsonrpc": "2.0",
                "id": 5,
                "method": "tools/call",
                "params": {"name": "add", "arguments": {"a": "not a number", "b": 4}},
            })
            self.assertTrue(err_res["result"]["isError"])

            # Unknown tool
            unk_res = await send_request({
                "jsonrpc": "2.0",
                "id": 6,
                "method": "tools/call",
                "params": {"name": "nonexistent", "arguments": {}},
            })
            self.assertTrue(unk_res["result"]["isError"])

            # Ping
            ping_res = await send_request({
                "jsonrpc": "2.0",
                "id": 7,
                "method": "ping",
                "params": {},
            })
            self.assertEqual(ping_res["result"], {})

        finally:
            proc.terminate()
            await proc.wait()


if __name__ == "__main__":
    unittest.main()
