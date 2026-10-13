"""The built-in HTTP transport is gone: an http transport in config fails at startup."""

import asyncio
import contextlib
import io
import unittest

from zeromcp import serve


def _serve_and_capture(config: dict) -> tuple[SystemExit, str]:
    stderr = io.StringIO()
    with contextlib.redirect_stderr(stderr):
        try:
            asyncio.run(serve(config))
        except SystemExit as exc:
            return exc, stderr.getvalue()
    raise AssertionError("serve() did not exit")


class TestHttpTransportRemoved(unittest.TestCase):
    def test_http_transport_exits_with_error(self):
        exc, err = _serve_and_capture({"transport": {"type": "http", "port": 1}})
        self.assertEqual(exc.code, 1)
        self.assertIn("create_registry", err)
        self.assertIn("create_handler", err)

    def test_http_in_list_rejects_whole_config(self):
        exc, err = _serve_and_capture({"transport": [{"type": "stdio"}, {"type": "http"}]})
        self.assertEqual(exc.code, 1)
        self.assertIn("create_registry", err)
        self.assertNotIn("stdio transport ready", err)


if __name__ == "__main__":
    unittest.main()
