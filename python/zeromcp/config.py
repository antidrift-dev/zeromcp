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


def _log(msg: str) -> None:
    import sys
    print(f"[zeromcp] {msg}", file=sys.stderr)
