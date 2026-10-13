# Node parity — PHP

## Status
Done (2026-10-13). Docker: php unit tests 256 passed / 0 failed (new RemoteTest + Config/Scanner/Server/Registry cases); PHP conformance unchanged (all stdio suites pass).

## Gaps
1. Remote federation (`remote` config) in `Server` (covers serve, serveHttp, and the handler entry point)
2. Remote allowlist (`remote[].tools`)
3. Remote in `Registry::create()`
4. Runtime context injection (`get_runtime` → `$ctx->runtime`)
5. Hot reload (`autoload_tools`) in `serve()`
6. Tool sources with prefix, and `namespacing`

## 1. Remote federation in `Server`
**Node does:** `RemoteManager::connect()` (`nodejs/src/remote.ts:20-38`) connects to each `RemoteServer { name, url, auth?, tools? }` (`config.ts:5-11`): rejects non-http(s) URLs (`remote.ts:41-43`), POSTs `initialize` (id 1, params {}) then `tools/list` (id 2) (`remote.ts:52-59`) with `Content-Type: application/json` and `Authorization: Bearer <auth>` when set; non-2xx throws `HTTP <status>` (`remote.ts:87-98`). `auth` goes through `resolveAuth` (`config.ts:153-166`): `env:VAR` → env var (warns if unset), else literal. Each remote tool's `inputSchema` becomes local input via `schemaToInput` (`remote.ts:101-121`), and its `execute` POSTs `tools/call` {name, arguments}, returning `result.content[0].text` if truthy else `result` (`remote.ts:69-79`). Tools are keyed `<server.name>.<toolName>`, logged `[mcp] Remote tool: <name>`; a failing server logs `[mcp] Failed to connect to <name>: <msg>` and is skipped (`remote.ts:26-34`). `serve()` and `createHandler()` add remote tools first, then local tools override with `[zeromcp] Local tool "<name>" overrides remote` (`server.ts:23-36`, `handler.ts:39-49`). In `serve()` only, a throwing local scan with no `remote`/`resources`/`prompts` exits 1 with `[zeromcp] No tools directory and no remote servers configured` (`server.ts:37-42`).

**PHP today:** No `remote` anywhere: `grep -rni remote php/src php/zeromcp.php` returns nothing. `Config` has no `remote` property (`php/src/Config.php:7-18`). `Server::loadTools()` sets `$this->tools = $this->scanner->scan()` directly (`php/src/Server.php:65`). The handler entry point equivalent to Node's `createHandler` is `new Server($config)` → `loadTools()` → `handleRequest()` (`Server.php:59-63`, `Server.php:309`; documented in `php/README.md:35-64`). `serve()` (`Server.php:273-275`) and `serveHttp()` (`Server.php:88-90`) both call `loadTools()`, so one change there covers all three entry points.

**Change:**
- New `php/src/RemoteManager.php` (namespace `ZeroMcp`, PSR-4 name matches file). Add `require_once __DIR__ . '/src/RemoteManager.php';` to `php/zeromcp.php` (its require list is `zeromcp.php:4-11`).
- `php/src/Config.php`: add `public array $remote;` set from `$opts['remote'] ?? []`, and `Config::resolveAuth()`.
- `php/src/Server.php`: merge remotes in `loadTools()`; serve-path exit rule.

```php
namespace ZeroMcp;

// Config.php
/** @var array<int, array{name: string, url: string, auth?: string, tools?: string[]}> */
public array $remote;
public static function resolveAuth(?string $auth): ?string;

// RemoteManager.php
final class RemoteManager
{
    /**
     * @param array<int, array{name: string, url: string, auth?: string, tools?: string[]}> $servers
     * @return array<string, Tool>  keyed "<server.name>.<toolName>"
     */
    public function connect(array $servers): array;
}
```

- **HTTP client:** `file_get_contents($url, false, stream_context_create(['http' => ['method' => 'POST', 'header' => ..., 'content' => json_encode($body), 'ignore_errors' => true]]))`, same stream-context approach `Server::resolveIcon()` already uses (`Server.php:796-797`). No curl, so `composer.json`'s `require` stays `{"php": ">=8.1"}` (`php/composer.json`). Read the status from `$http_response_header[0]`; anything outside 200-299 throws `RuntimeException("HTTP <status>")`.
- **Connect sequence per server:** URL must start with `http://` or `https://`, otherwise throw `Remote server "<name>" must have an HTTP/HTTPS URL, got: <url>`. Resolve auth once via `Config::resolveAuth()`. Send `initialize` (`id` 1, `params` `{}`) and then `tools/list` (`id` 2, `params` `{}`). Encode empty params as `new \stdClass()` so they serialize as `{}`. Log `[mcp] Connected to <name> (HTTP): <n> tool(s)`.
- **`resolveAuth`:** `null`/`''` → `null`. `env:VAR` → `getenv('VAR')`, logging `[zeromcp] Warning: environment variable VAR not set` when unset. Anything else is returned as-is.
- **`schemaToInput`** (private): for each `properties` key, `type` defaults to `'string'`. If the property has a `description` or is not in `required`, emit `['type' => .., 'description' => .. (if set), 'optional' => true (if not required)]`. Otherwise emit the bare type string. Build each remote tool with `new Tool(name: $rt['name'], description: $rt['description'] ?? '', input: $input, execute: ...)`. The `Tool` constructor computes `cachedSchema` (`php/src/Tool.php:31`). `route` stays `null`, so remote tools never reach `serveHttp()` route matching (`Server.php:113-114`) or `buildOpenApiSpec()` (`Server.php:165-166`).
- **Remote `execute`:** `function (array $args, ?Context $ctx) { ... }` POSTs `['jsonrpc' => '2.0', 'id' => (int) (microtime(true) * 1000), 'method' => 'tools/call', 'params' => ['name' => $rt['name'], 'arguments' => (object) $args]]` with the same auth. If `$res['result']['content'][0]['text']` is truthy, return it. Otherwise return `$res['result'] ?? null`. The caller's `$ctx` is ignored.
- **Failure isolation:** wrap each server in `try/catch (\Throwable)`. On failure, log `[mcp] Failed to connect to <name>: <msg>` and continue with the next server. Log `[mcp] Remote tool: <name>` for each tool added.
- **`Server::loadTools()`:** if `$this->config->remote` is non-empty, set `$this->tools = (new RemoteManager())->connect(...)`. Then for each scanned local tool, log `[zeromcp] Local tool "<name>" overrides remote` when the key already exists, and set it. Resources, prompts and icon are unchanged.
- **Exit rule, `serve()`/`serveHttp()` only:** if the local scan throws and `remote`, `resources` and `prompts` are all empty in config, log `[zeromcp] No tools directory and no remote servers configured` and `exit(1)`. Implementation: `loadTools()` gains no new public parameter. Move the scan-and-merge into a private `loadToolsInternal(bool $tolerateScanFailure)`. The serve paths call it with `true`; public `loadTools()` calls it with `false`, so a scan exception propagates, as in Node's `createHandler` (`handler.ts:44-45`, no try).
- `serveHttp()` runs once per request (`Server.php:83-90`), so remotes get connected on every HTTP request, the same way local tools are rescanned per request today. No caching is added.

**Tests:** new `php/tests/RemoteTest.php`, a standalone runner in the same style as `php/tests/RegistryTest.php` (own `run()`/`assert()`, `require_once` list). Add a fixture `php/tests/fixtures/remote/router.php` that returns the same canned responses as `nodejs/test/handler-remote.test.js:6-17`. Start it with `proc_open('php -S 127.0.0.1:<port> router.php')` and kill it after. Cases:
- remote tools listed as `probeo.list_pages`/`probeo.get_page` via `handleRequest` `tools/list`
- `tools/call` returns the upstream `content[0].text`
- `auth: 'env:X'` sends `Authorization: Bearer <value>` (the router echoes the header)
- a non-http URL and an unreachable URL are both skipped while a good server still loads
- a non-2xx response is skipped
- a local tool named `probeo.list_pages` wins and logs the override
- remote tools are absent from `buildOpenApiSpec()['paths']`

## 2. Remote allowlist
**Node does:** `remote[].tools?: string[]` filters the upstream `tools/list` to names in the list. If it is omitted, every tool is exposed (`config.ts:9-10`, `remote.ts:61`).

**PHP today:** Not present. There is no remote support at all (see 1).

**Change:** in `RemoteManager`, after `tools/list`, keep only entries where `!isset($server['tools']) || in_array($rt['name'], $server['tools'], true)`. Filtering uses the upstream name, before the `<server>.` prefix is applied.

**Tests:** in `RemoteTest.php`, `tools: ['list_pages']` exposes only `probeo.list_pages` (mirrors `handler-remote.test.js:28-31`). Omitting `tools` exposes both.

## 3. Remote in `Registry::create()`
**Node does:** `createRegistry(tools, { remote })` connects the remotes first, then sets local tools over them with the same override log (`nodejs/src/registry.ts:49-65`). Remote tools appear in `mcp` `tools/list`/`tools/call`, but `routes` is built only from the local `tools` (`registry.ts:69-74`), so remotes never appear in `routes`/`openapi`. `createRegistry` is async because of this.

**PHP today:** `Registry::create(array $tools, array $options = [])` accepts only `get_env` and `config` (`php/src/Registry.php:36-41`). It passes the normalized local tools straight to `Server::fromTools()` (`Registry.php:48`).

**Change:** `php/src/Registry.php`. It stays synchronous: the remote HTTP calls block, and PHP has no async (registry.md "Behavior"). Add an options field:

```php
/**
 * @param array{
 *   get_env?: callable(): mixed,
 *   config?: Config,
 *   remote?: array<int, array{name: string, url: string, auth?: string, tools?: string[]}>,
 * } $options
 */
public static function create(array $tools, array $options = []): self;
```

- If `$options['remote']` is non-empty, set `$merged = (new RemoteManager())->connect($options['remote'])`. Then for each `$normalized` local tool, log `[zeromcp] Local tool "<name>" overrides remote` when the key exists, and set it. Pass `$merged` to `Server::fromTools()`.
- `$routes` keeps iterating `$normalized` (local only) as it does now (`Registry.php:50-54`). `openapi` comes from `$server->buildOpenApiSpec()`, which skips `route === null` (`Server.php:166`), so remote tools are excluded with no extra code.
- Registry reads remotes only from `$options['remote']`. `$options['config']->remote` is ignored, in keeping with Registry not reading config-driven discovery (registry.md "Non-goals").

**Tests:** add to `php/tests/RegistryTest.php`, reusing the `RemoteTest.php` fixture server. Cases:
- remote tools appear in `mcp(tools/list)` as `probeo.*` and `mcp(tools/call)` returns upstream text
- a local `probeo.list_pages` overrides the remote one
- `routes` and `openapi['paths']` contain no remote tools

These mirror `nodejs/test/registry.test.js:180-230`.

## 4. Runtime context injection
**Node does:** `createHandler(config, { getRuntime })` (`nodejs/src/handler.ts:19-23, 44`) passes `getRuntime` to `ToolScanner`. On every local tool execute it calls `getRuntime()` and, if the result is not `undefined`, sets `ctx.runtime` alongside `credentials`/`fetch` (`scanner.ts:9-13, 167-172`). `serve()` does not accept it (`server.ts:11, 30`).

**PHP today:** `Context` has `toolName`, `credentials`, `permissions`, `bypass` and no runtime (`php/src/Tool.php:56-69`). `Server::__construct(?Config $config = null)` takes no options (`Server.php:36`). `callTool()` builds the `Context` from `resolveCredentials()` only (`Server.php:594-596`).

**Change:**
- `php/src/Tool.php` (`Context`): add `public mixed $runtime = null;`. PHP has no generics, so `mixed` mirrors `Context::$credentials` (`Tool.php:59`).
- `php/src/Server.php`: add `private ?\Closure $getRuntime = null;` and an options array on the constructor:

```php
/** @param array{get_runtime?: callable(): mixed} $options */
public function __construct(?Config $config = null, array $options = []);
```

- In `callTool()`, after the `Context` is built (`Server.php:595-596`): `if ($this->getRuntime !== null) { $rt = ($this->getRuntime)(); if ($rt !== null) $ctx->runtime = $rt; }`. It runs on every call. `null` stands in for Node's `undefined`.
- `php/zeromcp.php` does not pass `get_runtime`, matching Node's `serve()`. `Server::fromTools()` does not take it either, matching Node's registry, which has `getEnv` only.

**Tests:** in `php/tests/ServerTest.php`:
- `new Server($config, ['get_runtime' => fn() => ['db' => 'x']])` plus a fixture tool that returns `$ctx->runtime` gives `{"db":"x"}`
- a counter closure shows `get_runtime` is invoked once per `tools/call`
- without the option, `$ctx->runtime === null`

## 5. Hot reload (`autoload_tools`)
**Node does:** in `serve()`, if `config.autoload_tools`, it watches each tool source dir recursively. On a change to a tool file it logs `[zeromcp] Change detected: <file>` and rescans (`scanner.ts:184-206`). It then sets every rescanned tool into the existing tool map (it does not remove tools that disappeared) and sends `notifications/tools/list_changed` with `params: {}` (`server.ts:72-81`, `server.ts:107-111`). At startup it logs `[zeromcp] autoload_tools enabled — watching for changes`.

**PHP today:** Tools are loaded from directories at runtime by `require` (`php/src/Scanner.php:44-59, 136`), so this applies. There is no `autoload_tools` (`grep -rni autoload php/src` returns nothing). `serve()` is a blocking `fgets` loop with no timer (`Server.php:278-292`). `serveHttp()` rescans on every request (`Server.php:90`), so it already picks up changes and has no channel for notifications. This item applies to `serve()` only.

**Change:**
- `php/src/Config.php`: `public bool $autoloadTools;` from `$opts['autoload_tools'] ?? false`.
- `php/src/Server.php` `serve()`: when `autoloadTools` is set, log the startup line and replace the blocking read with a `stream_select([$stdin], null, null, 1)` loop. Each pass handles a ready line exactly as now, then compares a fingerprint of the tool dirs.
- **Fingerprint:** path → `filemtime`/`filesize` for every `*.php` under each tool source, recursive. Polling is used because stock PHP has no recursive fs-watch without an extension.
- **On change:** log `[zeromcp] Change detected: <relative path>` for each changed, added or removed file. Rescan once, then `foreach ($this->scanner->scan() as $n => $t) $this->tools[$n] = $t;`. That is merge, not replace, as in Node. Write `{"jsonrpc":"2.0","method":"notifications/tools/list_changed","params":{}}` plus a newline to STDOUT and `fflush`.
- `require` (not `require_once`, `Scanner.php:136`) re-executes the file on each scan, so no cache-busting is needed. Node needs `?t=` for that (`scanner.ts:139`). Whether opcache in CLI would serve stale code is unverified.
- When `autoloadTools` is false, `serve()` keeps the current `fgets` loop unchanged.

**Tests:** in `php/tests/ServerTest.php`, `proc_open('php zeromcp.php serve --config <tmp.json>')` with `autoload_tools: true` and a temp tools dir holding one tool. Write a second tool file, then read stdout until the `notifications/tools/list_changed` line appears (time out after about 5s). Then `tools/list` includes the new tool.

## 6. Tool sources with prefix, and `namespacing`
**Node does:** `tools` may be a string or an array of `string | {path, prefix?}`, normalized by `resolveToolSources` (`nodejs/src/config.ts:28-31, 35, 104-108`). A tool name is built in three steps (`scanner.ts:90-113`). First, the inner name is the filename. Second, for files in a subdirectory, the first directory segment `dir` gives a prefix of `namespacing[dir].prefix` if that is defined (an empty string means no prefix) and `dir` otherwise, joined to the inner name with `separator`. Third, `source.prefix + separator` is prepended when set. Credentials stay keyed by the first directory segment, not by the resulting name (`scanner.ts:115-120`). `resources`/`prompts` accept the same `string | {path, prefix}` shape, but only `path` is read (`resource-scanner.ts:62-65`, `prompt-scanner.ts:35-38`).

**PHP today:**
- `separator` is present (`Config.php:31`, `Scanner.php:162`).
- `tools` accepts a string or an array (`Config.php:22-23`), and each entry goes straight to `realpath($d)` (`Scanner.php:49-50`). An `{path, prefix}` object would reach `realpath()` as an array. Whether that throws a TypeError is unverified (not run).
- There is no `namespacing` (`grep -rn namespacing php/src` returns nothing). `buildName()` always uses the directory name (`Scanner.php:160-163`).
- `resourcesDirs`/`promptsDirs` go straight to `realpath()` the same way (`Config.php:25-29`, `Scanner.php:73-74, 94-95`).
- Credentials are matched on the tool-name prefix (`Server.php:648-653`), not the directory.

**Change:**
- `php/src/Config.php`: keep `$toolsDirs` (asserted by `php/tests/ConfigTest.php:56-66`) as the list of paths. Add:

```php
/** @var array<int, array{path: string, prefix: ?string}> */
public array $toolSources;          // from 'tools': string | (string | {path, prefix?})[]
/** @var array<string, array{prefix?: string}> */
public array $namespacing;          // from 'namespacing', default []
```

  `toolsDirs` becomes `array_column($toolSources, 'path')`. `resourcesDirs`/`promptsDirs` map object entries to their `path`.
- `php/src/Scanner.php`: `scan()` iterates `toolSources` and threads `prefix` through `scanDir()` → `loadTool()` → `buildName($filePath, $rootDir, ?string $sourcePrefix)`. `buildName()` applies the namespacing override (`array_key_exists('prefix', $this->config->namespacing[$dir] ?? [])` → use it, and an empty string means no dir prefix), then the source prefix.
- **Credentials:** they must stay keyed by directory, or a renamed dir or prefixed source loses its credentials under PHP's name-prefix match. Add `public ?string $credentialNs = null;` to `Tool`, set by `Scanner::loadTool()` to the first directory segment (or `null` for top-level files). `Server::resolveCredentials()` then matches `$this->config->credentials[$tool->credentialNs]` when `credentialNs` is set. It falls back to the existing name-prefix match otherwise, so `Registry`/`fromTools` tools are unchanged.

**Tests:**
- `php/tests/ConfigTest.php`: mixed `['./a', ['path' => './b', 'prefix' => 'x']]` normalizes `toolSources`/`toolsDirs`; `namespacing` defaults to `[]`; object entries in `resources`/`prompts` reduce to paths.
- `php/tests/ScannerTest.php`, temp-dir fixtures:
  - source prefix gives `x_math_add`
  - `namespacing: {math: {prefix: 'm'}}` gives `m_add`
  - `namespacing: {math: {prefix: ''}}` gives `add`
  - a custom `separator` is applied to both joins
- `php/tests/ServerTest.php`: credentials keyed `math` still reach a tool renamed to `m_add`.

## Already at parity / N/A
- `get_env` on the registry: `Registry::create(['get_env' => ...])` → `$ctx->credentials` on every call (`php/src/Registry.php:48`, `php/src/Server.php:644-646`, test `php/tests/RegistryTest.php:126-137`)
- Handler entry point (C): `Server::loadTools()` + `handleRequest()` is the equivalent of Node's `createHandler` (`php/README.md:35-64`, `Server.php:63, 309`). Its remote support is covered by gap 1.
- Multiple transports (H), N/A: PHP has no `transport` config. The mode comes from the CLI subcommand `serve|http` (`php/zeromcp.php:28-48`), and HTTP is a per-request SAPI handler with no in-process listener (`Server.php:80-88`), so there is no HTTP loop to run alongside stdio.
- `title` — `Config.php:39`, used `Server.php:246`
- `logging` — parsed `Config.php:32`
- `bypass_permissions` — `Config.php:33`, used `Server.php:596`
- `cache_credentials` — `Config.php:36`, used `Server.php:659-667`
- `execute_timeout` — `Config.php:34`, used `Server.php:599`
- `page_size` — `Config.php:37`, used `Server.php:420`
- `resources` / `prompts` — `Config.php:25-29`, `Scanner.php:68-104`
- `icon` — `Config.php:38`, `Server.php:786-841`
- `credentials` — `Config.php:35`, `Server.php:642-687`
- `separator` — `Config.php:31`, `Scanner.php:162`

## Verify
All build and test runs happen in the local all-language Docker image (repo-root `Dockerfile`, per `engineering/testing.md`), not on host toolchains. The image copies the source in at build time, so rebuild it after every change.

```sh
docker build -t zeromcp-tests .
docker run --rm zeromcp-tests sh -c 'cd php && for f in tests/*Test.php; do php "$f" || exit 1; done'
docker run --rm zeromcp-tests node tests/conformance/run-all.js --language "PHP"
```
