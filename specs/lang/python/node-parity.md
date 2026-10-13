# Node parity — Python

## Status

Done (2026-10-13). All six gaps implemented. Verified in the Docker image: 196 unit tests pass and every Python conformance suite passes.

## Gaps

1. Remote MCP client (`zeromcp/remote.py`): no remote federation exists
2. Remote allowlist (`remote[].tools`)
3. Remote merge in `serve()` and `create_handler()`, plus the "no tools and no remotes" exit in `serve()`
4. Registry: not implemented. Port it per `registry.md`, plus Node's additions beyond that spec
5. Runtime context injection (`get_runtime` → `ctx.runtime`)
6. Hot reload (`autoload_tools`)

## 1. Remote MCP client

**Node does:** `RemoteManager.connect(servers)` (`nodejs/src/remote.ts:20-38`) connects to each `{name, url, auth?, tools?}` server (`config.ts:5-11`). For each server it rejects URLs that are not http(s) (`remote.ts:41-43`), resolves `auth` with `resolveAuth` (`remote.ts:49`), POSTs `initialize` (id 1, `params: {}`) and then `tools/list` (id 2) (`remote.ts:52-59`), and converts each tool's `inputSchema` back to the simplified input shape with `schemaToInput` (`remote.ts:101-121`). Each tool's `execute` POSTs `tools/call` and returns `result.content[0].text` when present, otherwise `result` (`remote.ts:69-79`). Tools are named `<server.name>.<toolName>`. A server that fails is logged and skipped (`remote.ts:32-34`). HTTP requests send `Content-Type: application/json` and `Authorization: Bearer <auth>` when auth is set, and a non-2xx status throws `HTTP <status>` (`remote.ts:87-99`).

**Python today:** none of this exists. `grep -rn "remote" python/zeromcp python/tests` finds no matches. `resolve_auth` (`env:VAR` → env var, else literal) already exists at `python/zeromcp/config.py:91-101`. `to_json_schema` is at `python/zeromcp/schema.py:9-42`.

**Change:** add a new file, `python/zeromcp/remote.py`. It is stdlib only, because `pyproject.toml` declares no runtime dependencies.

```python
class RemoteManager:
    def __init__(self) -> None:
        self.connections: dict = {}

    async def connect(self, servers: list[dict]) -> dict[str, dict]:
        """servers: [{"name": str, "url": str, "auth"?: str, "tools"?: list[str]}].
        Returns {"<server>.<tool>": tool_dict}."""

    def stop(self) -> None: ...

def _schema_to_input(schema: dict | None) -> dict: ...
```

- `connect` handles servers in order. For each tool, log `[mcp] Remote tool: <server>.<tool>`. On any exception for a server, log `[mcp] Failed to connect to <name>: <exc>` and continue with the next server. These lines use the `[mcp]` prefix, written to stderr with `print` and not through `_log`, which prints `[zeromcp]`.
- Reject a URL that does not start with `http://` or `https://` by raising `Remote server "<name>" must have an HTTP/HTTPS URL, got: <url>`.
- Use `resolve_auth(server.get("auth"))` from `config.py`.
- Send `initialize` `{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}`, then `tools/list` with id 2. Read the tools from `result.tools`, defaulting to `[]`.
- Each tool dict has the same shape that `ToolScanner` produces (`scanner.py:117-123`): `description`, `input` (from `_schema_to_input`), `_cached_schema` (from `to_json_schema(input)`), and a **one-arg** `async def execute(args)`, which is the form that `_call_tool` calls (`server.py:467`). There is no `route` and no `permissions` key.
- `execute` POSTs `{"jsonrpc":"2.0","id":int(time.time()*1000),"method":"tools/call","params":{"name":<upstream name>,"arguments":args}}`. If `result.content[0].text` is truthy, return it. Otherwise return `result`.
- After each server connects, log `[mcp] Connected to <name> (HTTP): <n> tool(s)`.
- HTTP: run `urllib.request.urlopen` (method POST, JSON body, the headers above) in `asyncio.to_thread`, with no timeout, matching Node's `fetch`. A non-2xx status, including `urllib.error.HTTPError`, raises `RuntimeError(f"HTTP {status}")`. The body is parsed with `json.loads`.
- `_schema_to_input`: return `{}` when `properties` is missing. For each property, `type` defaults to `"string"`. If the property has a `description` or is not in `required`, emit `{"type": t, "description"?: d, "optional"?: True}`. Otherwise emit the bare type string.

**Tests:** add a new file, `python/tests/test_remote.py` (unittest, like the rest of `python/tests/`). It runs a fake upstream on `http.server.ThreadingHTTPServer` at port 0 in a background thread, answering `initialize`, `tools/list` and `tools/call`, which mirrors `nodejs/test/handler-remote.test.js`. Cover:
- namespacing
- the `content[0].text` unwrap
- the `Authorization` header from a literal value and from `env:VAR`
- a non-http URL being skipped with the `Failed to connect` log
- a 500 upstream being skipped while a second good server still loads
- the `_schema_to_input` cases

## 2. Remote allowlist

**Node does:** `remote[].tools?: string[]`. Only upstream tools whose name is in the list are exposed. If the list is omitted, all tools are exposed (`nodejs/src/config.ts:9-10`, `remote.ts:61`).

**Python today:** absent. There is no remote support at all (see gap 1).

**Change:** in `RemoteManager`, after `tools/list`, filter the tools to `t["name"] in server["tools"]` when `server.get("tools")` is not `None`. The filter checks the upstream name, before namespacing.

**Tests:** in `test_remote.py`, add a case that configures `tools: ["list_pages"]` against an upstream that has two tools and asserts that only `probeo.list_pages` is listed. This is the same case as `handler-remote.test.js`.

## 3. Remote merge in `serve()` and `create_handler()`

**Node does:** both `serve()` (`nodejs/src/server.ts:20-42`) and `createHandler()` (`handler.ts:36-49`) connect to the remotes first, then scan local tools. A local tool with the same name overrides the remote one and logs `[zeromcp] Local tool "<name>" overrides remote`. In `serve()`, if the local scan throws and there are no `remote`, no `resources` and no `prompts`, it logs `No tools directory and no remote servers configured` and exits 1 (`server.ts:37-41`). Remote tools have no `route`, so they never reach REST routing or OpenAPI.

**Python today:** both entry points build their state through the synchronous `_build_state(config)` (`python/zeromcp/server.py:17-63`, called at `:87` and `:102`). `_build_state` scans local tools only and swallows scan errors with `_log("No tools directory found")` (`server.py:21-25`). `serve()` never exits on that path. Route dispatch (`server.py:678-690`) and `_build_openapi` (`server.py:532-535`) already skip tools that have no `route`.

**Change** (`python/zeromcp/server.py`):

```python
async def _build_state(config: dict, *, exit_without_sources: bool = False, get_runtime=None) -> dict
```

- Make `_build_state` `async`, and have both callers `await` it.
- When `config.get("remote")` is non-empty, `remote_tools = await RemoteManager().connect(config["remote"])`, and seed `all_tools` with `remote_tools`.
- Then merge `scanner.tools`: for each name already in `all_tools`, log `Local tool "<name>" overrides remote` before assigning it.
- `serve()` passes `exit_without_sources=True`. In the scan `except` branch, if that flag is set and `remote`, `resources` and `prompts` are all falsy, log `No tools directory and no remote servers configured` and call `sys.exit(1)`. Otherwise keep the existing log. `create_handler` keeps the current swallow.
- No change to routing or OpenAPI is needed, because remote tool dicts carry no `route`.

**Tests:** in `test_remote.py`:
- `create_handler({"tools": [], "remote": [...]})` lists and calls `probeo.list_pages`, as in Node's `handler-remote.test.js`.
- Local override: a temporary tools dir holding `list_pages.py`, with config `{"tools": [{"path": <dir>, "prefix": "probeo"}], "separator": ".", "remote": [{"name": "probeo", ...}]}`. Because `_build_name` (`scanner.py:63-65`) then produces `probeo.list_pages`, this collides with the remote name. Assert that the local tool wins and the `overrides remote` line is logged.
- `serve()` exit: patch `ToolScanner.scan` to raise and assert `SystemExit(1)` from `await _build_state({}, exit_without_sources=True)`. The test has to be in-process with a patch, because `scan()` does not raise on a missing directory (`scanner.py:36-40`).

## 4. Registry: not implemented, plus Node's additions

**Gap:** `create_registry` does not exist. `python/zeromcp/registry.py` is absent, and `python/zeromcp/__init__.py:5` exports only `create_handler, serve`. Implement it per `specs/lang/python/registry.md`. That spec already covers `get_env` as the second argument to `execute`.

**Node does, beyond `registry.md`:** `createRegistry` is `async` and takes `{ getEnv, title, version, executeTimeout, remote }` (`nodejs/src/registry.ts:25-34, 42-45`). Remote tools are connected first and merged under the same rule as gap 3: a local tool overrides a remote one, with the same log (`registry.ts:49-65`). Remote tools appear in `mcp` `tools/list` and `tools/call` but never in `routes` or `openapi`, because `routes` is built from the caller's `tools` only (`registry.ts:69-74`). `title` and `version` feed the OpenAPI `info` block, defaulting to `'ZeroMCP'` and `'1.0.0'` (`openapi.ts:82`). `version` is also reported in `initialize` `serverInfo` (`dispatch.ts:154`). `executeTimeout` defaults to 30000 ms (`registry.ts:81`). When more than one tool shares `METHOD path`, it logs `<n> tools registered the same route "<key>" — only your own router's route matching, not this registry, decides which one runs` (`registry.ts:67-77`).

**Python today:** none of this is in `registry.md`. That spec defines a synchronous `create_registry(tools, *, get_env=None)` and uses `execute_timeout=30` with no title or version. The dispatcher hardcodes `serverInfo.version` as `"0.2.0"` (`server.py:246`), and `_build_openapi` hardcodes `info.version` as `"0.5.0"` (`server.py:586`).

**Change:** apply the following on top of `registry.md`.

```python
async def create_registry(
    tools: dict[str, dict],
    *,
    get_env: Callable[[], Any] | None = None,
    title: str | None = None,          # default "ZeroMCP"
    version: str | None = None,        # default "1.0.0"
    execute_timeout: float | None = None,  # seconds, default 30 (Python's existing unit, server.py:58/467)
    remote: list[dict] | None = None,  # same shape as config["remote"]
) -> ToolRegistry
```

- The function is `async def`, not sync as `registry.md` has it.
- If `remote` is set, `await RemoteManager().connect(remote)` (gap 1) and seed the internal tools with the result. Then merge local tools on top, logging `Local tool "<name>" overrides remote` for each name collision.
- `routes` is built from the caller's `tools` only, so remote tools never appear there. `openapi` is built from the internal state, but remote tools have no `route`, so `build_openapi` skips them.
- The internal state gets `"title": title or "ZeroMCP"`, `"version": version or "1.0.0"` and `"execute_timeout": execute_timeout or 30`.
- In `server.py`, `handle_request`'s `initialize` reads `state.get("version", "0.2.0")` and `build_openapi` reads `state.get("version", "0.5.0")`. The existing defaults are kept, so `serve()` and `create_handler()` output does not change.
- After building `routes`, count `f"{method} {path}"` keys and log the duplicate-route warning above for each key whose count is above 1.

**Tests:** add a new file, `python/tests/test_registry.py`, alongside the tests that `registry.md` already calls for. Add the cases from `nodejs/test/registry.test.js:98-121, 143, 156-227`:
- default and overridden `title`/`version` in `openapi.info`
- `initialize` reporting `version`
- a custom `execute_timeout`
- remote tools namespaced in `mcp` `tools/list` and `tools/call`
- a local tool overriding a remote one, with the log line
- remote tools absent from `routes` and `openapi.paths`
- the duplicate-route warning

Use the fake upstream from `test_remote.py`.

## 5. Runtime context injection

**Node does:** `createHandler(config, { getRuntime })` (`nodejs/src/handler.ts:19-23, 44`) passes `getRuntime` into `ToolScanner`. On every local tool execution, `getRuntime()` is called. If the result is not `undefined`, it is set as `ctx.runtime` alongside `credentials` and `fetch` (`scanner.ts:9-13, 167-172`). `serve()` does not accept it.

**Python today:** `create_handler(config_or_path)` takes no options (`python/zeromcp/server.py:66`). `ToolScanner.__init__(self, config)` takes no options (`scanner.py:15`). `_ToolContext` has only `credentials` and `fetch` (`scanner.py:132-137`), built at `scanner.py:113`. The registry's equivalent, `get_env`, is specified in `registry.md` but not implemented (see gap 4), so the registry is not at parity either.

**Change:**

```python
# scanner.py
class ToolScanner:
    def __init__(self, config: dict | None = None, *, get_runtime: Callable[[], Any] | None = None): ...

class _ToolContext:
    def __init__(self, credentials=None, fetch=None, runtime=None): ...

# server.py
async def create_handler(config_or_path: dict | str | None = None, *, get_runtime: Callable[[], Any] | None = None): ...
```

- The runtime value is `Any`, consistent with the untyped `credentials` attribute. `ctx.runtime` is always present on `_ToolContext` and is `None` when no `get_runtime` is given or when it returns `None`. This is Python's form of Node's omitted key.
- `wrapped_execute` (`scanner.py:111-114`) calls `scanner.get_runtime()` on every invocation, when one is set, and passes the result into `_ToolContext(credentials=..., fetch=..., runtime=...)`.
- `create_handler` passes `get_runtime` through `_build_state(config, get_runtime=...)` to `ToolScanner(config, get_runtime=...)`. `serve()` does not accept or pass it.
- Remote tools do not receive `ctx`, the same as in Node.

**Tests:** add a new file, `python/tests/test_handler.py`, with a fixture tool at `python/tests/fixtures/runtime_tools/whoami.py` that returns `ctx.runtime`. Assert that a call through `create_handler(..., get_runtime=lambda: {"user": "a"})` returns that value, that `get_runtime` is called once per `tools/call` (counter), and that without `get_runtime` the tool sees `None`.

## 6. Hot reload (`autoload_tools`)

**Node does:** in `serve()`, when `autoload_tools` is set, it watches each tool source directory recursively. On a change to a tool file, it logs `Change detected: <file>`, rescans, writes every scanned tool into the live tool map (`allTools.set`; tools are not deleted), and calls `state.notify('notifications/tools/list_changed', {})` (`nodejs/src/server.ts:73-81`, `scanner.ts:184-206`). At startup it logs `autoload_tools enabled — watching for changes`. Only stdio sets `notify`, which writes `{"jsonrpc":"2.0","method":m,"params":p}` lines to stdout (`server.ts:107-111`). `SIGINT` stops the watchers (`server.ts:95-100`).

**Python today:** tools are loaded from directories at runtime (`ToolScanner._scan_dir`, `scanner.py:35-46`), so the feature applies. `grep -rn "autoload\|watch\|notify" python/zeromcp` finds no watcher and no notify mechanism. The only `list_changed` reference is the inbound `notifications/roots/list_changed` at `server.py:228`. `_build_state` discards its `ToolScanner` (`server.py:20-23`).

**Change** (`python/zeromcp/scanner.py`, `python/zeromcp/server.py`):

```python
# scanner.py
_AUTOLOAD_POLL_INTERVAL = 0.5  # seconds

class ToolScanner:
    async def watch(self, on_change: Callable[[dict], None] | None = None) -> None: ...
    def stop(self) -> None: ...
```

- The standard library has no recursive filesystem watcher, so `watch` polls instead. It snapshots the `{path: mtime_ns}` of every `*.py` file under each source `path` (`Path.rglob`) every `_AUTOLOAD_POLL_INTERVAL` seconds. When a file is added, removed or modified, it logs `Change detected: <path relative to source>`, calls `self.scan()` and then `on_change(self.tools)`. `stop()` cancels the polling tasks.
- `_build_state` stores the scanner as `state["_tool_scanner"]`.
- In `serve()`, if `config.get("autoload_tools")`, start `asyncio.create_task(scanner.watch(on_change))`, where `on_change` does `state["tools"][name] = tool` for each scanned tool and calls `state["notify"]("notifications/tools/list_changed", {})` if `state.get("notify")`. Log `autoload_tools enabled — watching for changes`. Cancel the task when the transports return.
- `_start_stdio` sets `state["notify"] = fn`. The function writes `{"jsonrpc":"2.0","method":method}`, plus `"params"` when it is not `None`, as a JSON line to stdout and flushes.
- The rescan re-imports from source, because `_import_file` re-executes the file on each call (`scanner.py:322-332`).

**Tests:** add a new file, `python/tests/test_autoload.py`:
- In a temporary tools dir, start `ToolScanner.watch` with `_AUTOLOAD_POLL_INTERVAL` patched low. Edit the tool's description and add a new tool file. Assert that `on_change` fires and that the tool map reflects both changes.
- Assert that `_start_stdio`'s `notify` writes the notification line (patch `sys.stdout`).

## Already at parity

- Tool sources and naming config (`tools` as a string or a list of `str | {path, prefix}`, `separator` defaulting to `_`, `namespacing.<dir>.prefix`). Evidence: `python/zeromcp/config.py:21-33`, `python/zeromcp/scanner.py:18-20, 48-66`.
- Multiple transports at once (`transport` as an object or a list, with stdio and http running together). Evidence: `python/zeromcp/config.py:51-58`, `python/zeromcp/server.py:105-119`.
- Framework-agnostic handler entry point exists (`create_handler`), so checklist item C applies and is covered by gap 3. Evidence: `python/zeromcp/server.py:66-92`.
- `title`: `python/zeromcp/server.py:62`
- `logging`: `python/zeromcp/scanner.py:24`
- `bypass_permissions`: `python/zeromcp/scanner.py:25`
- `cache_credentials`: `python/zeromcp/scanner.py:23, 77-83`
- `execute_timeout`: `python/zeromcp/server.py:58, 464`
- `page_size`: `python/zeromcp/server.py:59, 181-189`
- `resources`: `python/zeromcp/scanner.py:175`
- `prompts`: `python/zeromcp/scanner.py:264`
- `icon`: `python/zeromcp/config.py:115-156`, `python/zeromcp/server.py:45`
- `credentials`: `python/zeromcp/scanner.py:21, 68-83`, `python/zeromcp/config.py:61-88`

## Verify
All build and test runs happen in the local all-language Docker image (repo-root `Dockerfile`, per `engineering/testing.md`), not on host toolchains. The image copies the source in at build time, so rebuild it after every change.

```sh
docker build -t zeromcp-tests .
docker run --rm zeromcp-tests sh -c 'cd python && python3 -m unittest discover -s tests -q'
docker run --rm zeromcp-tests node tests/conformance/run-all.js --language "Python"
```
