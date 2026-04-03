"""Static analysis: scan tool files for unsafe patterns."""

from __future__ import annotations

import re
import sys
from pathlib import Path

from .config import resolve_tool_sources

# Patterns that indicate bypassing the sandbox
FORBIDDEN_PATTERNS = [
    {
        "regex": re.compile(r"(?<!ctx\.)(?<!\w)requests\.\w+\s*\("),
        "pattern": "requests.*(",
        "message": "Use ctx.fetch instead of requests library",
    },
    {
        "regex": re.compile(r"(?<!ctx\.)(?<!\w)urllib\.request\.\w+\s*\("),
        "pattern": "urllib.request.*()",
        "message": "Use ctx.fetch instead of urllib.request directly",
    },
    {
        "regex": re.compile(r"(?<!ctx\.)(?<!\w)urlopen\s*\("),
        "pattern": "urlopen(",
        "message": "Use ctx.fetch instead of urlopen directly",
    },
    {
        "regex": re.compile(r"\bopen\s*\("),
        "pattern": "open(",
        "message": "Filesystem access requires fs permission -- avoid raw open()",
    },
    {
        "regex": re.compile(r"\bsubprocess\.\w+\s*\("),
        "pattern": "subprocess.*()",
        "message": "Exec access requires exec permission -- avoid subprocess directly",
    },
    {
        "regex": re.compile(r"\bimport\s+subprocess\b"),
        "pattern": "import subprocess",
        "message": "Exec access requires exec permission -- avoid subprocess",
    },
    {
        "regex": re.compile(r"\bfrom\s+subprocess\s+import\b"),
        "pattern": "from subprocess import",
        "message": "Exec access requires exec permission -- avoid subprocess",
    },
    {
        "regex": re.compile(r"\bos\.system\s*\("),
        "pattern": "os.system(",
        "message": "Exec access requires exec permission -- avoid os.system",
    },
    {
        "regex": re.compile(r"\bos\.popen\s*\("),
        "pattern": "os.popen(",
        "message": "Exec access requires exec permission -- avoid os.popen",
    },
    {
        "regex": re.compile(r"\bos\.environ\b"),
        "pattern": "os.environ",
        "message": "Use ctx.credentials for secrets -- not os.environ directly",
    },
]


def audit_file(file_path: str, content: str) -> list[dict]:
    """Audit a single file's content. Returns list of violations."""
    violations = []
    lines = content.split("\n")

    for i, line in enumerate(lines):
        for pat in FORBIDDEN_PATTERNS:
            if pat["regex"].search(line):
                violations.append({
                    "file": file_path,
                    "line": i + 1,
                    "pattern": pat["pattern"],
                    "message": pat["message"],
                })

    return violations


def audit_tools(tools=None) -> list[dict]:
    """Audit all tool files in the configured sources."""
    violations: list[dict] = []
    sources = resolve_tool_sources(tools)

    for source in sources:
        root_dir = Path(source["path"]).resolve()
        _scan_dir(root_dir, root_dir, violations)

    return violations


def _scan_dir(directory: Path, root_dir: Path, violations: list[dict]) -> None:
    try:
        entries = sorted(directory.iterdir())
    except OSError:
        return

    for entry in entries:
        if entry.is_dir():
            _scan_dir(entry, root_dir, violations)
        elif entry.is_file() and entry.suffix == ".py":
            content = entry.read_text(encoding="utf-8")
            rel = str(entry.relative_to(root_dir))
            violations.extend(audit_file(rel, content))


def format_audit_results(violations: list[dict]) -> str:
    """Format audit results for display."""
    if not violations:
        return "[zeromcp] Audit passed -- all tools use ctx for sandboxed access"

    lines = [f"[zeromcp] Audit found {len(violations)} violation(s):\n"]
    for v in violations:
        lines.append(f"  x {v['file']}:{v['line']} -- {v['pattern']}")
        lines.append(f"    {v['message']}\n")
    return "\n".join(lines)
