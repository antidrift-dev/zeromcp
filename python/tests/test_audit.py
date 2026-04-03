"""Tests for the audit module."""

import unittest

from zeromcp.audit import audit_file, format_audit_results


class TestAuditFile(unittest.TestCase):
    def test_clean_file_passes(self):
        content = '''
tool = {"description": "test", "input": {"name": "string"}}

async def execute(args, ctx):
    result = await ctx.fetch("https://api.example.com/data")
    return result["body"]
'''
        violations = audit_file("clean.py", content)
        self.assertEqual(len(violations), 0)

    def test_detects_raw_requests(self):
        content = 'response = requests.get("https://example.com")'
        violations = audit_file("bad.py", content)
        self.assertTrue(any("requests" in v["pattern"] for v in violations))

    def test_detects_subprocess(self):
        content = "import subprocess\nsubprocess.run(['ls'])"
        violations = audit_file("bad.py", content)
        self.assertTrue(len(violations) >= 1)

    def test_detects_os_environ(self):
        content = 'secret = os.environ["API_KEY"]'
        violations = audit_file("bad.py", content)
        self.assertTrue(any("os.environ" in v["pattern"] for v in violations))

    def test_detects_open(self):
        content = 'f = open("/etc/passwd", "r")'
        violations = audit_file("bad.py", content)
        self.assertTrue(any("open(" in v["pattern"] for v in violations))


class TestFormatResults(unittest.TestCase):
    def test_no_violations(self):
        result = format_audit_results([])
        self.assertIn("Audit passed", result)

    def test_with_violations(self):
        violations = [{"file": "bad.py", "line": 1, "pattern": "open(", "message": "bad"}]
        result = format_audit_results(violations)
        self.assertIn("1 violation", result)


if __name__ == "__main__":
    unittest.main()
