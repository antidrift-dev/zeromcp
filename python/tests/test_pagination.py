"""Tests for pagination: encode/decode cursor and paginate."""

import base64
import unittest

from zeromcp.server import _decode_cursor, _encode_cursor, _paginate


class TestEncodeCursor(unittest.TestCase):
    def test_encodes_offset_zero(self):
        cursor = _encode_cursor(0)
        self.assertEqual(base64.b64decode(cursor).decode(), "0")

    def test_encodes_positive_offset(self):
        cursor = _encode_cursor(10)
        self.assertEqual(base64.b64decode(cursor).decode(), "10")

    def test_roundtrip(self):
        for offset in [0, 1, 5, 100, 9999]:
            self.assertEqual(_decode_cursor(_encode_cursor(offset)), offset)


class TestDecodeCursor(unittest.TestCase):
    def test_decodes_valid_cursor(self):
        cursor = base64.b64encode(b"5").decode("ascii")
        self.assertEqual(_decode_cursor(cursor), 5)

    def test_invalid_base64_returns_zero(self):
        self.assertEqual(_decode_cursor("!!!not-base64!!!"), 0)

    def test_non_numeric_returns_zero(self):
        cursor = base64.b64encode(b"abc").decode("ascii")
        self.assertEqual(_decode_cursor(cursor), 0)

    def test_negative_offset_clamped_to_zero(self):
        cursor = base64.b64encode(b"-5").decode("ascii")
        self.assertEqual(_decode_cursor(cursor), 0)

    def test_empty_string_returns_zero(self):
        self.assertEqual(_decode_cursor(""), 0)


class TestPaginate(unittest.TestCase):
    def test_no_pagination_when_page_size_zero(self):
        items = [1, 2, 3, 4, 5]
        page, next_cursor = _paginate(items, None, 0)
        self.assertEqual(page, items)
        self.assertIsNone(next_cursor)

    def test_no_pagination_when_page_size_negative(self):
        items = [1, 2, 3]
        page, next_cursor = _paginate(items, None, -1)
        self.assertEqual(page, items)
        self.assertIsNone(next_cursor)

    def test_first_page(self):
        items = list(range(10))
        page, next_cursor = _paginate(items, None, 3)
        self.assertEqual(page, [0, 1, 2])
        self.assertIsNotNone(next_cursor)

    def test_second_page(self):
        items = list(range(10))
        _, cursor = _paginate(items, None, 3)
        page, next_cursor = _paginate(items, cursor, 3)
        self.assertEqual(page, [3, 4, 5])
        self.assertIsNotNone(next_cursor)

    def test_last_page(self):
        items = list(range(5))
        # First page: [0,1,2], second page: [3,4]
        _, cursor = _paginate(items, None, 3)
        page, next_cursor = _paginate(items, cursor, 3)
        self.assertEqual(page, [3, 4])
        self.assertIsNone(next_cursor)

    def test_exact_page_boundary(self):
        items = list(range(6))
        _, cursor = _paginate(items, None, 3)
        page, next_cursor = _paginate(items, cursor, 3)
        self.assertEqual(page, [3, 4, 5])
        self.assertIsNone(next_cursor)

    def test_empty_list(self):
        page, next_cursor = _paginate([], None, 5)
        self.assertEqual(page, [])
        self.assertIsNone(next_cursor)

    def test_page_size_larger_than_list(self):
        items = [1, 2]
        page, next_cursor = _paginate(items, None, 100)
        self.assertEqual(page, [1, 2])
        self.assertIsNone(next_cursor)

    def test_cursor_past_end(self):
        items = [1, 2, 3]
        cursor = _encode_cursor(100)
        page, next_cursor = _paginate(items, cursor, 2)
        self.assertEqual(page, [])
        self.assertIsNone(next_cursor)

    def test_single_item_pages(self):
        items = ["a", "b", "c"]
        page1, c1 = _paginate(items, None, 1)
        self.assertEqual(page1, ["a"])
        page2, c2 = _paginate(items, c1, 1)
        self.assertEqual(page2, ["b"])
        page3, c3 = _paginate(items, c2, 1)
        self.assertEqual(page3, ["c"])
        self.assertIsNone(c3)

    def test_full_traversal(self):
        items = list(range(7))
        all_items = []
        cursor = None
        while True:
            page, cursor = _paginate(items, cursor, 3)
            all_items.extend(page)
            if cursor is None:
                break
        self.assertEqual(all_items, items)


if __name__ == "__main__":
    unittest.main()
