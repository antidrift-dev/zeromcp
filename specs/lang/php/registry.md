# Framework-neutral tool registry — PHP

## Status

**Shipped**, on branch `registry/php`. Implemented exactly as designed below: `Registry.php` (`Registry`/`RouteDefinition` classes), `Server::fromTools()`, the `buildOpenApiSpec()` visibility change (`private` → `public`), the `$envOverride` seam in `resolveCredentials()`, and `Tool::fromDefinition()` (extracted from `Scanner::loadTool()`, which now calls it too — one mapping, two callers). Covered by 15 new tests in `tests/RegistryTest.php` (route filtering, insertion-order preservation, OpenAPI parity, direct tool invocation, `mcp` dispatch for `tools/list` and `tools/call`, `get_env` actually overriding `$ctx->credentials`, accepting raw definition arrays alongside `Tool` objects, empty-routes case, default-config-doesn't-read-disk). All 202 assertions across the full suite pass (21+27+32+30+77+15), zero regressions — confirmed `Scanner::loadTool()`'s refactor and `buildOpenApiSpec()`'s visibility change didn't change any existing behavior.

One pre-existing, unrelated issue surfaced while verifying: invoking `php zeromcp.php http` outside a real SAPI context (plain CLI, no `php -S`/Apache/php-fpm) throws "headers already sent" warnings — confirmed via `git stash` that this happens identically on unmodified `main`, so it predates and is unrelated to this work. Not fixed here; flagging for whoever next touches `serveHttp()`.

## Motivation

`php/src/Server.php::serveHttp()` already mounts `/mcp`, tool `route` definitions, `/openapi.json`, and `/docs` — but all of it is wired inline against PHP's single-request CGI/SAPI model (`$_SERVER`, `php://input`, `header()`, `echo`). It owns the whole request/response cycle for one specific way of running PHP (`php -S` or Apache/nginx+PHP-FPM dispatching straight to `zeromcp.php`).

`php/README.md` already documents the escape hatch for this: `Server::handleRequest(array $request): ?array` is public and framework-neutral, with a worked Slim example. That's half of what Node's registry provides (the `mcp` handler). What's missing is:

1. A way to build that dispatcher from a **plain array of already-built tools**, without going through `Scanner::scan()` and a tools directory — the same distinction Node draws between `scanner.ts` (file discovery) and `registry.ts` (takes a `Record<string, Tool>` you hand it).
2. `routes` and `openapi` exposed as **reusable data**, independent of `serveHttp()`'s request cycle, so a consumer embedding tools into Laravel, Slim, WordPress, or a PHP Lambda handler doesn't have to re-derive route metadata or regenerate the OpenAPI doc themselves.

This is additive, same as Node: `Server::serve()` / `Server::serveHttp()` are unchanged. The registry is a second, composable entry point for embedding tools built directly in PHP code (not scanned from files) into someone else's router.

## Public API

New file `php/src/Registry.php`, namespace `ZeroMcp`:

```php
namespace ZeroMcp;

final class RouteDefinition
{
    public function __construct(
        public string $name,
        public string $method,
        public string $path,
        public Tool $tool,
    ) {}
}

final class Registry
{
    /** @var RouteDefinition[] */
    public array $routes;

    /** Pre-built OpenAPI 3.0 document, same shape Server::buildOpenApiSpec() produces. */
    public array $openapi;

    /**
     * @param array<string, Tool|array> $tools  Tool objects, or raw tool-definition
     *   arrays in the same shape a tool file returns (description/input/permissions/
     *   execute/route). Mixed maps of both are fine.
     * @param array{
     *   get_env?: callable(): mixed,
     *   config?: Config,
     * } $options
     */
    public static function create(array $tools, array $options = []): self;

    /** JSON-RPC handler. Synchronous — PHP has no async/await. */
    public function mcp(array $request): ?array;
}
```

Usage sketch (Slim, mirroring the pattern already in `php/README.md`):

```php
$tools = [
    'greet' => Tool::fromDefinition('greet', [
        'description' => 'Greet someone',
        'input'       => ['name' => 'string'],
        'route'       => ['method' => 'GET', 'path' => '/greet/:name'],
        'execute'     => fn($args, $ctx) => "Hello, {$args['name']}!",
    ]),
];

$registry = Registry::create($tools, [
    'get_env' => fn() => ['apiKey' => getenv('API_KEY')],
]);

foreach ($registry->routes as $route) {
    $app->map([$route->method], $route->path, function ($req, $res) use ($route) {
        $params = array_merge($req->getQueryParams(), (array) $req->getParsedBody(), $req->getAttributes());
        $result = $route->tool->call($params);
        $res->getBody()->write(json_encode(['ok' => true, 'result' => $result]));
        return $res->withHeader('Content-Type', 'application/json');
    });
}

$app->post('/mcp', function ($req, $res) use ($registry) {
    $response = $registry->mcp(json_decode((string) $req->getBody(), true) ?? []);
    if ($response === null) return $res->withStatus(204);
    $res->getBody()->write(json_encode($response));
    return $res->withHeader('Content-Type', 'application/json');
});

$app->get('/openapi.json', fn($req, $res) => $res->getBody()->write(json_encode($registry->openapi)) ? $res : $res);
```

### Behavior

- **Tool input shape.** `$tools` is `array<string, Tool>` — same `ZeroMcp\Tool` class `Scanner` already produces (`description`, `input`, `permissions`, `execute`, `cachedSchema`, `route`). Registry entries may also be plain arrays in the exact shape a tool file already returns (`['description'=>.., 'input'=>.., 'execute'=>.., 'route'=>..]`); these get normalized to `Tool` via a new `Tool::fromDefinition(string $name, array $def): Tool` static factory. That factory is extracted from `Scanner::loadTool()`'s existing construction logic (`php/src/Scanner.php:142-154`, currently: read `permissions`, `route`, `description`, `input`, `execute` off `$toolDef` and `new Tool(...)`) — `Scanner::loadTool()` is refactored to call it too, so the array→`Tool` mapping exists in exactly one place. This is deliberately distinct from `Scanner::scan()`: Registry never touches `Config::toolsDirs` or the filesystem. A caller who wants both file-based discovery *and* embedding can compose them themselves: `$tools = (new Scanner($config))->scan(); $registry = Registry::create($tools);`.

- **`mcp` reuses `Server`'s dispatch, not a reimplementation.** Add a new static factory to `Server.php`: `Server::fromTools(array $tools, ?Config $config = null, ?callable $getEnv = null): self`. It builds a `Server` the normal way (`$config ?? new Config([])`) but sets `$server->tools` directly instead of calling `loadTools()`/`Scanner::scan()` — `resources`, `templates`, `prompts` stay empty (Registry, like Node's, only wires tools; the resulting `initialize` response correctly omits `resources`/`prompts` capabilities since `Server::handleInitialize()` already gates those on `!empty($this->resources)` / `!empty($this->prompts)`). `Registry::mcp()` is then just `fn(array $request): ?array => $this->server->handleRequest($request)` — the exact same `tools/list`, `tools/call`, `Schema::validate`, pcntl-based per-tool timeout, and pagination code paths `serve()`/`serveHttp()` already use. Zero duplicated JSON-RPC logic. Because `handleRequest()` is already synchronous and PHP has no async/await, `Registry::mcp()` is synchronous too — it returns `?array` directly, not a promise/generator, matching `Tool::execute` closures which are also plain synchronous callables (`function ($args, $ctx) { ... }`, no `Fiber` involved).

- **`get_env` and credentials.** PHP's `Tool::call(array $args, ?Context $ctx = null)` takes a concrete `Context` object (`toolName`, `credentials`, `permissions`, `bypass`), not a generic env type — PHP has no generics, so there's no literal equivalent of Node's `TEnv`. `Server::callTool()` currently sources `Context::$credentials` from `resolveCredentials($name)`, which matches the tool name against `Config::$credentials` namespace prefixes (env/file sources). That mechanism doesn't compose with a flat, per-call `get_env` value the way Node's `getEnv` does. Fix: add a settable override seam to `Server` — `private ?\Closure $envOverride = null;`, set by `Server::fromTools()`'s third `$getEnv` argument — and check it first in `resolveCredentials()`:
  ```php
  private function resolveCredentials(string $toolName): mixed
  {
      if ($this->envOverride !== null) {
          return ($this->envOverride)();
      }
      // ...existing namespace-based Config::$credentials lookup, unchanged
  }
  ```
  When `Registry::create()` is given `get_env`, every `tools/call` dispatched through `->mcp()` gets that value as `$ctx->credentials`, regardless of tool name — same flat, global semantics as Node's `getEnv`. When omitted, behavior falls back to normal `Config::$credentials` resolution (or `null` if that's also unset) — i.e. `serve()`/`serveHttp()` are completely unaffected since they never set `$envOverride`. Note PHP closures already capture their enclosing scope via `use (...)`, so a tool's `execute` closure can just close over whatever dependency it needs at construction time (`fn($args, $ctx) use ($pdo) => ...`) without ever touching `get_env` — `get_env` mainly matters when the value must be resolved lazily per call (request-scoped credentials in a long-running worker runtime like RoadRunner/Swoole/FrankenPHP) rather than once at boot. Default: `null` (i.e. `$ctx->credentials` stays whatever `Config::$credentials` resolves to, same as today).

- **`options.config`.** Optional `Config` instance controlling `execute_timeout`, `bypass_permissions`, `page_size`, `title` (used in `openapi.info.title`), and `credentials` (if `get_env` is not supplied). Defaults to `new Config([])` — i.e. `Registry::create()` never calls `Config::load()` / reads `zeromcp.config.json` implicitly. The whole point of the registry is "caller wires everything explicitly"; if a caller wants file-driven config they load it themselves and pass it in.

- **`routes`.** `Registry::create()` filters `$tools` down to entries with a non-null `->route`, preserving PHP's array insertion order (the same ordering guarantee Node gets from `Object.entries`), producing `RouteDefinition[]` (`name`, `method`, `path`, `tool`). No route matching, path-param extraction, or HTTP handling happens here — `Server::matchRoutePath()` exists and is used by `serveHttp()`, but Registry does **not** call it. The caller's own router (Slim's routing, Laravel route params, a Lambda event's `pathParameters`) does param extraction and decides what to pass to `$route->tool->call($args, $ctx)` — including what `$ctx` to build, since Registry has no opinion here (mirrors Node: "no route matching or HTTP handling is done here"). Note today's `serveHttp()` already calls `$tool->call($args)` for routes with **no** `$ctx` (defaults to `null`) — Registry doesn't touch or need to match that; `routes` is inert data, not a dispatch path.

- **`openapi`.** Reuses `Server::buildOpenApiSpec()` verbatim — the only change needed is widening its visibility from `private` to `public` so `Registry::create()` (a different class) can call `$server->buildOpenApiSpec()` once at construction time and cache the resulting array on `$registry->openapi`. Same `:param` → `{param}` conversion, same path-vs-query parameter inference from `cachedSchema`, same `requestBody` generation for non-GET routes. Built once, not per-request — same as Node computing it once inside `createRegistry()` rather than regenerating it on every `/openapi.json` hit.

- **No auth hook.** Nothing like this exists in `Server.php` today either — sandboxing (`permissions.fs`/`permissions.network`/`permissions.exec`) is a per-tool execution concern (see `php/src/Sandbox.php`), not an HTTP auth layer. Registry adds none; auth is the caller's framework's concern (Slim middleware, Laravel guards, API Gateway authorizers), same as Node.

### Non-goals

- Does not replace or call into `Server::serve()` / `Server::serveHttp()` — the CLI entry point (`php zeromcp.php serve`) is unchanged and still does its own inline `/mcp`, route, `/openapi.json`, `/docs` handling against `$_SERVER`/`php://input`.
- Does not do HTTP routing, query-string/body parsing, or response writing — `routes` hands back `RouteDefinition` data, not wired handlers.
- Does not depend on any HTTP framework or router (no Slim/Laravel/PSR-7 types imported by `Registry.php` itself — the usage sketch above is illustrative, not a dependency).
- Does not scan directories or read `zeromcp.config.json` — `Registry::create()` only ever sees the `$tools` array and `$options` values a caller passes in.

## Packaging

- New file: `php/src/Registry.php` (`Registry` + `RouteDefinition` classes, namespace `ZeroMcp`).
- Modified `php/src/Server.php`:
  - add `Server::fromTools(array $tools, ?Config $config = null, ?callable $getEnv = null): self` static factory,
  - change `buildOpenApiSpec()` visibility from `private` to `public`,
  - add `private ?\Closure $envOverride = null;` and check it first in `resolveCredentials()`.
  - No change to `serve()`, `serveHttp()`, `handleRequest()`, or any existing call path's behavior when these new pieces aren't used.
- Modified `php/src/Tool.php`: add `Tool::fromDefinition(string $name, array $def): self` static factory (mapping logic moved here from `Scanner::loadTool()`).
- Modified `php/src/Scanner.php`: `loadTool()` calls `Tool::fromDefinition()` instead of duplicating the array→`Tool` mapping inline.
- No new Composer dependencies — `composer.json`'s `require` stays `{"php": ">=8.1"}` only, consistent with the "no Composer, no extensions" pitch in `php/README.md`.
- No `composer.json` autoload changes needed: PSR-4 already maps `ZeroMcp\` → `src/` (`autoload.psr-4` in `php/composer.json`), so `Registry.php` and the new `RouteDefinition` class are picked up automatically.
- Consumers use it as `use ZeroMcp\Registry; use ZeroMcp\Tool; $registry = Registry::create($tools);`.

## Porting notes / judgment calls made for this port

1. **No separate dispatch module to import from.** Node's `registry.ts` imports `createState`/`handleRequest` from an already-decoupled `dispatch.ts`; PHP's `Server.php` is one monolithic class with no such split. "Reuse, don't duplicate" in PHP therefore means adding a `fromTools()` factory and widening one method's visibility on `Server`, rather than importing from a module that was already framework/transport-agnostic. This is a smaller change than it sounds (`Server.php` was already structured so `$tools` is the only state `handleRequest()`/`buildOpenApiSpec()` actually need — resources/prompts/subscriptions are separate fields that simply stay empty).
2. **`get_env` had no direct target.** Node's `TEnv` is a free type parameter threaded straight into `execute(args, env)`. PHP's `Tool::call()` takes a concrete `?Context $ctx`, and `Context::$credentials` is the closest existing slot for "an opaque value the tool needs." Rather than changing `Tool`'s signature (which would ripple into `Scanner`, `Sandbox`, and every existing tool file's `execute` closure), this spec adds a narrow `$envOverride` seam inside `Server::resolveCredentials()` so `get_env`'s value flows into `Context::$credentials` only for registry-built servers, leaving `Config::$credentials`-based namespace resolution untouched for `serve()`/`serveHttp()`.
3. **Accepting both `Tool` objects and raw definition arrays in `Registry::create()`.** Node's `Record<string, Tool>` is objects only. PHP's own file convention is array literals (`return ['description'=>.., 'execute'=>..]`), and that's the shape a PHP engineer will reach for first when defining a tool inline for embedding rather than in a file. This spec has Registry accept either (normalized via the new `Tool::fromDefinition()`) as the more idiomatic choice — open question for the implementer: restrict to `Tool` objects only for stricter parity with Node's typed map, if preferred. Either is a small change since `fromDefinition()` exists either way.
4. **`RouteDefinition->tool` exposes the full `Tool` object**, not a narrower view — `Tool` in PHP is already a plain public-property class (`cachedSchema`, `permissions`, everything visible), unlike Node's `Tool<TEnv>` interface which the registry module defines its own narrower shape for. No slimming needed.
5. **Pre-existing `null`-`$ctx` route dispatch in `serveHttp()` is not a precedent Registry follows.** Today, `serveHttp()`'s inline route handling calls `$tool->call($args)` with no `Context` at all. `Registry`'s `routes` array is inert data — it doesn't call `->call()` on anything — so this asymmetry in the existing built-in server doesn't need to be resolved or matched; it's simply out of scope, same as Node's registry not caring how `server.ts` invokes routes internally.

## Fixed: existing `buildOpenApiSpec()` had the same non-GET path-param bug as Node

Auditing all 10 languages for the Node bug above (see `specs/lang/nodejs/registry.md`'s "Fixed since the original as-built version" section, and the identical finding for Swift in `specs/lang/swift/registry.md`) found the exact same bug already shipped in PHP's own `buildOpenApiSpec()` (`php/src/Server.php`, private method starting line 142, pre-dating this registry spec entirely — it's used by `serveHttp()`'s `/openapi.json` route today). For a non-GET route with a `:param` segment (e.g. `PUT /items/:id`), the `else` branch (`Server.php:185-191`, prior to this fix) built `requestBody`'s schema from the entire `$inputSchema` — every property including path-param ones — and never emitted a `parameters` array for them at all: `:id` was undocumented as a path parameter and silently duplicated into the JSON request body schema instead.

**Fixed directly** (not just specified) in `Server.php`'s `else` branch (now `Server.php:185-216`): it filters `$pathParamNames` out of both `$properties` (via `array_diff_key($properties, array_flip($pathParamNames))`) and `$required` (via `array_values(array_diff($required, $pathParamNames))`) to build a filtered body schema (`{'type' => 'object', 'properties' => ..., 'required' => ...}`, with `'required'` omitted when empty, matching this file's existing convention), and — when `$pathParamNames` is non-empty — adds a `parameters` array documenting each as `['name' => $name, 'in' => 'path', 'required' => true, 'schema' => ['type' => 'string']]`, matching the GET branch's existing path-parameter shape immediately above it. `requestBody['required'] => true` was also added, a small separate pre-existing gap noticed while touching this block (every other language's requestBody already marks itself required). The GET branch (`Server.php:171-184`) was already correct and is untouched.

Verified with the existing custom test runner (`php tests/ServerTest.php`, invoked via `php tests/ConfigTest.php`, `php tests/PaginationTest.php`, `php tests/ScannerTest.php`, `php tests/SchemaTest.php`, `php tests/ServerTest.php` — this codebase has no PHPUnit-based suite despite `composer.json`'s `require-dev`; each `tests/*Test.php` is a standalone script with its own `run()`/`assert()` loop). Added `testOpenApiNonGetRoutePathParam()` to `php/tests/ServerTest.php`, backed by a new fixture tool `php/tests/fixtures/tools/update_item.php` (`PUT /items/:id`, `input => ['id' => 'string', 'name' => 'string']`), invoking the still-private `buildOpenApiSpec()` via `\ReflectionMethod` and asserting: the `PUT /items/{id}` operation has exactly one `parameters` entry (`id`, `in: path`, `required: true`, `schema: {type: string}`); `requestBody.required === true`; the body schema's `properties` excludes `id` but keeps `name`; and the body schema's `required` list excludes `id`. All 190 assertions across the five test files pass (77 in `ServerTest.php` alone, up from 70).

This means the PHP port's reuse of `buildOpenApiSpec()` (`openapi` field, "Behavior" above) now gets the corrected behavior for free — no divergent logic for the registry to carry, same conclusion as the Swift port.
