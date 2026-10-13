#!/usr/bin/env node
/**
 * Route + OpenAPI conformance harness for Node.js.
 *
 * ZeroMCP no longer ships an HTTP server; this is the "your own server" a user
 * would write. It mounts createRegistry (routes, OpenAPI, MCP handler) on
 * node:http, on port 14250 unless PORT is set.
 */
import { createServer } from 'node:http';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..', '..', '..');
const { createRegistry } = await import(join(root, 'nodejs/dist/registry.js'));
const { default: greet } = await import(join(root, 'tests/conformance/route-tools/greet.js'));
const { default: echo } = await import(join(root, 'tests/conformance/route-tools/echo.js'));

const PORT = Number(process.env.PORT || 14250);
const registry = await createRegistry({ greet, echo });

const SWAGGER_HTML = `<!DOCTYPE html>
<html>
<head><title>ZeroMCP API</title><meta charset="utf-8"/>
<link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist/swagger-ui.css"></head>
<body><div id="swagger-ui"></div>
<script src="https://unpkg.com/swagger-ui-dist/swagger-ui-bundle.js"></script>
<script>SwaggerUIBundle({ url: '/openapi.json', dom_id: '#swagger-ui' })</script>
</body></html>`;

function match(pattern, pathname) {
  const p = pattern.split('/');
  const a = pathname.split('/');
  if (p.length !== a.length) return null;
  const params = {};
  for (let i = 0; i < p.length; i++) {
    if (p[i].startsWith(':')) params[p[i].slice(1)] = decodeURIComponent(a[i]);
    else if (p[i] !== a[i]) return null;
  }
  return params;
}

async function readJson(req) {
  let body = '';
  for await (const chunk of req) body += chunk;
  try { return JSON.parse(body); } catch { return undefined; }
}

function send(res, data, status = 200) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(data));
}

createServer(async (req, res) => {
  const url = new URL(req.url || '/', `http://localhost:${PORT}`);

  if (req.method === 'GET' && url.pathname === '/openapi.json') return send(res, registry.openapi);
  if (req.method === 'GET' && url.pathname === '/docs') {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    return res.end(SWAGGER_HTML);
  }
  if (req.method === 'POST' && url.pathname === '/mcp') {
    const body = await readJson(req);
    const response = await registry.mcp(body ?? { jsonrpc: '2.0', method: '' });
    return send(res, response ?? { jsonrpc: '2.0', result: {} });
  }

  for (const route of registry.routes) {
    if (route.method.toUpperCase() !== req.method) continue;
    const params = match(route.path, url.pathname);
    if (params === null) continue;
    try {
      let args = { ...params };
      if (req.method === 'GET') {
        for (const [k, v] of url.searchParams) args[k] = v;
      } else {
        const body = await readJson(req);
        if (body && typeof body === 'object' && !Array.isArray(body)) args = { ...args, ...body };
      }
      return send(res, { ok: true, result: await route.tool.execute(args, {}) });
    } catch (err) {
      return send(res, { ok: false, error: err.message }, 500);
    }
  }

  send(res, { error: 'Not found' }, 404);
}).listen(PORT, () => console.error(`[route-harness] listening on ${PORT}`));
