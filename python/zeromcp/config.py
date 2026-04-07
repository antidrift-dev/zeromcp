"""Load zeromcp.config.json, resolve credentials, transports."""

from __future__ import annotations

import json
import os
from pathlib import Path


def load_config(config_path: str) -> dict:
    """Load config from a JSON file. Returns empty dict if file not found."""
    path = Path(config_path)
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError) as exc:
        raise RuntimeError(f"Cannot parse config: {exc}") from exc


def resolve_tool_sources(tools=None) -> list[dict]:
    """Normalize the tools config into a list of {path, prefix?} dicts."""
    if tools is None:
        return [{"path": "./tools"}]
    if isinstance(tools, str):
        return [{"path": tools}]
    result = []
    for t in tools:
        if isinstance(t, str):
            result.append({"path": t})
        else:
            result.append(t)
    return result


def resolve_sources(raw) -> list[dict]:
    """Normalize a source config (string, list of strings/dicts) into [{path, ...}]."""
    if raw is None:
        return []
    if isinstance(raw, str):
        return [{"path": raw}]
    result = []
    for item in raw:
        if isinstance(item, str):
            result.append({"path": item})
        else:
            result.append(item)
    return result


def resolve_transports(config: dict) -> list[dict]:
    """Resolve transport configuration. Defaults to stdio."""
    transport = config.get("transport")
    if not transport:
        return [{"type": "stdio"}]
    if isinstance(transport, list):
        return transport
    return [transport]


def resolve_credentials(source: dict):
    """Resolve a credential source (env var or file)."""
    if "env" in source:
        env_var = source["env"]
        value = os.environ.get(env_var)
        if not value:
            _log(f"Warning: environment variable {env_var} not set")
            return None
        try:
            return json.loads(value)
        except (json.JSONDecodeError, ValueError):
            return value

    if "file" in source:
        file_path = source["file"]
        if file_path.startswith("~"):
            file_path = str(Path.home()) + file_path[1:]
        try:
            raw = Path(file_path).read_text(encoding="utf-8")
            try:
                return json.loads(raw)
            except (json.JSONDecodeError, ValueError):
                return raw
        except OSError:
            _log(f"Warning: cannot read credential file {file_path}")
            return None

    return None


def resolve_auth(auth: str | None) -> str | None:
    """Resolve an auth string. Supports 'env:VAR_NAME' syntax."""
    if not auth:
        return None
    if auth.startswith("env:"):
        env_var = auth[4:]
        value = os.environ.get(env_var)
        if not value:
            _log(f"Warning: environment variable {env_var} not set")
        return value
    return auth


ICON_MIME = {
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".gif": "image/gif",
    ".svg": "image/svg+xml",
    ".ico": "image/x-icon",
    ".webp": "image/webp",
}


def resolve_icon(icon: str | None) -> str | None:
    """Resolve an icon config value to a data URI.

    Accepts: data URI (passthrough), URL (fetched), file path (read).
    """
    import base64
    import urllib.request

    if not icon:
        return None

    # Already a data URI
    if icon.startswith("data:"):
        return icon

    # URL — fetch and convert
    if icon.startswith("http://") or icon.startswith("https://"):
        try:
            req = urllib.request.Request(icon)
            with urllib.request.urlopen(req, timeout=10) as resp:
                content_type = resp.headers.get("Content-Type", "image/png")
                data = resp.read()
                b64 = base64.b64encode(data).decode("ascii")
                return f"data:{content_type};base64,{b64}"
        except Exception as exc:
            _log(f"Warning: failed to fetch icon {icon}: {exc}")
            return None

    # File path
    try:
        file_path = icon
        if file_path.startswith("~"):
            file_path = str(Path.home()) + file_path[1:]
        p = Path(file_path)
        data = p.read_bytes()
        ext = p.suffix.lower()
        mime = ICON_MIME.get(ext, "image/png")
        b64 = base64.b64encode(data).decode("ascii")
        return f"data:{mime};base64,{b64}"
    except Exception as exc:
        _log(f"Warning: failed to read icon file {icon}: {exc}")
        return None


def _log(msg: str) -> None:
    import sys
    print(f"[zeromcp] {msg}", file=sys.stderr)
