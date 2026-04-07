"""Tests for ResourceScanner: static files, dynamic resources, templates, MIME detection."""

import unittest
from pathlib import Path

from zeromcp.scanner import MIME_MAP, ResourceScanner

FIXTURES_DIR = str(Path(__file__).parent / "fixtures" / "resources")


class TestResourceScanning(unittest.TestCase):
    def setUp(self):
        self.scanner = ResourceScanner({"resources": FIXTURES_DIR})
        self.scanner.scan()

    def test_static_json_loaded(self):
        self.assertIn("config", self.scanner.resources)
        res = self.scanner.resources["config"]
        self.assertEqual(res["mime_type"], "application/json")
        self.assertEqual(res["uri"], "resource:///config.json")

    def test_static_markdown_loaded(self):
        self.assertIn("readme", self.scanner.resources)
        res = self.scanner.resources["readme"]
        self.assertEqual(res["mime_type"], "text/markdown")

    def test_static_txt_loaded(self):
        self.assertIn("data", self.scanner.resources)
        res = self.scanner.resources["data"]
        self.assertEqual(res["mime_type"], "text/plain")

    def test_dynamic_resource_loaded(self):
        self.assertIn("dynamic", self.scanner.resources)
        res = self.scanner.resources["dynamic"]
        self.assertEqual(res["uri"], "resource:///dynamic-data")
        self.assertEqual(res["mime_type"], "application/json")
        self.assertEqual(res["description"], "Dynamic test resource")

    def test_template_loaded(self):
        self.assertIn("user_profile", self.scanner.templates)
        tmpl = self.scanner.templates["user_profile"]
        self.assertEqual(tmpl["uri_template"], "resource:///users/{user_id}/profile")
        self.assertEqual(tmpl["mime_type"], "application/json")

    def test_static_resource_has_description(self):
        res = self.scanner.resources["config"]
        self.assertIn("Static resource", res["description"])

    def test_template_not_in_resources(self):
        # Templates should not appear in the resources dict
        self.assertNotIn("user_profile", self.scanner.resources)

    def test_dynamic_not_in_templates(self):
        # Dynamic resources (no uri_template) should not appear in templates
        self.assertNotIn("dynamic", self.scanner.templates)


class TestStaticResourceRead(unittest.TestCase):
    def setUp(self):
        self.scanner = ResourceScanner({"resources": FIXTURES_DIR})
        self.scanner.scan()

    def test_read_static_json(self):
        import asyncio
        res = self.scanner.resources["config"]
        text = asyncio.run(res["read"]())
        self.assertIn('"version"', text)
        self.assertIn('"1.0"', text)

    def test_read_static_txt(self):
        import asyncio
        res = self.scanner.resources["data"]
        text = asyncio.run(res["read"]())
        self.assertEqual(text.strip(), "plain text content")


class TestDynamicResourceRead(unittest.TestCase):
    def setUp(self):
        self.scanner = ResourceScanner({"resources": FIXTURES_DIR})
        self.scanner.scan()

    def test_read_dynamic_resource(self):
        res = self.scanner.resources["dynamic"]
        # Dynamic read is sync, but the server calls it via _call_read
        result = res["read"]()
        self.assertEqual(result, '{"status": "ok"}')

    def test_read_template_with_params(self):
        tmpl = self.scanner.templates["user_profile"]
        result = tmpl["read"]({"user_id": "42"})
        self.assertIn('"user_id": "42"', result)
        self.assertIn('"name": "User 42"', result)


class TestMimeMap(unittest.TestCase):
    def test_known_extensions(self):
        self.assertEqual(MIME_MAP[".json"], "application/json")
        self.assertEqual(MIME_MAP[".md"], "text/markdown")
        self.assertEqual(MIME_MAP[".txt"], "text/plain")
        self.assertEqual(MIME_MAP[".html"], "text/html")
        self.assertEqual(MIME_MAP[".yaml"], "text/yaml")
        self.assertEqual(MIME_MAP[".yml"], "text/yaml")
        self.assertEqual(MIME_MAP[".csv"], "text/csv")
        self.assertEqual(MIME_MAP[".js"], "application/javascript")

    def test_py_not_in_mime_map(self):
        # .py files are treated as dynamic resources, not static
        self.assertNotIn(".py", MIME_MAP)


class TestResourceScannerEmptyDir(unittest.TestCase):
    def test_nonexistent_dir_no_crash(self):
        scanner = ResourceScanner({"resources": "/nonexistent/path"})
        scanner.scan()
        self.assertEqual(len(scanner.resources), 0)
        self.assertEqual(len(scanner.templates), 0)

    def test_no_resources_config(self):
        scanner = ResourceScanner({})
        scanner.scan()
        self.assertEqual(len(scanner.resources), 0)


if __name__ == "__main__":
    unittest.main()
