# Remove the built-in HTTP server — PHP

## Status
Not started. Spec only.

## Why
ZeroMCP doesn't own the HTTP layer. Users run whatever HTTP server they already have and wire ZeroMCP in. `ZeroMcp\Registry::create()` (routes, OpenAPI, MCP handler as plain data) and `Server::handleRequest()` already cover that.

PHP's "HTTP server" is not a listener. `Server::serveHttp()` (`php/src/Server.php:88-159`) is a one-request SAPI handler: it reads `$_SERVER['REQUEST_METHOD']`/`REQUEST_URI` (`:93-94`) and `php://input` (`:98`, `:125`), does its own routing for `/mcp`, tool routes, `/openapi.json`, `/docs` and a 404, and writes the response with `header()`/`http_response_code()`/`echo`. There is no accept loop, port, CORS, auth or `/health`. It still owns the whole request/response cycle (routing, path params, body parsing, response writing), which is the HTTP layer the decision removes. So it goes, and `Registry` + `handleRequest()` are the replacement.

It also has no working entry point in the repo:
- `php zeromcp.php http ./tools` (CLI SAPI) loads tools, handles one synthetic `GET /`, prints the 404 JSON and exits 0, with a "headers already sent" warning. Checked by running it.
- `php -S 127.0.0.1:<port> zeromcp.php` fatals on every request at `zeromcp.php:16` (`count($argv)`, `$argv` undefined under the CLI server). Checked by running it.
- A user-written front controller that calls `serveHttp()` under `php -S` would hit `fwrite(STDERR, ...)` in `loadTools()` (`Server.php:66`). `STDERR` is undefined under `php -S`; that was checked with a minimal script, not with `serveHttp()` itself. Behaviour under FPM/Apache is unverified.

## Remove
- `Server::serveHttp()` and its docblock (`php/src/Server.php:79-159`).
- `Server::buildSwaggerHtml()` (`Server.php:253-271`). Its only caller is `serveHttp()` (`:152`).
- `Server::matchRoutePath()` and its docblock (`Server.php:691-716`). Its only caller is `serveHttp()` (`:118`). `Registry` does not use it (`php/src/Registry.php:50-54` builds routes without matching).
- The `http` subcommand in `php/zeromcp.php`: the `'http'` branch of the command check (`:28`), `serveHttp` in the usage string (`:29`) and the `if ($command === 'http')` dispatch (`:44-48`). `serve` becomes the only command. `zeromcp.php http` exits 1 with the error under "Startup error" below, not the usage line.
- `tests/conformance/route-config-php.json`. Its only user is `tests/conformance/run-route.js:42`, which is replaced below.

## Startup error
PHP has no `transport` config today. `Config::__construct` never reads a `transport` key (`php/src/Config.php:20-40`), so `route-config-php.json`'s `"transport": [{ "type": "http", "port": 14253 }]` is silently ignored and the server runs stdio. Add the settled check:
- In `Config::__construct`, if `$opts['transport']` is a list containing an entry whose `type` is `'http'`, throw `\InvalidArgumentException`. The list-of-`{type, ...}` shape is the one in `tests/conformance/route-config-php.json:3`. Every config path goes through the constructor: `Config::load()` (`Config.php:55`), `new Config(...)` in `zeromcp.php:35,39`, and direct use. Message:
  `[zeromcp] The "http" transport has been removed. ZeroMCP does not ship an HTTP server. Mount ZeroMcp\Registry::create($tools) (->routes, ->openapi, ->mcp()) or Server::handleRequest() in your own HTTP server.`
- Other `transport` entries (`stdio`) are accepted and ignored, as today. The mode is still chosen by the CLI command.
- `zeromcp.php` catches that exception around config construction (`:33-41`), writes the message to `STDERR` and exits 1. The `http` subcommand prints the same message and exits 1.

## Keep
- `Server::serve()` (stdio, `Server.php:273-295`), `Server::handleRequest()` (`:309`), `Server::loadTools()`, `Server::fromTools()`.
- `Server::buildOpenApiSpec()` (`Server.php:161-251`). `Registry::create()` calls it (`Registry.php:56`), so it stays public on `Server`.
- `Registry` / `RouteDefinition` (`php/src/Registry.php`), unchanged.
- `composer.json` unchanged. `require` is `php >=8.1` only (`php/composer.json:19-21`), and no dependency exists only for HTTP.
- README "HTTP / Streamable HTTP" section (`php/README.md:35-64`). It already says "ZeroMCP doesn't own the HTTP layer". Switch the Slim example from `$server->handleRequest()` to `Registry::create($tools)`, mounting `$registry->routes`, `/mcp` via `$registry->mcp()` and `/openapi.json` via `$registry->openapi`, so it shows the routes as well as `/mcp`. The README never documents the `http` subcommand, so there is nothing else to remove.

## Breaking change
Packagist lists `antidrift/zeromcp` 0.3.0 (2026-08-06, source `antidrift-dev/zeromcp-php` @ `8c826f2`). At that ref, `src/Server.php:88` has `public function serveHttp()` and `zeromcp.php:28,44` has the `http` subcommand. Removing them breaks anyone who calls `serveHttp()` or runs `zeromcp.php http`, although neither works as shipped (see Why). Note it in the next release's changelog with the one-line replacement: mount `ZeroMcp\Registry::create($tools)` in your own server. The monorepo has no PHP git tags (`git tag | grep -i php` is empty).

## Tests
- Unit tests: none exercise `serveHttp()`, `matchRoutePath()` or `buildSwaggerHtml()` (grep of `php/tests/*.php`). Nothing to delete. `ServerTest.php:394` (`testOpenApiNonGetRoutePathParam`) reflects on `buildOpenApiSpec()`, which stays, so it stays.
- Add to `php/tests/ConfigTest.php`: `new Config(['transport' => [['type' => 'http', 'port' => 1]]])` throws `\InvalidArgumentException` whose message contains `Registry::create`. `new Config(['transport' => [['type' => 'stdio']]])` does not throw.
- Route conformance: the PHP entry in `tests/conformance/run-route.js:39-46` runs `zeromcp.php serve --config route-config-php.json`. That is stdio, and it never answers `/health` (`run-route.js:104`), so it is always skipped as `optional`. Replace it with a test-only router script, `tests/conformance/route-harness-php.php`, run as `php -S 127.0.0.1:14253 <harness>`. `php -S` is part of `php-cli`, which the root `Dockerfile:31-32` already installs. The harness:
  - defines `STDERR` if it is undefined, because the library writes to it (`Scanner.php:146`, `Server.php:66`) and `php -S` does not define it;
  - `require`s `php/src/*.php`, scans `tests/conformance/route-tools` with `new Scanner(new Config(['tools' => ...]))`, then calls `Registry::create($tools)`;
  - serves `GET /health` → `{"status":"ok"}`, `POST /mcp` → `$registry->mcp()` (204 on `null`), `GET /openapi.json` → `$registry->openapi`, `GET /docs` → a static Swagger UI HTML string (needed by `run-route.js:175-179`), and each `$registry->routes` entry. Route matching (`:param` regex) and arg building (GET: query + path params; otherwise JSON body + path params; response `{ok, result}`, or 500 `{ok:false, error}`) live in the harness.
  - The `run-route.js` entry becomes `command: 'php', args: ['-S', '127.0.0.1:14253', join(__dirname, 'route-harness-php.php')]`. Drop `optional: true` so a failure shows instead of a skip.
- Nothing else in the repo launches PHP's built-in HTTP mode (checked):
  - `run-all.js`, `run-chaos.js:413-415` and `run-mixed-all.mjs:102-104` all use `serve` (stdio).
  - `run-mixed-docker.mjs:99-103` points at `php/examples/http-server.php`, which does not exist, and is `skip: true`.
  - `run-zeromcp-overnight.sh:77-80` and `rerun-zeromcp-cold-tiers.sh:66-68` run a `server-slim.php` from a `zeromcp-bench-http-php` image that is not in this repo (unverified what it calls).
  - Neither Dockerfile builds a PHP HTTP example.
  - No change to any of these.

## Verify
```sh
docker build -t zeromcp-tests .
docker run --rm zeromcp-tests sh -c 'cd php && for f in tests/*Test.php; do php "$f" || exit 1; done'
docker run --rm zeromcp-tests node tests/conformance/run-all.js --language "PHP"
docker run --rm zeromcp-tests node tests/conformance/run-route.js
docker run --rm zeromcp-tests sh -c 'php php/zeromcp.php http; test $? -eq 1'
grep -rn -E 'serveHttp|matchRoutePath|buildSwaggerHtml|\$_SERVER|php://input|http_response_code|header\(' php/src php/zeromcp.php   # expect nothing
```
