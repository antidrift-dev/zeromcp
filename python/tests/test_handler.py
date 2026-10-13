"""Tests for create_handler / serve state: remote merge and runtime context."""

import asyncio
import contextlib
import io
import json
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock

from fake_upstream import FakeUpstream

from zeromcp.server import _build_state, create_handler

RUNTIME_TOOLS = str(Path(__file__).parent / "fixtures" / "runtime_tools")


def call(handler, req_id, method, params=None):
    return asyncio.run(handler({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params or {}}))


def quiet(fn, *args, **kwargs):
    stderr = io.StringIO()
    with contextlib.redirect_stderr(stderr):
        result = fn(*args, **kwargs)
    return result, stderr.getvalue()


class TestHandlerRemote(unittest.TestCase):
    def test_create_handler_composes_remote_tools(self):
        with FakeUpstream() as up:
            handler, _ = quiet(asyncio.run, create_handler(
                {"tools": [], "remote": [{"name": "probeo", "url": up.url, "tools": ["list_pages"]}]}
            ))
            listed = call(handler, 1, "tools/list")
            self.assertEqual([t["name"] for t in listed["result"]["tools"]], ["probeo.list_pages"])

            called = call(handler, 2, "tools/call", {"name": "probeo.list_pages", "arguments": {"domain": "example.com"}})
        self.assertEqual(
            json.loads(called["result"]["content"][0]["text"]),
            {"pages": [], "args": {"domain": "example.com"}},
        )

    def test_local_tool_overrides_remote(self):
        with tempfile.TemporaryDirectory() as tools_dir, FakeUpstream() as up:
            Path(tools_dir, "list_pages.py").write_text(textwrap.dedent("""
                tool = {"description": "Local list_pages", "input": {}}

                async def execute(args, ctx):
                    return "local"
            """))
            config = {
                "tools": [{"path": tools_dir, "prefix": "probeo"}],
                "separator": ".",
                "remote": [{"name": "probeo", "url": up.url}],
            }
            handler, log = quiet(asyncio.run, create_handler(config))
            listed = {t["name"]: t for t in call(handler, 1, "tools/list")["result"]["tools"]}
            called = call(handler, 2, "tools/call", {"name": "probeo.list_pages", "arguments": {}})

        self.assertEqual(sorted(listed), ["probeo.get_page", "probeo.list_pages"])
        self.assertEqual(listed["probeo.list_pages"]["description"], "Local list_pages")
        self.assertEqual(called["result"]["content"][0]["text"], "local")
        self.assertIn('[zeromcp] Local tool "probeo.list_pages" overrides remote', log)

    def test_remote_tools_have_no_route(self):
        with FakeUpstream() as up:
            state, _ = quiet(asyncio.run, _build_state({"tools": [], "remote": [{"name": "probeo", "url": up.url}]}))
        self.assertTrue(all("route" not in t for t in state["tools"].values()))


class TestServeExit(unittest.TestCase):
    def test_exits_without_tools_remotes_resources_or_prompts(self):
        with mock.patch("zeromcp.server.ToolScanner.scan", side_effect=OSError("no dir")):
            with self.assertRaises(SystemExit) as cm:
                quiet(asyncio.run, _build_state({}, exit_without_sources=True))
        self.assertEqual(cm.exception.code, 1)

    def test_does_not_exit_when_prompts_configured(self):
        with mock.patch("zeromcp.server.ToolScanner.scan", side_effect=OSError("no dir")):
            state, log = quiet(asyncio.run, _build_state({"prompts": "./nope"}, exit_without_sources=True))
        self.assertEqual(state["tools"], {})
        self.assertIn("No tools directory found", log)

    def test_create_handler_never_exits(self):
        with mock.patch("zeromcp.server.ToolScanner.scan", side_effect=OSError("no dir")):
            handler, _ = quiet(asyncio.run, create_handler({}))
        self.assertEqual(call(handler, 1, "tools/list")["result"]["tools"], [])


class TestRuntimeContext(unittest.TestCase):
    def test_get_runtime_reaches_ctx_runtime_on_every_call(self):
        calls = []

        def get_runtime():
            calls.append(1)
            return {"user": "a", "n": len(calls)}

        handler, _ = quiet(asyncio.run, create_handler({"tools": RUNTIME_TOOLS}, get_runtime=get_runtime))
        first = call(handler, 1, "tools/call", {"name": "whoami", "arguments": {}})
        second = call(handler, 2, "tools/call", {"name": "whoami", "arguments": {}})

        self.assertEqual(json.loads(first["result"]["content"][0]["text"]), {"runtime": {"user": "a", "n": 1}})
        self.assertEqual(json.loads(second["result"]["content"][0]["text"]), {"runtime": {"user": "a", "n": 2}})
        self.assertEqual(len(calls), 2)

    def test_runtime_is_none_without_get_runtime(self):
        handler, _ = quiet(asyncio.run, create_handler({"tools": RUNTIME_TOOLS}))
        res = call(handler, 1, "tools/call", {"name": "whoami", "arguments": {}})
        self.assertEqual(json.loads(res["result"]["content"][0]["text"]), {"runtime": None})


if __name__ == "__main__":
    unittest.main()
