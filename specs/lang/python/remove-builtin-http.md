# Remove the built-in HTTP server — Python

## Status
Done (2026-10-13). Verified in Docker: 198 unit tests pass (2 new), every Python conformance suite passes, and Python route conformance is 5/5 via `route-harness-python.py` (was 4/5).

## Why
ZeroMCP doesn't own the HTTP layer. Users run whatever HTTP server they already have and wire ZeroMCP in. `create_registry` (routes, OpenAPI, MCP handler as plain data, `python/zeromcp/registry.py:36-105`) and `create_handler` (`python/zeromcp/server.py:84-117`) already cover that. The hand-rolled `asyncio` server behind `transport: {"type": "http"}` is the one piece that puts an HTTP stack in the package.

Python has no public `serve_http` function. The server is reachable only through config: `serve()` starts `_start_http` for any transport entry with `"type": "http"` (`server.py:146-152`).

## Remove
All in `python/zeromcp/server.py`:
- `_start_http` (`server.py:658-754`): the `asyncio.start_server` listener, request parsing, `/openapi.json`, `/docs`, `/mcp` and route dispatch.
- `_http_respond` (`server.py:757-768`). Only `_start_http` calls it (`server.py:701, 722, 725, 740, 743, 745`).
- `_DOCS_HTML` (`server.py:642-655`). Only `_start_http` uses it (`server.py:706`).
- `_match_route_path` (`server.py:536-549`) and `_handle_http_route` (`server.py:552-576`). Their only callers are in `_start_http` (`server.py:736, 739`). `registry.py` imports neither (`registry.py:9-11`).
- The `elif t["type"] == "http"` branch in `serve()` (`server.py:149-152`), including the `port` default 8080 and `host` default `127.0.0.1`.

There is no `/health`, CORS or inbound bearer auth in the Python server (grep of `server.py` for those finds nothing), so there is nothing to remove for them. `config.resolve_auth` (`config.py:91`) stays: its only caller is `remote.py:42` (outbound auth to remote MCP servers).

No dependency changes. `python/pyproject.toml` declares no runtime dependencies, and every module import in `server.py` (`server.py:5-17`) is still used after the removal (`asyncio`, `base64`, `inspect`, `json`, `re`, `sys` all have callers outside the removed code).

## Startup error for `http` transport
In `serve()` (`server.py:120`), resolve transports right after loading config and before `_build_state`, so nothing is scanned or connected first. If any entry has `"type": "http"`, log and exit, the same way `_build_state` already exits on a fatal config (`server.py:40-41`: `_log(...)` then `sys.exit(1)`):

```
[zeromcp] The built-in HTTP transport was removed. Mount zeromcp.create_registry (routes, OpenAPI, MCP handler) or zeromcp.create_handler in your own HTTP server.
```

This applies when `http` is one entry in a list too: the whole config is rejected, no stdio fallback. The CLI needs no change: `python -m zeromcp serve` has no HTTP flags (`__main__.py:14-68`) and reaches this check through `serve(config)` (`__main__.py:68`).

## Keep
- `serve()` (stdio), `_start_stdio`, `handle_request` (`server.py:260`), `create_handler` (`server.py:84`), `create_registry` (`registry.py:36`).
- `build_openapi` (`server.py:579-639`). `create_registry` uses it (`registry.py:11, 105`) and `tests/test_openapi.py` tests it directly. It stays in `server.py`; after this change it is no longer HTTP-server code, just a function of `state`.
- `resolve_transports` (`config.py:51-58`), unchanged.
- README "HTTP / Streamable HTTP" section (`python/README.md:34-74`). It already says ZeroMCP doesn't own the HTTP layer and shows `create_handler` on Flask and FastAPI; it never documents the built-in server. Add a short `create_registry` example under it showing `registry.routes`, `registry.openapi` and `registry.mcp`, since the current text only covers `/mcp`.

## Breaking change
The `http` transport is in the published 0.3.0 package. PyPI JSON for `antidrift-zeromcp` lists releases 0.1.0, 0.1.1, 0.2.0, 0.2.2, 0.3.0 (latest 0.3.0). The 0.3.0 wheel's `zeromcp/server.py` has the `elif t["type"] == "http"` branch (line 111) and `_start_http` (line 607). Anyone with an `http` transport in their config gets the startup error above after upgrading.

`create_registry`, which the error names, is not in 0.3.0: that wheel's `zeromcp/__init__.py` imports only `create_handler, serve`. It ships in the same release as this removal. Changelog line: the `http` transport is gone; mount `zeromcp.create_registry` or `zeromcp.create_handler` in your own server.

## Tests
- Unit tests: no test in `python/tests/` touches `_start_http`, `_http_respond`, `_match_route_path`, `_handle_http_route` or `_DOCS_HTML` (grep finds none). Nothing to delete or move. `tests/test_openapi.py` (imports `build_openapi`, `test_openapi.py:5`) stays as is. `tests/test_config.py:60-72` (`resolve_transports` with `sse`/`stdio`) is unaffected.
- Add one test: `serve({"transport": {"type": "http", "port": 1}})` raises `SystemExit` with code 1 and stderr contains `create_registry`. Add a second with `[{"type": "stdio"}, {"type": "http"}]` to prove no fallback.
- Route conformance: Python's entry (`tests/conformance/run-route.js:25-31`) runs `python3 -m zeromcp serve --config route-config-python.json`, and that config asks for `{"type": "http", "port": 14251}` (`tests/conformance/route-config-python.json:3`). It is the only file that references that config. Replace it with a test-only harness `tests/conformance/route-harness-python.py`, stdlib only (`http.server.ThreadingHTTPServer`), on port 14251:
  - Load `tests/conformance/route-tools/*.py` with `importlib`, building `{name: {"description", "input", "route", "execute": module.execute}}`. Don't go through `ToolScanner`: it wraps `execute` to one argument (`scanner.py`), and `create_registry` calls `execute(args, env)`.
  - `registry = await create_registry(tools)`.
  - `GET /health` returns 200, which `waitForPort` polls (`run-route.js:99-109`).
  - `GET /openapi.json` returns `registry.openapi`.
  - `GET /docs` returns a Swagger UI HTML page (the harness owns this HTML now), as `run-route.js:173-178` checks.
  - `POST /mcp` returns `await registry.mcp(body)`.
  - For everything else, match `registry.routes` by method and `:param` path, merge path params with query (GET) or JSON body (other methods), call `route.tool["execute"](args, {})`, and respond `{"ok": true, "result": <return value>}`. `run-route.js:155-156` expects `result` as the tool's object, not a JSON-encoded string.
  
  Then point `run-route.js:26-28` at `python3 tests/conformance/route-harness-python.py` and delete `tests/conformance/route-config-python.json`.
- Chaos (`tests/chaos/run-chaos.js:386-390`) and all other `run-all.js` Python entries use stdio `serve`. No change.
- Performance: `tests/performance/run-mixed-docker.mjs:45-75` and `run-mixed-all.mjs:44-86` already mount `create_handler` on stdlib `HTTPServer`, and `tests/performance/Dockerfile` and the root `Dockerfile` build nothing Python-HTTP-specific. No change.

## Verify
```sh
docker build -t zeromcp-tests .
docker run --rm zeromcp-tests sh -c 'cd python && python3 -m unittest discover -s tests -q'
docker run --rm zeromcp-tests node tests/conformance/run-all.js --language "Python"
docker run --rm zeromcp-tests node tests/conformance/run-route.js
grep -rnE 'start_server|_start_http|_http_respond|_DOCS_HTML|"http"' python/zeromcp   # expect only the startup-error check in serve()
```
