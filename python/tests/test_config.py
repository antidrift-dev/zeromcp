"""Tests for config: resolve_sources, resolve_icon, resolve_transports, resolve_tool_sources."""

import base64
import json
import os
import tempfile
import unittest
from pathlib import Path

from zeromcp.config import (
    load_config,
    resolve_icon,
    resolve_sources,
    resolve_tool_sources,
    resolve_transports,
)


class TestResolveSources(unittest.TestCase):
    def test_none_returns_empty(self):
        self.assertEqual(resolve_sources(None), [])

    def test_string_returns_single_path(self):
        result = resolve_sources("./resources")
        self.assertEqual(result, [{"path": "./resources"}])

    def test_list_of_strings(self):
        result = resolve_sources(["./a", "./b"])
        self.assertEqual(result, [{"path": "./a"}, {"path": "./b"}])

    def test_list_of_dicts_passthrough(self):
        src = [{"path": "./a", "prefix": "x"}]
        result = resolve_sources(src)
        self.assertEqual(result, src)

    def test_mixed_list(self):
        result = resolve_sources(["./a", {"path": "./b", "prefix": "y"}])
        self.assertEqual(result, [{"path": "./a"}, {"path": "./b", "prefix": "y"}])


class TestResolveToolSources(unittest.TestCase):
    def test_none_defaults_to_tools_dir(self):
        result = resolve_tool_sources(None)
        self.assertEqual(result, [{"path": "./tools"}])

    def test_string(self):
        result = resolve_tool_sources("./my-tools")
        self.assertEqual(result, [{"path": "./my-tools"}])

    def test_list_of_strings(self):
        result = resolve_tool_sources(["./a", "./b"])
        self.assertEqual(result, [{"path": "./a"}, {"path": "./b"}])

    def test_list_of_dicts(self):
        src = [{"path": "./x", "prefix": "p"}]
        result = resolve_tool_sources(src)
        self.assertEqual(result, src)


class TestResolveTransports(unittest.TestCase):
    def test_no_transport_defaults_stdio(self):
        result = resolve_transports({})
        self.assertEqual(result, [{"type": "stdio"}])

    def test_single_transport(self):
        result = resolve_transports({"transport": {"type": "sse", "port": 8080}})
        self.assertEqual(result, [{"type": "sse", "port": 8080}])

    def test_list_of_transports(self):
        transports = [{"type": "stdio"}, {"type": "sse"}]
        result = resolve_transports({"transport": transports})
        self.assertEqual(result, transports)


class TestResolveIcon(unittest.TestCase):
    def test_none_returns_none(self):
        self.assertIsNone(resolve_icon(None))

    def test_empty_string_returns_none(self):
        self.assertIsNone(resolve_icon(""))

    def test_data_uri_passthrough(self):
        data_uri = "data:image/png;base64,iVBORw0KGgo="
        self.assertEqual(resolve_icon(data_uri), data_uri)

    def test_file_path_reads_and_encodes(self):
        with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as f:
            f.write(b"\x89PNG\r\n\x1a\n")
            f.flush()
            try:
                result = resolve_icon(f.name)
                self.assertIsNotNone(result)
                self.assertTrue(result.startswith("data:image/png;base64,"))
                # Decode the base64 part and verify
                b64_part = result.split(",", 1)[1]
                decoded = base64.b64decode(b64_part)
                self.assertEqual(decoded, b"\x89PNG\r\n\x1a\n")
            finally:
                os.unlink(f.name)

    def test_file_path_jpeg_mime(self):
        with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as f:
            f.write(b"\xff\xd8\xff")
            f.flush()
            try:
                result = resolve_icon(f.name)
                self.assertTrue(result.startswith("data:image/jpeg;base64,"))
            finally:
                os.unlink(f.name)

    def test_invalid_file_returns_none(self):
        result = resolve_icon("/nonexistent/icon.png")
        self.assertIsNone(result)

    def test_svg_mime(self):
        with tempfile.NamedTemporaryFile(suffix=".svg", delete=False) as f:
            f.write(b"<svg></svg>")
            f.flush()
            try:
                result = resolve_icon(f.name)
                self.assertTrue(result.startswith("data:image/svg+xml;base64,"))
            finally:
                os.unlink(f.name)


class TestLoadConfig(unittest.TestCase):
    def test_nonexistent_file_returns_empty(self):
        result = load_config("/nonexistent/zeromcp.config.json")
        self.assertEqual(result, {})

    def test_valid_json_file(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            json.dump({"tools": "./my-tools"}, f)
            f.flush()
            try:
                result = load_config(f.name)
                self.assertEqual(result, {"tools": "./my-tools"})
            finally:
                os.unlink(f.name)

    def test_invalid_json_raises(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            f.write("{bad json")
            f.flush()
            try:
                with self.assertRaises(RuntimeError):
                    load_config(f.name)
            finally:
                os.unlink(f.name)


if __name__ == "__main__":
    unittest.main()
