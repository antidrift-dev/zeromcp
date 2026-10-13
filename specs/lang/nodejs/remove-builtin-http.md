# Remove the built-in HTTP server — Node.js

## Status
Done (2026-10-13). Docker: `npm test` 163/163 (was 160; 3 new in `test/http-removed.test.js`); conformance Node.js passes all 12 stdio suites as before, Route 5/5 and HTTP no-auth 1/1 via harnesses in `tests/conformance/harness/nodejs/`; HTTP auth row removed as specced.

## Why
ZeroMCP doesn't own the HTTP layer. Users run whatever HTTP server they already have and wire ZeroMCP in. `createHandler` (`@antidrift/zeromcp/handler`) and `createRegistry` (`@antidrift/zeromcp/registry`: routes, OpenAPI, MCP handler as plain data) already cover that. The `node:http` server inside `serve()` is the one piece where the package owns a listener.

## Remove
- `startHttp` (`nodejs/src/server.ts:148-222`): the `node:http` listener, CORS headers (`:152-156`), bearer auth (`:149`, `:158-164`), `/health` (`:168-171`), `/mcp` (`:173-178`), `/openapi.json` (`:180-184`), `/docs` (`:186-190`), tool route dispatch (`:192-214`), default port 4242 (`:91`). It is not exported; it is reached only through `serve()` with an `http` transport.
- Helpers used only by it: `SWAGGER_HTML` (`server.ts:133-146`), `matchRoute` (`:224-237`), `parseBody` (`:239-249`), `json` (`:251-254`). Grep shows no other caller in `src/` or `bin/`. The registry does no route matching (`registry.ts:67-74`), so `matchRoute` is not needed there.
- Imports in `server.ts` that go with it: `createServer` from `node:http` (`:2`), `resolveAuth` (`:7`), `buildOpenApiSpec` (`:9`).
- The `http` branch and `hasHttp` in `serve()` (`server.ts:85`, `:90-92`), and the `httpAlso` parameter of `startStdio` (`:89`, `:103`, `:129`): stdin close always exits.
- `TransportConfig.port` and `TransportConfig.auth`, and `'http'` from `TransportConfig.type` (`nodejs/src/config.ts:22-26`). The type becomes `{ type: 'stdio' }`.
- CLI: the `port: 4242` mapping (`nodejs/bin/mcp.js:61`) and `[stdio|http]` in the usage line (`:13`, becomes `[stdio]`). `http` stays in the reserved keyword set (`:37`, `:58`) so `zeromcp serve http` reaches the startup error below instead of being read as a tools directory.
- README: the `{ "type": "http", "port": 4242, "auth": "env:TOKEN" }` entry in the Configuration example (`nodejs/README.md:181-184`). Drop the whole `transport` key from the example; stdio is the default (`config.ts:111`).
- `specs/lang/nodejs/registry.md`: the sentences that describe the built-in server as current (`:9`, `:13`, `:72`, and the `server.ts` mentions in `:65`, `:67`). Reword to past tense or drop.

## Add: startup error
- At the top of `serve()` (`server.ts:11`), after the config is loaded and before remotes connect or tools are scanned: run `resolveTransports(config)` and, if any entry's `type` is not `'stdio'`, throw:
  `The built-in HTTP transport was removed. Mount createHandler ('@antidrift/zeromcp/handler') or createRegistry ('@antidrift/zeromcp/registry') in your own HTTP server.`
  No fallback to stdio.
- `bin/mcp.js:66` calls `serve(config)` without `await` or `.catch`. Change it to `serve(config).catch(err => { console.error(`[zeromcp] ${err.message}`); process.exit(1); })` so the CLI prints the message and exits 1 instead of dumping an unhandled rejection.

## Keep
- `serve()` with stdio, `startStdio`, `createHandler` (`handler.ts`), `createRegistry` (`registry.ts`).
- `nodejs/src/openapi.ts` / `buildOpenApiSpec`: the registry uses it (`registry.ts:4`, `:87`). It stays where it is.
- `resolveAuth` (`config.ts:153-166`): `remote.ts:49` uses it for remote-server auth.
- `resolveTransports` (`config.ts:110-114`): used by the new startup check.
- README's "HTTP / Streamable HTTP" section (`nodejs/README.md:31-86`): already uses `createHandler`. Add one line under it pointing at `createRegistry` for REST routes and OpenAPI (it is currently only described under Programmatic API, `:172`).
- Dependencies: none change. `package.json` has no runtime dependencies; `node:http` is built in.

## Breaking change
`npm view @antidrift/zeromcp` lists 0.1.0 through 0.3.0, latest 0.3.0. The 0.3.0 tarball (`npm pack`) contains `startHttp` with `createServer` in `dist/server.js:136-138` and the `http` → port 4242 mapping in `bin/mcp.js:61`. Removing it breaks anyone running `zeromcp serve http` or a config with an `http` transport. Note it in the next release's changelog with the replacement: mount `createHandler` or `createRegistry` in your own server.

## Tests
- Unit: no test in `nodejs/test/` exercises the HTTP server. Grep for `'http'`, `transport`, `/openapi.json`, `/health` hits only `template.test.js:85-93`, which is a `resource:///health` URI, not HTTP. `e2e.test.js:24` uses stdio. Nothing to delete or move.
- Unit, add: `serve({ transport: { type: 'http' } })` rejects with a message containing `createRegistry`; and `node bin/mcp.js serve http` exits 1 with that message on stderr (same spawn pattern as `e2e.test.js`).
- `tests/conformance/run-route.js:18-24`: the Node entry starts `bin/mcp.js serve` with `route-config-node.json` (http on 14250). Replace it with a test-only harness, `tests/conformance/node-route-harness.mjs`, that imports `route-tools/greet.js` and `route-tools/echo.js`, passes them to `createRegistry` from `nodejs/dist/registry.js`, and serves on `node:http` port 14250: each `registry.routes` entry (with its own small `:param` matcher; GET args from path + query, other methods from path + JSON body; respond `{ ok: true, result }` or `{ ok: false, error }` 500), `GET /openapi.json` → `registry.openapi`, `POST /mcp` → `registry.mcp`, and `GET /docs` → a minimal swagger-ui page, because the shared test checks it (`run-route.js:172-178`). Delete `route-config-node.json`.
- `tests/conformance/run-http.js`: the Node auth entry (`:18-25`, `http-config-node.json`) tests bearer auth and CORS on the built-in server (`:86-158`). Both are now the user's server's job, so a harness would only test itself: remove the Node entry and delete `http-config-node.json`. The Node no-auth entry (`:36-44`, `http-config-node-noauth.json`) checks `initialize` over `/mcp`: point it at a harness that mounts `createHandler(nodejs/examples/tools)` on `node:http` port 14244 (`/mcp` only), the way `tests/performance/run-mixed-docker.mjs:25-43` already does. Delete `http-config-node-noauth.json`.
- No change: `tests/chaos/run-chaos.js:380-382` runs Node over stdio. `tests/chaos/chaos-http.mjs` launches no server. `tests/performance/run-mixed-docker.mjs:25-43` and `run-mixed-all.mjs` already mount `createHandler` on their own `node:http`. The root `Dockerfile` builds no Node example (grep for `npm`/`nodejs` hits only the Node install at `:10-12`).
- Unverified: `tests/performance/run-zeromcp-overnight.sh:38-40` and `rerun-zeromcp-cold-tiers.sh:36` run `server-bare.mjs` in an image `zeromcp-bench-http-node` that isn't built anywhere in this repo. What that server uses could not be checked.

## Verify
The root `Dockerfile` has no Node build step and there is no `.dockerignore`, so `COPY . .` (`Dockerfile:60`) brings in whatever `nodejs/dist` is on the host. Rebuild inside the container (`npm ci` runs `prepare` → `tsc`):
```sh
docker build -t zeromcp-tests .
docker run --rm zeromcp-tests sh -c 'cd nodejs && npm ci && npm test'
docker run --rm zeromcp-tests sh -c 'cd nodejs && npm ci && cd .. && node tests/conformance/run-all.js --language "Node.js"'
docker run --rm zeromcp-tests sh -c 'cd nodejs && npm ci && cd .. && node tests/conformance/run-route.js'
docker run --rm zeromcp-tests sh -c 'cd nodejs && npm ci && cd .. && node tests/conformance/run-http.js'
grep -rn "node:http\|createServer\|listen(\|4242\|SWAGGER\|matchRoute" nodejs/src nodejs/bin   # expect nothing
```
`run-all.js` runs the HTTP and Route suites without the `--language` filter (`run-all.js:971`, `:995` check only `--suite`), so the second command also covers the harnesses; the last two isolate them.
