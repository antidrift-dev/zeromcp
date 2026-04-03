"""Permission system and sandboxed fetch (stdlib urllib.request)."""

from __future__ import annotations

import json
import sys
from urllib.error import URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen


def validate_permissions(name: str, permissions: dict | None) -> None:
    """Log elevated permission requests."""
    if not permissions:
        return
    elevated = []
    if permissions.get("fs"):
        elevated.append(f"fs: {permissions['fs']}")
    if permissions.get("exec"):
        elevated.append("exec")
    if elevated:
        _log(f"{name} requests elevated permissions: {' | '.join(elevated)}")


def _is_allowed(hostname: str, allowlist: list[str]) -> bool:
    for pattern in allowlist:
        if pattern.startswith("*."):
            suffix = pattern[1:]  # e.g. ".example.com"
            base = pattern[2:]  # e.g. "example.com"
            if hostname.endswith(suffix) or hostname == base:
                return True
        elif hostname == pattern:
            return True
    return False


def create_sandbox(
    name: str,
    permissions: dict | None = None,
    opts: dict | None = None,
) -> dict:
    """Create a sandbox context with a sandboxed fetch function."""
    logging = (opts or {}).get("logging", False)
    bypass = (opts or {}).get("bypass", False)

    async def sandboxed_fetch(
        url: str,
        *,
        method: str = "GET",
        headers: dict | None = None,
        body: str | bytes | None = None,
        timeout: int = 30,
    ) -> dict:
        """Sandboxed HTTP fetch using stdlib urllib.request.

        Returns dict with keys: status, headers, body, ok.
        """
        parsed = urlparse(url)
        hostname = parsed.hostname or ""

        # Check permissions
        network = (permissions or {}).get("network")

        if network is False:
            if bypass:
                if logging:
                    _log(f"! {name} -> {method} {hostname} (network disabled -- bypassed)")
            else:
                if logging:
                    _log(f"{name} x {method} {hostname} (network disabled)")
                raise PermissionError(f"[zeromcp] {name}: network access denied")

        if isinstance(network, list):
            if not _is_allowed(hostname, network):
                if bypass:
                    if logging:
                        _log(f"! {name} -> {method} {hostname} (not in allowlist -- bypassed)")
                else:
                    if logging:
                        _log(f"{name} x {method} {hostname} (not in allowlist)")
                    allowed = ", ".join(network)
                    raise PermissionError(
                        f"[zeromcp] {name}: network access denied for {hostname} "
                        f"(allowed: {allowed})"
                    )

        if logging:
            _log(f"{name} -> {method} {hostname}")

        # Make the actual request
        req = Request(url, method=method)
        if headers:
            for k, v in headers.items():
                req.add_header(k, v)
        data = None
        if body is not None:
            data = body.encode("utf-8") if isinstance(body, str) else body

        try:
            resp = urlopen(req, data=data, timeout=timeout)
            resp_body = resp.read().decode("utf-8")
            return {
                "status": resp.status,
                "headers": dict(resp.headers),
                "body": resp_body,
                "ok": 200 <= resp.status < 300,
            }
        except URLError as exc:
            raise ConnectionError(f"[zeromcp] {name}: fetch failed: {exc}") from exc

    return {"fetch": sandboxed_fetch}


def _log(msg: str) -> None:
    print(f"[zeromcp] {msg}", file=sys.stderr)
