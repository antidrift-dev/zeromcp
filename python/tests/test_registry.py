"""Tests for the framework-neutral tool registry (zeromcp.registry)."""

import asyncio
import contextlib
import io
import json
import unittest

from fake_upstream import FakeUpstream

from zeromcp import create_registry
from zeromcp.registry import RouteDefinition, ToolRegistry


async def greet(args, env):
    return f"Hello, {args['name']}! ({env.get('who', 'none')})"


async def create(args, env):
    return {"created": args["title"]}


async def internal(args, env):
    return "internal"


def make_tools():
    return {
        "greet": {
            "description": "Greet someone",
            "input": {"name": "string"},
            "route": {"method": "GET", "path": "/greet/:name"},
            "execute": greet,
        },
        "internal": {"description": "No route", "input": {}, "execute": internal},
        "create_item": {
            "description": "Create an item",
            "input": {"title": "string"},
            "route": {"method": "POST", "path": "/items"},
            "execute": create,
        },
    }


def build(tools=None, **kwargs):
    stderr = io.StringIO()
    with contextlib.redirect_stderr(stderr):
        registry = asyncio.run(create_registry(make_tools() if tools is None else tools, **kwargs))
    return registry, stderr.getvalue()


def mcp(registry, req_id, method, params=None):
    return asyncio.run(registry.mcp({"jsonrpc": "2.0", "id": req_id, "method": method, "params": params or {}}))


class TestRoutes(unittest.TestCase):
    def test_routes_keep_only_routed_tools_in_order(self):
        registry, _ = build()
        self.assertIsInstance(registry, ToolRegistry)
        self.assertEqual(
            [(r.name, r.method, r.path) for r in registry.routes],
            [("greet", "GET", "/greet/:name"), ("create_item", "POST", "/items")],
        )
        self.assertTrue(all(isinstance(r, RouteDefinition) for r in registry.routes))

    def test_route_tool_is_the_original_two_arg_tool(self):
        tools = make_tools()
        registry, _ = build(tools)
        route = registry.routes[0]
        self.assertIs(route.tool, tools["greet"])
        self.assertEqual(asyncio.run(route.tool["execute"]({"name": "Ann"}, {"who": "me"})), "Hello, Ann! (me)")

    def test_no_routes(self):
        registry, _ = build({"internal": make_tools()["internal"]})
        self.assertEqual(registry.routes, [])
        self.assertEqual(registry.openapi["paths"], {})

    def test_duplicate_route_warning(self):
        tools = make_tools()
        tools["greet_again"] = dict(tools["greet"])
        _, log = build(tools)
        self.assertIn(
            '[zeromcp] 2 tools registered the same route "GET /greet/:name" — only your own '
            "router's route matching, not this registry, decides which one runs",
            log,
        )

    def test_no_duplicate_warning_for_distinct_routes(self):
        _, log = build()
        self.assertNotIn("registered the same route", log)


class TestOpenApi(unittest.TestCase):
    def test_paths_from_routed_tools(self):
        registry, _ = build()
        self.assertEqual(sorted(registry.openapi["paths"]), ["/greet/{name}", "/items"])
        self.assertIn("get", registry.openapi["paths"]["/greet/{name}"])
        self.assertIn("post", registry.openapi["paths"]["/items"])

    def test_info_defaults(self):
        registry, _ = build()
        self.assertEqual(registry.openapi["info"], {"title": "ZeroMCP", "version": "1.0.0"})

    def test_info_overrides(self):
        registry, _ = build(title="My API", version="2.3.4")
        self.assertEqual(registry.openapi["info"], {"title": "My API", "version": "2.3.4"})

    def test_openapi_is_built_once(self):
        registry, _ = build()
        self.assertIs(registry.openapi, registry.openapi)

    def test_bad_input_schema_raises(self):
        with self.assertRaises(ValueError):
            build({"bad": {"description": "", "input": {"x": "integer"}, "execute": internal}})


class TestMcp(unittest.TestCase):
    def test_initialize_reports_version(self):
        registry, _ = build(version="9.9.9")
        res = mcp(registry, 1, "initialize")
        self.assertEqual(res["result"]["serverInfo"]["version"], "9.9.9")

    def test_initialize_default_version(self):
        registry, _ = build()
        self.assertEqual(mcp(registry, 1, "initialize")["result"]["serverInfo"]["version"], "1.0.0")

    def test_tools_list_includes_unrouted_tools(self):
        registry, _ = build()
        names = [t["name"] for t in mcp(registry, 1, "tools/list")["result"]["tools"]]
        self.assertEqual(names, ["greet", "internal", "create_item"])

    def test_tools_call_passes_env_from_get_env_each_call(self):
        calls = []

        def get_env():
            calls.append(1)
            return {"who": f"call{len(calls)}"}

        registry, _ = build(get_env=get_env)
        first = mcp(registry, 1, "tools/call", {"name": "greet", "arguments": {"name": "Ann"}})
        second = mcp(registry, 2, "tools/call", {"name": "greet", "arguments": {"name": "Bo"}})
        self.assertEqual(first["result"]["content"][0]["text"], "Hello, Ann! (call1)")
        self.assertEqual(second["result"]["content"][0]["text"], "Hello, Bo! (call2)")

    def test_default_env_is_empty_dict(self):
        registry, _ = build()
        res = mcp(registry, 1, "tools/call", {"name": "greet", "arguments": {"name": "Ann"}})
        self.assertEqual(res["result"]["content"][0]["text"], "Hello, Ann! (none)")

    def test_validation_uses_cached_schema(self):
        registry, _ = build()
        res = mcp(registry, 1, "tools/call", {"name": "greet", "arguments": {}})
        self.assertTrue(res["result"]["isError"])
        self.assertIn("Missing required field: name", res["result"]["content"][0]["text"])

    def test_custom_execute_timeout(self):
        async def slow(args, env):
            await asyncio.sleep(1)
            return "late"

        registry, _ = build({"slow": {"description": "", "input": {}, "execute": slow}}, execute_timeout=0.05)
        res = mcp(registry, 1, "tools/call", {"name": "slow", "arguments": {}})
        self.assertTrue(res["result"]["isError"])
        self.assertIn('Tool "slow" timed out after 0.05s', res["result"]["content"][0]["text"])


class TestRemote(unittest.TestCase):
    def test_remote_tools_in_mcp_not_routes_or_openapi(self):
        with FakeUpstream() as up:
            registry, _ = build(remote=[{"name": "probeo", "url": up.url, "tools": ["list_pages"]}])
            names = [t["name"] for t in mcp(registry, 1, "tools/list")["result"]["tools"]]
            called = mcp(registry, 2, "tools/call", {"name": "probeo.list_pages", "arguments": {"domain": "a.com"}})

        self.assertEqual(names, ["probeo.list_pages", "greet", "internal", "create_item"])
        self.assertEqual(json.loads(called["result"]["content"][0]["text"]), {"pages": [], "args": {"domain": "a.com"}})
        self.assertNotIn("probeo.list_pages", [r.name for r in registry.routes])
        self.assertEqual(sorted(registry.openapi["paths"]), ["/greet/{name}", "/items"])

    def test_local_tool_overrides_remote(self):
        async def local_list(args, env):
            return "local"

        with FakeUpstream() as up:
            registry, log = build(
                {"probeo.list_pages": {"description": "Local", "input": {}, "execute": local_list}},
                remote=[{"name": "probeo", "url": up.url}],
            )
            res = mcp(registry, 1, "tools/call", {"name": "probeo.list_pages", "arguments": {}})

        self.assertEqual(res["result"]["content"][0]["text"], "local")
        self.assertIn('[zeromcp] Local tool "probeo.list_pages" overrides remote', log)


if __name__ == "__main__":
    unittest.main()
