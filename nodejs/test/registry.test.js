import { describe, it, mock } from 'node:test';
import assert from 'node:assert/strict';
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
  it('includes only tools with a route, preserving insertion order', () => {
    const registry = createRegistry({
      a: tool({ route: { method: 'GET', path: '/a' } }),
      b: tool(),
      c: tool({ route: { method: 'POST', path: '/c' } }),
    });
    assert.deepEqual(registry.routes.map(r => r.name), ['a', 'c']);
  });

  it('exposes name/method/path/tool on each route', () => {
    const t = tool({ route: { method: 'GET', path: '/greet/:name' } });
    const registry = createRegistry({ greet: t });
    assert.deepEqual(registry.routes, [{ name: 'greet', method: 'GET', path: '/greet/:name', tool: t }]);
  });

  it('warns when two tools declare the same method+path', () => {
    const errors = [];
    const restore = console.error;
    console.error = (msg) => errors.push(msg);
    try {
      createRegistry({
        a: tool({ route: { method: 'GET', path: '/dup' } }),
        b: tool({ route: { method: 'GET', path: '/dup' } }),
      });
    } finally {
      console.error = restore;
    }
    assert.ok(errors.some(e => e.includes('GET /dup')), `expected a collision warning, got: ${JSON.stringify(errors)}`);
  });

  it('does not warn when routes are unique', () => {
    const errors = [];
    const restore = console.error;
    console.error = (msg) => errors.push(msg);
    try {
      createRegistry({
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
  it('documents path params for GET routes', () => {
    const registry = createRegistry({
      greet: tool({ input: { name: 'string' }, route: { method: 'GET', path: '/greet/:name' } }),
    });
    const op = registry.openapi.paths['/greet/{name}'].get;
    assert.deepEqual(op.parameters, [{ name: 'name', in: 'path', required: true, schema: { type: 'string' } }]);
  });

  it('documents path params for non-GET routes and excludes them from the body schema', () => {
    const registry = createRegistry({
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

  it('omits requestBody path param from required when it was the only required field', () => {
    const registry = createRegistry({
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

  it('defaults title and version, and honors overrides', () => {
    const defaults = createRegistry({ a: tool({ route: { method: 'GET', path: '/a' } }) });
    assert.equal(defaults.openapi.info.title, 'ZeroMCP');
    assert.equal(defaults.openapi.info.version, '1.0.0');

    const custom = createRegistry(
      { a: tool({ route: { method: 'GET', path: '/a' } }) },
      { title: 'My API', version: '2.3.0' },
    );
    assert.equal(custom.openapi.info.title, 'My API');
    assert.equal(custom.openapi.info.version, '2.3.0');
  });

  it('excludes tools with no route', () => {
    const registry = createRegistry({ hidden: tool() });
    assert.deepEqual(registry.openapi.paths, {});
  });
});

describe('createRegistry - mcp', () => {
  it('initialize reports the configured version', async () => {
    const registry = createRegistry({}, { version: '9.9.9' });
    const resp = await registry.mcp({ jsonrpc: '2.0', id: 1, method: 'initialize', params: {} });
    assert.equal(resp.result.serverInfo.version, '9.9.9');
  });

  it('tools/list reflects registered tools', async () => {
    const registry = createRegistry({ greet: tool() });
    const resp = await registry.mcp({ jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} });
    assert.deepEqual(resp.result.tools.map(t => t.name), ['greet']);
  });

  it('tools/call invokes execute with the env from getEnv', async () => {
    const execute = mock.fn(async (args, env) => `${args.name}-${env.tag}`);
    const registry = createRegistry(
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
    const registry = createRegistry(
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
