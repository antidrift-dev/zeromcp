"""Scan directories for .py tool files, load tools with execute + tool dict."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

from .config import resolve_credentials, resolve_tool_sources
from .sandbox import create_sandbox, validate_permissions


class ToolScanner:
    def __init__(self, config: dict | None = None):
        config = config or {}
        self.tools: dict = {}
        self.sources = resolve_tool_sources(config.get("tools"))
        self.separator = config.get("separator", "_")
        self.namespacing: dict = config.get("namespacing", {})
        self.credential_sources: dict = config.get("credentials", {})
        self.credential_cache: dict = {}
        self.logging: bool = config.get("logging", False)
        self.bypass: bool = config.get("bypass_permissions", False)

    def scan(self) -> dict:
        """Scan all tool sources and return a dict of name -> ToolDefinition."""
        self.tools.clear()
        for source in self.sources:
            root_dir = Path(source["path"]).resolve()
            self._scan_dir(root_dir, root_dir, source.get("prefix"))
        return self.tools

    def _scan_dir(self, directory: Path, root_dir: Path, source_prefix: str | None) -> None:
        try:
            entries = sorted(directory.iterdir())
        except OSError:
            _log(f"Cannot read tools directory: {directory}")
            return

        for entry in entries:
            if entry.is_dir():
                self._scan_dir(entry, root_dir, source_prefix)
            elif entry.is_file() and entry.suffix == ".py":
                self._load_tool(entry, root_dir, source_prefix)

    def _build_name(self, file_path: Path, root_dir: Path, source_prefix: str | None) -> str:
        rel = file_path.relative_to(root_dir)
        parts = list(rel.parts)
        filename = parts.pop()
        stem = Path(filename).stem

        # Build inner name (directory-based namespacing)
        inner_name = stem
        if parts:
            dir_name = parts[0]
            override = self.namespacing.get(dir_name, {})
            dir_prefix = override.get("prefix", dir_name)
            if dir_prefix is not None and dir_prefix != "":
                inner_name = f"{dir_prefix}{self.separator}{stem}"

        # Apply source-level prefix
        if source_prefix:
            return f"{source_prefix}{self.separator}{inner_name}"
        return inner_name

    def _get_credentials(self, file_path: Path, root_dir: Path):
        rel = file_path.relative_to(root_dir)
        parts = list(rel.parts)
        if len(parts) < 2:
            return None

        dir_name = parts[0]
        if dir_name in self.credential_cache:
            return self.credential_cache[dir_name]

        source = self.credential_sources.get(dir_name)
        if not source:
            return None

        creds = resolve_credentials(source)
        self.credential_cache[dir_name] = creds
        return creds

    def _load_tool(self, file_path: Path, root_dir: Path, source_prefix: str | None) -> None:
        try:
            mod = _import_file(file_path)
        except Exception as exc:
            rel = file_path.relative_to(root_dir)
            _log(f"Error loading {rel}: {exc}")
            return

        # Check for required exports
        tool_meta = getattr(mod, "tool", None)
        execute_fn = getattr(mod, "execute", None)

        if not tool_meta or not callable(execute_fn):
            return

        name = self._build_name(file_path, root_dir, source_prefix)
        permissions = tool_meta.get("permissions")
        validate_permissions(name, permissions)

        credentials = self._get_credentials(file_path, root_dir)
        sandbox_opts = {"logging": self.logging, "bypass": self.bypass}
        sandbox = create_sandbox(name, permissions, sandbox_opts)

        ctx = _ToolContext(credentials=credentials, fetch=sandbox["fetch"])

        # Wrap execute to inject ctx
        raw_execute = execute_fn

        async def wrapped_execute(args: dict, _ctx=ctx):
            return await raw_execute(args, _ctx)

        self.tools[name] = {
            "description": tool_meta.get("description", ""),
            "input": tool_meta.get("input", {}),
            "execute": wrapped_execute,
        }

        _log(f"Loaded: {name}")


class _ToolContext:
    """Context object passed to tool execute functions."""

    def __init__(self, credentials=None, fetch=None):
        self.credentials = credentials
        self.fetch = fetch


def _import_file(file_path: Path):
    """Dynamically import a Python file as a module."""
    spec = importlib.util.spec_from_file_location(
        f"zeromcp_tool_{file_path.stem}_{id(file_path)}",
        str(file_path),
    )
    if spec is None or spec.loader is None:
        raise ImportError(f"Cannot create module spec for {file_path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _log(msg: str) -> None:
    print(f"[zeromcp] {msg}", file=sys.stderr)
