"""Tests for remote MCP server federation (zeromcp.remote)."""

import asyncio
import contextlib
import io
import json
import os
import unittest
from unittest import mock

from zeromcp.remote import RemoteManager, _schema_to_input

from fake_upstream import FakeUpstream


def connect(servers):
    stderr = io.StringIO()
    with contextlib.redirect_stderr(stderr):
        tools = asyncio.run(RemoteManager().connect(servers))
    return tools, stderr.getvalue()


class TestRemoteManager(unittest.TestCase):
    def test_tools_are_namespaced_by_server(self):
        with FakeUpstream() as up:
            tools, log = connect([{"name": "probeo", "url": up.url}])
        self.assertEqual(sorted(tools), ["probeo.get_page", "probeo.list_pages"])
        self.assertIn("[mcp] Remote tool: probeo.list_pages", log)
        self.assertIn("[mcp] Connected to probeo (HTTP): 2 tool(s)", log)
        self.assertEqual([m for m, _, _ in up.requests], ["initialize", "tools/list"])

    def test_execute_unwraps_first_text_content(self):
        with FakeUpstream() as up:
            tools, _ = connect([{"name": "probeo", "url": up.url}])
            result = asyncio.run(tools["probeo.list_pages"]["execute"]({"domain": "example.com"}))
            self.assertEqual(up.requests[-1][2], {"name": "list_pages", "arguments": {"domain": "example.com"}})
        self.assertEqual(json.loads(result), {"pages": [], "args": {"domain": "example.com"}})

    def test_allowlist_limits_exposed_tools(self):
        with FakeUpstream() as up:
            tools, _ = connect([{"name": "probeo", "url": up.url, "tools": ["list_pages"]}])
        self.assertEqual(list(tools), ["probeo.list_pages"])

    def test_empty_allowlist_exposes_nothing(self):
        with FakeUpstream() as up:
            tools, _ = connect([{"name": "probeo", "url": up.url, "tools": []}])
        self.assertEqual(tools, {})

    def test_literal_auth_sent_as_bearer(self):
        with FakeUpstream() as up:
            connect([{"name": "probeo", "url": up.url, "auth": "secret"}])
        self.assertTrue(all(auth == "Bearer secret" for _, auth, _ in up.requests))

    def test_env_auth_resolved(self):
        with FakeUpstream() as up, mock.patch.dict(os.environ, {"PROBEO_TOKEN": "from-env"}):
            connect([{"name": "probeo", "url": up.url, "auth": "env:PROBEO_TOKEN"}])
        self.assertTrue(all(auth == "Bearer from-env" for _, auth, _ in up.requests))

    def test_no_auth_header_without_auth(self):
        with FakeUpstream() as up:
            connect([{"name": "probeo", "url": up.url}])
        self.assertTrue(all(auth is None for _, auth, _ in up.requests))

    def test_non_http_url_is_skipped(self):
        tools, log = connect([{"name": "local", "url": "stdio://thing"}])
        self.assertEqual(tools, {})
        self.assertIn('[mcp] Failed to connect to local: Remote server "local" must have an HTTP/HTTPS URL, got: stdio://thing', log)

    def test_failing_server_skipped_and_others_load(self):
        with FakeUpstream(status=500) as bad, FakeUpstream() as good:
            tools, log = connect([{"name": "bad", "url": bad.url}, {"name": "good", "url": good.url}])
        self.assertEqual(sorted(tools), ["good.get_page", "good.list_pages"])
        self.assertIn("[mcp] Failed to connect to bad: HTTP 500", log)


class TestSchemaToInput(unittest.TestCase):
    def test_missing_properties(self):
        self.assertEqual(_schema_to_input(None), {})
        self.assertEqual(_schema_to_input({"type": "object"}), {})

    def test_required_without_description_is_bare_type(self):
        schema = {"properties": {"n": {"type": "number"}}, "required": ["n"]}
        self.assertEqual(_schema_to_input(schema), {"n": "number"})

    def test_description_and_optional(self):
        schema = {
            "properties": {
                "a": {"type": "string", "description": "A"},
                "b": {"type": "boolean"},
                "c": {},
            },
            "required": ["a", "c"],
        }
        self.assertEqual(_schema_to_input(schema), {
            "a": {"type": "string", "description": "A"},
            "b": {"type": "boolean", "optional": True},
            "c": "string",
        })


if __name__ == "__main__":
    unittest.main()
