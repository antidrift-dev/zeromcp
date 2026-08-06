import { describe, it, mock } from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createRegistry } from '../dist/registry.js';

function tool(overrides = {}) {
  return {
    description: overrides.description || 'A tool',
    input: overrides.input || { name: 'string' },
    route: overrides.route,
    execute: overrides.execute || (async (args) => `hi ${args.name}`),
  };
}

describe('createRegistry - routes', () => {
  it('includes only tools with a route, preserving insertion order', async () => {
    const registry = await createRegistry({
      a: tool({ route: { method: 'GET', path: '/a' } }),
      b: tool(),
      c: tool({ route: { method: 'POST', path: '/c' } }),
    });
    assert.deepEqual(registry.routes.map(r => r.name), ['a', 'c']);
  });

  it('exposes name/method/path/tool on each route', async () => {
    const t = tool({ route: { method: 'GET', path: '/greet/:name' } });
    const registry = await createRegistry({ greet: t });
    assert.deepEqual(registry.routes, [{ name: 'greet', method: 'GET', path: '/greet/:name', tool: t }]);
  });

  it('warns when two tools declare the same method+path', async () => {
    const errors = [];
    const restore = console.error;
    console.error = (msg) => errors.push(msg);
    try {
      await createRegistry({
        a: tool({ route: { method: 'GET', path: '/dup' } }),
        b: tool({ route: { method: 'GET', path: '/dup' } }),
      });
    } finally {
      console.error = restore;
    }
    assert.ok(errors.some(e => e.includes('GET /dup')), `expected a collision warning, got: ${JSON.stringify(errors)}`);
  });

  it('does not warn when routes are unique', async () => {
    const errors = [];
    const restore = console.error;
    console.error = (msg) => errors.push(msg);
    try {
      await createRegistry({
        a: tool({ route: { method: 'GET', path: '/a' } }),
        b: tool({ route: { method: 'POST', path: '/a' } }),
      });
    } finally {
      console.error = restore;
    }
    assert.equal(errors.length, 0);
  });
});

describe('createRegistry - openapi', () => {
  it('documents path params for GET routes', async () => {
    const registry = await createRegistry({
      greet: tool({ input: { name: 'string' }, route: { method: 'GET', path: '/greet/:name' } }),
    });
    const op = registry.openapi.paths['/greet/{name}'].get;
    assert.deepEqual(op.parameters, [{ name: 'name', in: 'path', required: true, schema: { type: 'string' } }]);
  });

  it('documents path params for non-GET routes and excludes them from the body schema', async () => {
    const registry = await createRegistry({
      update: tool({
        input: { id: 'string', label: 'string' },
        route: { method: 'PUT', path: '/items/:id' },
      }),
    });
    const op = registry.openapi.paths['/items/{id}'].put;
    assert.deepEqual(op.parameters, [{ name: 'id', in: 'path', required: true, schema: { type: 'string' } }]);
    const bodySchema = op.requestBody.content['application/json'].schema;
    assert.deepEqual(Object.keys(bodySchema.properties), ['label']);
    assert.deepEqual(bodySchema.required, ['label']);
  });

  it('omits requestBody path param from required when it was the only required field', async () => {
    const registry = await createRegistry({
      del: tool({
        input: { id: 'string' },
        route: { method: 'DELETE', path: '/items/:id' },
      }),
    });
    const op = registry.openapi.paths['/items/{id}'].delete;
    const bodySchema = op.requestBody.content['application/json'].schema;
    assert.deepEqual(bodySchema.properties, {});
    assert.equal(bodySchema.required, undefined);
  });

  it('defaults title and version, and honors overrides', async () => {
    const defaults = await createRegistry({ a: tool({ route: { method: 'GET', path: '/a' } }) });
    assert.equal(defaults.openapi.info.title, 'ZeroMCP');
    assert.equal(defaults.openapi.info.version, '1.0.0');

    const custom = await createRegistry(
      { a: tool({ route: { method: 'GET', path: '/a' } }) },
      { title: 'My API', version: '2.3.0' },
    );
    assert.equal(custom.openapi.info.title, 'My API');
    assert.equal(custom.openapi.info.version, '2.3.0');
  });

  it('excludes tools with no route', async () => {
    const registry = await createRegistry({ hidden: tool() });
    assert.deepEqual(registry.openapi.paths, {});
  });
});

describe('createRegistry - mcp', () => {
  it('initialize reports the configured version', async () => {
    const registry = await createRegistry({}, { version: '9.9.9' });
    const resp = await registry.mcp({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} });
    assert.equal(resp.result.serverInfo.version, '9.9.9');
  });

  it('tools/list reflects registered tools', async () => {
    const registry = await createRegistry({ greet: tool() });
    const resp = await registry.mcp({ jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} });
    assert.deepEqual(resp.result.tools.map(t => t.name), ['greet']);
  });

  it('tools/call invokes execute with the env from getEnv', async () => {
    const execute = mock.fn(async (args, env) => `${args.name}-${env.tag}`);
    const registry = await createRegistry(
      { greet: tool({ execute }) },
      { getEnv: () => ({ tag: 'prod' }) },
    );
    const resp = await registry.mcp({
      jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'greet', arguments: { name: 'Ada' } },
    });
    assert.equal(resp.result.content[0].text, 'Ada-prod');
    assert.equal(execute.mock.calls.length, 1);
  });

  it('respects a custom executeTimeout', async () => {
    const registry = await createRegistry(
      { slow: tool({ execute: () => new Promise(r => setTimeout(r, 50)) }) },
      { executeTimeout: 5 },
    );
    const resp = await registry.mcp({
      jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'slow', arguments: { name: 'x' } },
    });
    assert.equal(resp.result.isError, true);
    assert.match(resp.result.content[0].text, /timed out/);
  });
});

describe('createRegistry - remote federation', () => {
  function responseFor(request) {
    if (request.method === 'initialize') return { result: { protocolVersion: '2025-03-26', capabilities: {}, serverInfo: { name: 'remote-server', version: 'test' } } };
    if (request.method === 'tools/list') {
      return { result: { tools: [{ name: 'list_pages', description: 'Lists pages.', inputSchema: { type: 'object', properties: { domain: { type: 'string' } }, required: ['domain'] } }] } };
    }
    if (request.method === 'tools/call') {
      return { result: { content: [{ type: 'text', text: JSON.stringify({ pages: [] }) }] } };
    }
    return { error: { message: `Unexpected method: ${request.method}` } };
  }

  async function startRemoteServer(t) {
    const server = createServer(async (request, response) => {
      let body = '';
      for await (const chunk of request) body += chunk;
      response.setHeader('Content-Type', 'application/json');
      response.end(JSON.stringify({ jsonrpc: '2.0', id: JSON.parse(body).id, ...responseFor(JSON.parse(body)) }));
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    t.after(() => server.close());
    return server.address();
  }

  it('merges remote tools into routes-less mcp dispatch, namespaced by server name', async (t) => {
    const address = await startRemoteServer(t);
    const registry = await createRegistry({}, {
      remote: [{ name: 'probeo', url: `http://127.0.0.1:${address.port}` }],
    });

    const listed = await registry.mcp({ jsonrpc: '2.0', id: 1, method: 'tools/list' });
    assert.equal(listed.result.tools[0].name, 'probeo.list_pages');

    const called = await registry.mcp({
      jsonrpc: '2.0', id: 2, method: 'tools/call',
      params: { name: 'probeo.list_pages', arguments: { domain: 'example.com' } },
    });
    assert.deepEqual(called.result.content, [{ type: 'text', text: JSON.stringify({ pages: [] }) }]);
  });

  it('a local tool with the same name overrides the remote one', async (t) => {
    const address = await startRemoteServer(t);
    const errors = [];
    const restore = console.error;
    console.error = (msg) => errors.push(msg);
    let registry;
    try {
      registry = await createRegistry(
        { 'probeo.list_pages': tool({ input: {}, execute: async () => 'local override' }) },
        { remote: [{ name: 'probeo', url: `http://127.0.0.1:${address.port}` }] },
      );
    } finally {
      console.error = restore;
    }
    assert.ok(errors.some(e => e.includes('probeo.list_pages') && e.includes('overrides remote')));

    const called = await registry.mcp({
      jsonrpc: '2.0', id: 1, method: 'tools/call',
      params: { name: 'probeo.list_pages', arguments: {} },
    });
    assert.equal(called.result.content[0].text, 'local override');
  });

  it('remote tools never appear in routes or openapi (no route field over MCP)', async (t) => {
    const address = await startRemoteServer(t);
    const registry = await createRegistry({}, {
      remote: [{ name: 'probeo', url: `http://127.0.0.1:${address.port}` }],
    });
    assert.deepEqual(registry.routes, []);
    assert.deepEqual(registry.openapi.paths, {});
  });
});
