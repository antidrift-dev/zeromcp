"""Tests for PromptScanner: load prompts, parse arguments, render."""

import unittest
from pathlib import Path

from zeromcp.scanner import PromptScanner

FIXTURES_DIR = str(Path(__file__).parent / "fixtures" / "prompts")


class TestPromptScanning(unittest.TestCase):
    def setUp(self):
        self.scanner = PromptScanner({"prompts": FIXTURES_DIR})
        self.scanner.scan()

    def test_loads_greeting_prompt(self):
        self.assertIn("greeting", self.scanner.prompts)

    def test_loads_simple_prompt(self):
        self.assertIn("simple", self.scanner.prompts)

    def test_greeting_has_description(self):
        prompt = self.scanner.prompts["greeting"]
        self.assertEqual(prompt["description"], "Generate a greeting")

    def test_simple_has_description(self):
        prompt = self.scanner.prompts["simple"]
        self.assertEqual(prompt["description"], "A simple prompt")


class TestPromptArguments(unittest.TestCase):
    def setUp(self):
        self.scanner = PromptScanner({"prompts": FIXTURES_DIR})
        self.scanner.scan()

    def test_greeting_has_arguments(self):
        prompt = self.scanner.prompts["greeting"]
        args = prompt["arguments"]
        self.assertIsNotNone(args)
        self.assertEqual(len(args), 2)

    def test_greeting_name_required(self):
        prompt = self.scanner.prompts["greeting"]
        name_arg = next(a for a in prompt["arguments"] if a["name"] == "name")
        self.assertTrue(name_arg["required"])

    def test_greeting_style_optional(self):
        prompt = self.scanner.prompts["greeting"]
        style_arg = next(a for a in prompt["arguments"] if a["name"] == "style")
        self.assertFalse(style_arg["required"])
        self.assertEqual(style_arg["description"], "Greeting style")

    def test_simple_has_no_arguments(self):
        prompt = self.scanner.prompts["simple"]
        self.assertIsNone(prompt["arguments"])


class TestPromptRender(unittest.TestCase):
    def setUp(self):
        self.scanner = PromptScanner({"prompts": FIXTURES_DIR})
        self.scanner.scan()

    def test_render_greeting(self):
        prompt = self.scanner.prompts["greeting"]
        messages = prompt["render"]({"name": "Alice", "style": "casual"})
        self.assertEqual(len(messages), 1)
        self.assertEqual(messages[0]["role"], "user")
        text = messages[0]["content"]["text"]
        self.assertIn("Alice", text)
        self.assertIn("casual", text)

    def test_render_greeting_default_style(self):
        prompt = self.scanner.prompts["greeting"]
        messages = prompt["render"]({"name": "Bob"})
        text = messages[0]["content"]["text"]
        self.assertIn("Bob", text)
        self.assertIn("formal", text)

    def test_render_simple(self):
        prompt = self.scanner.prompts["simple"]
        messages = prompt["render"]({})
        self.assertEqual(len(messages), 1)
        self.assertEqual(messages[0]["content"]["text"], "Hello!")


class TestPromptScannerEmptyDir(unittest.TestCase):
    def test_nonexistent_dir_no_crash(self):
        scanner = PromptScanner({"prompts": "/nonexistent/path"})
        scanner.scan()
        self.assertEqual(len(scanner.prompts), 0)

    def test_no_prompts_config(self):
        scanner = PromptScanner({})
        scanner.scan()
        self.assertEqual(len(scanner.prompts), 0)


if __name__ == "__main__":
    unittest.main()
