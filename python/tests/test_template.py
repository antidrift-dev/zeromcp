"""Tests for template matching."""

import unittest

from zeromcp.server import _match_template


class TestMatchTemplate(unittest.TestCase):
    def test_single_param(self):
        result = _match_template("resource:///users/{id}", "resource:///users/42")
        self.assertEqual(result, {"id": "42"})

    def test_multiple_params(self):
        result = _match_template(
            "resource:///users/{user_id}/posts/{post_id}",
            "resource:///users/5/posts/99",
        )
        self.assertEqual(result, {"user_id": "5", "post_id": "99"})

    def test_no_match_wrong_prefix(self):
        result = _match_template("resource:///users/{id}", "resource:///items/42")
        self.assertIsNone(result)

    def test_no_match_extra_segments(self):
        result = _match_template("resource:///users/{id}", "resource:///users/42/extra")
        self.assertIsNone(result)

    def test_no_match_missing_segment(self):
        result = _match_template("resource:///users/{id}/profile", "resource:///users/42")
        self.assertIsNone(result)

    def test_literal_only(self):
        result = _match_template("resource:///health", "resource:///health")
        self.assertEqual(result, {})

    def test_literal_no_match(self):
        result = _match_template("resource:///health", "resource:///status")
        self.assertIsNone(result)

    def test_empty_segment_no_match(self):
        # {id} matches [^/]+, so empty segment should not match
        result = _match_template("resource:///users/{id}", "resource:///users/")
        self.assertIsNone(result)

    def test_param_with_special_chars(self):
        result = _match_template("resource:///files/{name}", "resource:///files/my-file_v2")
        self.assertEqual(result, {"name": "my-file_v2"})

    def test_param_with_dots(self):
        result = _match_template("resource:///files/{name}", "resource:///files/doc.txt")
        self.assertEqual(result, {"name": "doc.txt"})


if __name__ == "__main__":
    unittest.main()
