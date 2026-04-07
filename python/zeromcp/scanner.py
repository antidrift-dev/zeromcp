"""Scan directories for .py tool files, load tools with execute + tool dict."""

from __future__ import annotations

import importlib.util
import sys
from pathlib import Path

from .config import resolve_credentials, resolve_sources, resolve_tool_sources
from .sandbox import create_sandbox, validate_permissions
from .schema import to_json_schema


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

        input_schema = tool_meta.get("input", {})
        self.tools[name] = {
            "description": tool_meta.get("description", ""),
            "input": input_schema,
            "_cached_schema": to_json_schema(input_schema),
            "permissions": tool_meta.get("permissions"),
            "execute": wrapped_execute,
        }

        _log(f"Loaded: {name}")


class _ToolContext:
    """Context object passed to tool execute functions."""

    def __init__(self, credentials=None, fetch=None):
        self.credentials = credentials
        self.fetch = fetch


MIME_MAP = {
    ".json": "application/json",
    ".txt": "text/plain",
    ".md": "text/markdown",
    ".html": "text/html",
    ".xml": "application/xml",
    ".yaml": "text/yaml",
    ".yml": "text/yaml",
    ".csv": "text/csv",
    ".css": "text/css",
    ".js": "application/javascript",
    ".ts": "text/typescript",
    ".sql": "text/plain",
    ".sh": "text/plain",
    ".rb": "text/plain",
    ".go": "text/plain",
    ".rs": "text/plain",
    ".toml": "text/plain",
    ".ini": "text/plain",
    ".env": "text/plain",
}


class ResourceScanner:
    """Scan directories for resource files.

    Static files (json, md, txt, etc.) are served as-is.
    .py files with a ``read()`` function are dynamic resources.
    .py files with a ``uri_template`` field are resource templates.
    """

    def __init__(self, config: dict | None = None):
        config = config or {}
        self.resources: dict = {}
        self.templates: dict = {}
        self.dirs = [Path(s["path"]).resolve() for s in resolve_sources(config.get("resources"))]
        self.separator: str = config.get("separator", "_")

    def scan(self) -> None:
        self.resources.clear()
        self.templates.clear()
        for d in self.dirs:
            self._scan_dir(d, d)

    def _scan_dir(self, base_dir: Path, current_dir: Path) -> None:
        try:
            entries = sorted(current_dir.iterdir())
        except OSError:
            return

        for entry in entries:
            if entry.is_dir():
                self._scan_dir(base_dir, entry)
            elif entry.is_file():
                rel = entry.relative_to(base_dir)
                name = rel.with_suffix("").as_posix().replace("/", self.separator)
                ext = entry.suffix.lower()

                if ext == ".py":
                    self._load_dynamic(entry, name)
                elif ext in MIME_MAP:
                    self._load_static(entry, rel.as_posix(), name, ext)

    def _load_dynamic(self, file_path: Path, name: str) -> None:
        try:
            mod = _import_file(file_path)
        except Exception as exc:
            _log(f"Error loading resource {file_path}: {exc}")
            return

        read_fn = getattr(mod, "read", None)
        if not callable(read_fn):
            return

        uri_template = getattr(mod, "uri_template", None)
        description = getattr(mod, "description", None)
        mime_type = getattr(mod, "mime_type", None)

        if uri_template:
            self.templates[name] = {
                "uri_template": uri_template,
                "name": name,
                "description": description,
                "mime_type": mime_type or "text/plain",
                "read": read_fn,
            }
        else:
            uri = getattr(mod, "uri", None) or f"resource:///{name}"
            self.resources[name] = {
                "uri": uri,
                "name": name,
                "description": description,
                "mime_type": mime_type or "application/json",
                "read": read_fn,
            }

    def _load_static(self, file_path: Path, rel_path: str, name: str, ext: str) -> None:
        uri = f"resource:///{rel_path}"
        mime_type = MIME_MAP.get(ext, "application/octet-stream")

        def make_reader(fp: Path):
            async def read_static():
                return fp.read_text(encoding="utf-8")
            return read_static

        self.resources[name] = {
            "uri": uri,
            "name": name,
            "description": f"Static resource: {rel_path}",
            "mime_type": mime_type,
            "read": make_reader(file_path),
        }


class PromptScanner:
    """Scan directories for prompt .py files.

    Each .py file must export a ``render(args)`` function.
    May also export ``description`` and ``arguments``.
    """

    def __init__(self, config: dict | None = None):
        config = config or {}
        self.prompts: dict = {}
        self.dirs = [Path(s["path"]).resolve() for s in resolve_sources(config.get("prompts"))]
        self.separator: str = config.get("separator", "_")

    def scan(self) -> None:
        self.prompts.clear()
        for d in self.dirs:
            self._scan_dir(d, d)

    def _scan_dir(self, base_dir: Path, current_dir: Path) -> None:
        try:
            entries = sorted(current_dir.iterdir())
        except OSError:
            return

        for entry in entries:
            if entry.is_dir():
                self._scan_dir(base_dir, entry)
            elif entry.is_file() and entry.suffix == ".py":
                rel = entry.relative_to(base_dir)
                name = rel.with_suffix("").as_posix().replace("/", self.separator)
                self._load_prompt(entry, name)

    def _load_prompt(self, file_path: Path, name: str) -> None:
        try:
            mod = _import_file(file_path)
        except Exception as exc:
            _log(f"Error loading prompt {file_path}: {exc}")
            return

        render_fn = getattr(mod, "render", None)
        if not callable(render_fn):
            _log(f"Prompt {file_path}: missing render() function")
            return

        description = getattr(mod, "description", None)
        raw_args = getattr(mod, "arguments", None)

        # Convert input schema shorthand to MCP prompt arguments
        prompt_args: list[dict] = []
        if raw_args and isinstance(raw_args, dict):
            for key, val in raw_args.items():
                if isinstance(val, str):
                    prompt_args.append({"name": key, "required": True})
                elif isinstance(val, dict):
                    arg: dict = {"name": key}
                    if "description" in val:
                        arg["description"] = val["description"]
                    arg["required"] = not val.get("optional", False)
                    prompt_args.append(arg)

        self.prompts[name] = {
            "name": name,
            "description": description,
            "arguments": prompt_args if prompt_args else None,
            "render": render_fn,
        }


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
