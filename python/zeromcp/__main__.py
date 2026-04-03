"""CLI entry point: python -m zeromcp serve ./tools | python -m zeromcp audit ./tools"""

from __future__ import annotations

import asyncio
import json
import sys
from pathlib import Path


def main() -> None:
    args = sys.argv[1:]

    if not args or args[0] not in ("serve", "audit"):
        print("Usage:", file=sys.stderr)
        print("  zeromcp serve [tools-directory...] [--config <path>]", file=sys.stderr)
        print("  zeromcp audit [tools-directory...]", file=sys.stderr)
        sys.exit(1)

    command = args[0]

    # Parse --config flag
    config_path = None
    if "--config" in args:
        idx = args.index("--config")
        if idx + 1 < len(args):
            config_path = str(Path(args[idx + 1]).resolve())

    # Auto-detect zeromcp.config.json
    if not config_path:
        auto_path = Path.cwd() / "zeromcp.config.json"
        if auto_path.exists():
            config_path = str(auto_path)

    # Load config
    config: dict = {}
    if config_path:
        config = json.loads(Path(config_path).read_text(encoding="utf-8"))

    # Collect positional args (skip flags and their values)
    skip_next = False
    positional = []
    for i, a in enumerate(args[1:], start=1):
        if skip_next:
            skip_next = False
            continue
        if a == "--config":
            skip_next = True
            continue
        if a.startswith("--"):
            continue
        positional.append(a)

    # CLI tool directories override config
    if positional:
        config["tools"] = [str(Path(d).resolve()) for d in positional]

    if command == "audit":
        from .audit import audit_tools, format_audit_results

        violations = audit_tools(config.get("tools", "./tools"))
        print(format_audit_results(violations), file=sys.stderr)
        sys.exit(1 if violations else 0)

    if command == "serve":
        from .server import serve

        asyncio.run(serve(config))


if __name__ == "__main__":
    main()
