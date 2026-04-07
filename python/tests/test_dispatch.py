"""Tests for server request dispatch: resources, prompts, logging, pagination."""

import asyncio
import unittest

from zeromcp.server import _handle_request


def _make_state(
    tools=None,
    resources=None,
    templates=None,
    prompts=None,
    page_size=0,
    icon=None,
):
    """Build a minimal state dict for testing dispatch."""
    return {
        "tools": tools or {},
        "resources": resources or {},
        "templates": templates or {},
        "prompts": prompts or {},
        "subscriptions": set(),
        "execute_timeout": 30,
        "page_size": page_size,
        "log_level": "info",
        "icon": icon,
    }


class TestInitialize(unittest.TestCase):
    def test_initialize_returns_capabilities(self):
        state = _make_state()
        req = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}
        resp = asyncio.run(_handle_request(req, state))
        self.assertEqual(resp["id"], 1)
        result = resp["result"]
        self.assertEqual(result["protocolVersion"], "2024-11-05")
        self.assertIn("tools", result["capabilities"])
        self.assertIn("logging", result["capabilities"])

    def test_initialize_includes_resources_capability_when_present(self):
        resources = {"r": {"uri": "resource:///r", "name": "r", "mime_type": "text/plain"}}
        state = _make_state(resources=resources)
        req = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}
        resp = asyncio.run(_handle_request(req, state))
        self.assertIn("resources", resp["result"]["capabilities"])

    def test_initialize_includes_prompts_capability_when_present(self):
        prompts = {"p": {"name": "p", "render": lambda a: []}}
        state = _make_state(prompts=prompts)
        req = {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}}
        resp = asyncio.run(_handle_request(req, state))
        self.assertIn("prompts", resp["result"]["capabilities"])


class TestNotifications(unittest.TestCase):
    def test_initialized_notification_returns_none(self):
        state = _make_state()
        req = {"jsonrpc": "2.0", "method": "notifications/initialized"}
        resp = asyncio.run(_handle_request(req, state))
        self.assertIsNone(resp)

    def test_roots_list_changed_returns_none(self):
        state = _make_state()
        req = {"jsonrpc": "2.0", "method": "notifications/roots/list_changed"}
        resp = asyncio.run(_handle_request(req, state))
        self.assertIsNone(resp)


class TestResourcesList(unittest.TestCase):
    def test_list_resources(self):
        resources = {
            "config": {
                "uri": "resource:///config.json",
                "name": "config",
                "description": "Config file",
                "mime_type": "application/json",
            },
        }
        state = _make_state(resources=resources)
        req = {"jsonrpc": "2.0", "id": 1, "method": "resources/list", "params": {}}
        resp = asyncio.run(_handle_request(req, state))
        items = resp["result"]["resources"]
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["uri"], "resource:///config.json")
        self.assertEqual(items[0]["mimeType"], "application/json")

    def test_list_resources_empty(self):
        state = _make_state()
        req = {"jsonrpc": "2.0", "id": 1, "method": "resources/list", "params": {}}
        resp = asyncio.run(_handle_request(req, state))
        self.assertEqual(resp["result"]["resources"], [])

    def test_list_resources_with_icon(self):
        resources = {
            "r": {"uri": "resource:///r", "name": "r", "description": "d", "mime_type": "text/plain"},
        }
        state = _make_state(resources=resources, icon="data:image/png;base64,abc")
        req = {"jsonrpc": "2.0", "id": 1, "method": "resources/list", "params": {}}
        resp = asyncio.run(_handle_request(req, state))
        self.assertIn("icons", resp["result"]["resources"][0])


class TestResourcesRead(unittest.TestCase):
    def test_read_static_resource(self):
        async def read_fn():
            return "hello"

        resources = {
            "r": {"uri": "resource:///r", "name": "r", "mime_type": "text/plain", "read": read_fn},
        }
        state = _make_state(resources=resources)
        req = {"jsonrpc": "2.0", "id": 1, "method": "resources/read", "params": {"uri": "resource:///r"}}
        resp = asyncio.run(_handle_request(req, state))
        contents = resp["result"]["contents"]
        self.assertEqual(len(contents), 1)
        self.assertEqual(contents[0]["text"], "hello")
        self.assertEqual(contents[0]["mimeType"], "text/plain")

    def test_read_resource_not_found(self):
        state = _make_state()
        req = {"jsonrpc": "2.0", "id": 1, "method": "resources/read", "params": {"uri": "resource:///nope"}}
        resp = asyncio.run(_handle_request(req, state))
        self.assertIn("error", resp)
        self.assertEqual(resp["error"]["code"], -32002)

    def test_read_template_resource(self):
        def read_fn(params):
            return f"user {params['id']}"

        templates = {
            "user": {
                "uri_template": "resource:///users/{id}",
                "name": "user",
                "mime_type": "application/json",
                "read": read_fn,
            },
        }
        state = _make_state(templates=templates)
        req = {"jsonrpc": "2.0", "id": 1, "method": "resources/read", "params": {"uri": "resource:///users/42"}}
        resp = asyncio.run(_handle_request(req, state))
        self.assertEqual(resp["result"]["contents"][0]["text"], "user 42")

    def test_read_resource_error(self):
        async def bad_read():
            raise RuntimeError("oops")

        resources = {
            "r": {"uri": "resource:///r", "name": "r", "mime_type": "text/plain", "read": bad_read},
        }
        state = _make_state(resources=resources)
        req = {"jsonrpc": "2.0", "id": 1, "method": "resources/read", "params": {"uri": "resource:///r"}}
        resp = asyncio.run(_handle_request(req, state))
        self.assertIn("error", resp)
        self.assertEqual(resp["error"]["code"], -32603)


class TestResourcesSubscribe(unittest.TestCase):
    def test_subscribe(self):
        state = _make_state()
        req = {"jsonrpc": "2.0", "id": 1, "method": "resources/subscribe", "params": {"uri": "resource:///r"}}
        resp = asyncio.run(_handle_request(req, state))
        self.assertEqual(resp["result"], {})
        self.assertIn("resource:///r", state["subscriptions"])


class TestTemplatesList(unittest.TestCase):
    def test_list_templates(self):
        templates = {
            "user": {
                "uri_template": "resource:///users/{id}",
                "name": "user",
                "description": "User by ID",
                "mime_type": "application/json",
            },
        }
        state = _make_state(templates=templates)
        req = {"jsonrpc": "2.0", "id": 1, "method": "resources/templates/list", "params": {}}
        resp = asyncio.run(_handle_request(req, state))
        items = resp["result"]["resourceTemplates"]
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["uriTemplate"], "resource:///users/{id}")


class TestPromptsList(unittest.TestCase):
    def test_list_prompts(self):
        prompts = {
            "greeting": {
                "name": "greeting",
                "description": "Greet someone",
                "arguments": [{"name": "name", "required": True}],
                "render": lambda a: [],
            },
        }
        state = _make_state(prompts=prompts)
        req = {"jsonrpc": "2.0", "id": 1, "method": "prompts/list", "params": {}}
        resp = asyncio.run(_handle_request(req, state))
        items = resp["result"]["prompts"]
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["name"], "greeting")
        self.assertEqual(items[0]["description"], "Greet someone")
        self.assertIn("arguments", items[0])

    def test_list_prompts_no_description(self):
        prompts = {
            "p": {"name": "p", "description": None, "arguments": None, "render": lambda a: []},
        }
        state = _make_state(prompts=prompts)
        req = {"jsonrpc": "2.0", "id": 1, "method": "prompts/list", "params": {}}
        resp = asyncio.run(_handle_request(req, state))
        items = resp["result"]["prompts"]
        self.assertEqual(len(items), 1)
        self.assertNotIn("description", items[0])
        self.assertNotIn("arguments", items[0])


class TestPromptsGet(unittest.TestCase):
    def test_get_prompt(self):
        def render(args):
            return [{"role": "user", "content": {"type": "text", "text": f"Hi {args['name']}"}}]

        prompts = {
            "greeting": {"name": "greeting", "render": render},
        }
        state = _make_state(prompts=prompts)
        req = {
            "jsonrpc": "2.0", "id": 1, "method": "prompts/get",
            "params": {"name": "greeting", "arguments": {"name": "Alice"}},
        }
        resp = asyncio.run(_handle_request(req, state))
        messages = resp["result"]["messages"]
        self.assertEqual(len(messages), 1)
        self.assertIn("Alice", messages[0]["content"]["text"])

    def test_get_prompt_not_found(self):
        state = _make_state()
        req = {"jsonrpc": "2.0", "id": 1, "method": "prompts/get", "params": {"name": "nope"}}
        resp = asyncio.run(_handle_request(req, state))
        self.assertIn("error", resp)
        self.assertEqual(resp["error"]["code"], -32002)

    def test_get_prompt_render_error(self):
        def bad_render(args):
            raise ValueError("render failed")

        prompts = {"bad": {"name": "bad", "render": bad_render}}
        state = _make_state(prompts=prompts)
        req = {"jsonrpc": "2.0", "id": 1, "method": "prompts/get", "params": {"name": "bad"}}
        resp = asyncio.run(_handle_request(req, state))
        self.assertIn("error", resp)
        self.assertEqual(resp["error"]["code"], -32603)

    def test_get_prompt_async_render(self):
        async def async_render(args):
            return [{"role": "assistant", "content": {"type": "text", "text": "async!"}}]

        prompts = {"ap": {"name": "ap", "render": async_render}}
        state = _make_state(prompts=prompts)
        req = {"jsonrpc": "2.0", "id": 1, "method": "prompts/get", "params": {"name": "ap"}}
        resp = asyncio.run(_handle_request(req, state))
        self.assertEqual(resp["result"]["messages"][0]["content"]["text"], "async!")


class TestLoggingSetLevel(unittest.TestCase):
    def test_set_level(self):
        state = _make_state()
        self.assertEqual(state["log_level"], "info")
        req = {"jsonrpc": "2.0", "id": 1, "method": "logging/setLevel", "params": {"level": "debug"}}
        resp = asyncio.run(_handle_request(req, state))
        self.assertEqual(resp["result"], {})
        self.assertEqual(state["log_level"], "debug")

    def test_set_level_no_level_param(self):
        state = _make_state()
        req = {"jsonrpc": "2.0", "id": 1, "method": "logging/setLevel", "params": {}}
        resp = asyncio.run(_handle_request(req, state))
        self.assertEqual(resp["result"], {})
        self.assertEqual(state["log_level"], "info")  # unchanged


class TestToolsListPagination(unittest.TestCase):
    def _make_tools(self, count):
        tools = {}
        for i in range(count):
            name = f"tool_{i}"
            tools[name] = {
                "description": f"Tool {i}",
                "_cached_schema": {"type": "object", "properties": {}, "required": []},
                "execute": lambda args: "ok",
            }
        return tools

    def test_tools_list_no_pagination(self):
        tools = self._make_tools(3)
        state = _make_state(tools=tools)
        req = {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}
        resp = asyncio.run(_handle_request(req, state))
        self.assertEqual(len(resp["result"]["tools"]), 3)
        self.assertNotIn("nextCursor", resp["result"])

    def test_tools_list_with_pagination(self):
        tools = self._make_tools(5)
        state = _make_state(tools=tools, page_size=2)
        req = {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}
        resp = asyncio.run(_handle_request(req, state))
        self.assertEqual(len(resp["result"]["tools"]), 2)
        self.assertIn("nextCursor", resp["result"])

    def test_tools_list_pagination_full_traversal(self):
        tools = self._make_tools(5)
        state = _make_state(tools=tools, page_size=2)
        all_names = []
        cursor = None
        for _ in range(10):  # safety limit
            req = {"jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {}}
            if cursor:
                req["params"]["cursor"] = cursor
            resp = asyncio.run(_handle_request(req, state))
            for t in resp["result"]["tools"]:
                all_names.append(t["name"])
            cursor = resp["result"].get("nextCursor")
            if not cursor:
                break
        self.assertEqual(len(all_names), 5)


class TestUnknownMethod(unittest.TestCase):
    def test_unknown_method_error(self):
        state = _make_state()
        req = {"jsonrpc": "2.0", "id": 1, "method": "unknown/method", "params": {}}
        resp = asyncio.run(_handle_request(req, state))
        self.assertIn("error", resp)
        self.assertEqual(resp["error"]["code"], -32601)


class TestPing(unittest.TestCase):
    def test_ping(self):
        state = _make_state()
        req = {"jsonrpc": "2.0", "id": 1, "method": "ping", "params": {}}
        resp = asyncio.run(_handle_request(req, state))
        self.assertEqual(resp["result"], {})


class TestCompletionComplete(unittest.TestCase):
    def test_completion_returns_empty(self):
        state = _make_state()
        req = {"jsonrpc": "2.0", "id": 1, "method": "completion/complete", "params": {}}
        resp = asyncio.run(_handle_request(req, state))
        self.assertEqual(resp["result"]["completion"]["values"], [])


class TestNullParams(unittest.TestCase):
    def test_null_params_treated_as_empty(self):
        state = _make_state()
        req = {"jsonrpc": "2.0", "id": 1, "method": "ping", "params": None}
        resp = asyncio.run(_handle_request(req, state))
        self.assertEqual(resp["result"], {})


if __name__ == "__main__":
    unittest.main()
