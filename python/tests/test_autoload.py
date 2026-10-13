"""Tests for autoload_tools: polling ToolScanner.watch and the stdio notify writer."""

import asyncio
import contextlib
import io
import json
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock

import zeromcp.scanner as scanner_mod
from zeromcp.scanner import ToolScanner
from zeromcp.server import _stdio_notify


def tool_source(description: str) -> str:
    return textwrap.dedent(f"""
        tool = {{"description": {description!r}, "input": {{}}}}

        async def execute(args, ctx):
            return {description!r}
    """)


class TestWatch(unittest.TestCase):
    def test_change_and_new_file_trigger_rescan(self):
        asyncio.run(self._run())

    async def _run(self):
        with tempfile.TemporaryDirectory() as tools_dir, \
                mock.patch.object(scanner_mod, "_AUTOLOAD_POLL_INTERVAL", 0.02), \
                contextlib.redirect_stderr(io.StringIO()) as stderr:
            Path(tools_dir, "hello.py").write_text(tool_source("v1"))
            scanner = ToolScanner({"tools": tools_dir})
            scanner.scan()
            self.assertEqual(scanner.tools["hello"]["description"], "v1")

            changes: list[dict] = []
            changed = asyncio.Event()

            def on_change(tools):
                changes.append({name: t["description"] for name, t in tools.items()})
                changed.set()

            task = asyncio.create_task(scanner.watch(on_change))
            await asyncio.sleep(0.05)

            # Different length so a same-second edit can't reuse stale bytecode.
            Path(tools_dir, "hello.py").write_text(tool_source("version two"))
            Path(tools_dir, "added.py").write_text(tool_source("added"))
            await asyncio.wait_for(changed.wait(), timeout=2)

            scanner.stop()
            with self.assertRaises(asyncio.CancelledError):
                await task

        self.assertEqual(changes[-1], {"added": "added", "hello": "version two"})
        self.assertIn("[zeromcp] Change detected: hello.py", stderr.getvalue())
        self.assertIn("[zeromcp] Change detected: added.py", stderr.getvalue())

    def test_no_change_no_callback(self):
        async def run():
            with tempfile.TemporaryDirectory() as tools_dir, \
                    mock.patch.object(scanner_mod, "_AUTOLOAD_POLL_INTERVAL", 0.02), \
                    contextlib.redirect_stderr(io.StringIO()):
                Path(tools_dir, "hello.py").write_text(tool_source("v1"))
                scanner = ToolScanner({"tools": tools_dir})
                scanner.scan()
                calls = []
                task = asyncio.create_task(scanner.watch(lambda tools: calls.append(1)))
                await asyncio.sleep(0.15)
                scanner.stop()
                with self.assertRaises(asyncio.CancelledError):
                    await task
                return calls

        self.assertEqual(asyncio.run(run()), [])


class TestStdioNotify(unittest.TestCase):
    def test_writes_notification_line(self):
        out = io.StringIO()
        with mock.patch("sys.stdout", out):
            _stdio_notify("notifications/tools/list_changed", {})
        self.assertEqual(json.loads(out.getvalue()), {
            "jsonrpc": "2.0", "method": "notifications/tools/list_changed", "params": {},
        })
        self.assertTrue(out.getvalue().endswith("\n"))

    def test_omits_params_when_none(self):
        out = io.StringIO()
        with mock.patch("sys.stdout", out):
            _stdio_notify("notifications/initialized")
        self.assertEqual(json.loads(out.getvalue()), {"jsonrpc": "2.0", "method": "notifications/initialized"})


if __name__ == "__main__":
    unittest.main()
