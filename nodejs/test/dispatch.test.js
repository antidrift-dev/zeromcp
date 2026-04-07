import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { handleRequest, createState } from '../dist/dispatch.js';

function makeState(overrides = {}) {
  return createState({
    tools: overrides.tools || new Map(),
    executeTimeout: overrides.executeTimeout || 30000,
    version: overrides.version || '0.1.0',
    ...overrides,
  });
}

function makeTool(name, opts = {}) {
  return [name, {
    description: opts.description || `Tool ${name}`,
    input: opts.input || {},
    cachedSchema: opts.cachedSchema || { type: 'object', properties: {}, required: [] },
    execute: opts.execute || (async () => 'ok'),
    execute_timeout: opts.execute_timeout,
  }];
}

describe('handleRequest - initialize', () => {
  it('returns protocol version and server info', async () => {
    const state = makeState();
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'initialize', params: {} },
      state,
    );
    assert.equal(resp.id, 1);
    assert.equal(resp.result.protocolVersion, '2024-11-05');
    assert.equal(resp.result.serverInfo.name, 'zeromcp');
    assert.equal(resp.result.serverInfo.version, '0.1.0');
  });

  it('includes tools capability', async () => {
    const state = makeState();
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'initialize', params: {} },
      state,
    );
    assert.ok(resp.result.capabilities.tools);
    assert.equal(resp.result.capabilities.tools.listChanged, true);
  });

  it('includes logging capability', async () => {
    const state = makeState();
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'initialize', params: {} },
      state,
    );
    assert.ok('logging' in resp.result.capabilities);
  });

  it('includes resources capability when resources present', async () => {
    const resources = new Map([['r', { uri: 'resource:///r', name: 'r', mimeType: 'text/plain', read: async () => '' }]]);
    const state = makeState({ resources });
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'initialize', params: {} },
      state,
    );
    assert.ok(resp.result.capabilities.resources);
    assert.equal(resp.result.capabilities.resources.subscribe, true);
  });

  it('includes resources capability when templates present', async () => {
    const templates = new Map([['t', { uriTemplate: 'resource:///t/{id}', name: 't', mimeType: 'text/plain', read: async () => '' }]]);
    const state = makeState({ templates });
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'initialize', params: {} },
      state,
    );
    assert.ok(resp.result.capabilities.resources);
  });

  it('excludes resources capability when none present', async () => {
    const state = makeState();
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'initialize', params: {} },
      state,
    );
    assert.equal(resp.result.capabilities.resources, undefined);
  });

  it('includes prompts capability when prompts present', async () => {
    const prompts = new Map([['p', { name: 'p', render: async () => [] }]]);
    const state = makeState({ prompts });
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'initialize', params: {} },
      state,
    );
    assert.ok(resp.result.capabilities.prompts);
  });

  it('excludes prompts capability when none present', async () => {
    const state = makeState();
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'initialize', params: {} },
      state,
    );
    assert.equal(resp.result.capabilities.prompts, undefined);
  });

  it('stores client capabilities', async () => {
    const state = makeState();
    await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'initialize', params: { capabilities: { roots: {} } } },
      state,
    );
    assert.deepEqual(state.clientCapabilities, { roots: {} });
  });
});

describe('handleRequest - ping', () => {
  it('returns empty result', async () => {
    const state = makeState();
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'ping', params: {} },
      state,
    );
    assert.deepEqual(resp.result, {});
  });
});

describe('handleRequest - notifications', () => {
  it('returns null for initialized notification', async () => {
    const state = makeState();
    const resp = await handleRequest(
      { jsonrpc: '2.0', method: 'notifications/initialized' },
      state,
    );
    assert.equal(resp, null);
  });

  it('returns null for roots/list_changed notification', async () => {
    const state = makeState();
    const resp = await handleRequest(
      { jsonrpc: '2.0', method: 'notifications/roots/list_changed', params: { roots: [{ uri: 'file:///app' }] } },
      state,
    );
    assert.equal(resp, null);
    assert.deepEqual(state.roots, [{ uri: 'file:///app' }]);
  });
});

describe('handleRequest - resources/list', () => {
  it('lists resources', async () => {
    const resources = new Map([
      ['config', { uri: 'resource:///config.json', name: 'config', description: 'Config', mimeType: 'application/json', read: async () => '{}' }],
    ]);
    const state = makeState({ resources });
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'resources/list', params: {} },
      state,
    );
    assert.equal(resp.result.resources.length, 1);
    assert.equal(resp.result.resources[0].uri, 'resource:///config.json');
    assert.equal(resp.result.resources[0].mimeType, 'application/json');
  });

  it('returns empty list when no resources', async () => {
    const state = makeState();
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'resources/list', params: {} },
      state,
    );
    assert.deepEqual(resp.result.resources, []);
  });

  it('includes icon when set', async () => {
    const resources = new Map([
      ['r', { uri: 'resource:///r', name: 'r', description: 'd', mimeType: 'text/plain', read: async () => '' }],
    ]);
    const state = makeState({ resources, icon: 'data:image/png;base64,abc' });
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'resources/list', params: {} },
      state,
    );
    assert.ok(resp.result.resources[0].icons);
    assert.equal(resp.result.resources[0].icons[0].uri, 'data:image/png;base64,abc');
  });
});

describe('handleRequest - resources/read', () => {
  it('reads a static resource', async () => {
    const resources = new Map([
      ['r', { uri: 'resource:///r', name: 'r', mimeType: 'text/plain', read: async () => 'hello world' }],
    ]);
    const state = makeState({ resources });
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'resources/read', params: { uri: 'resource:///r' } },
      state,
    );
    assert.equal(resp.result.contents[0].text, 'hello world');
    assert.equal(resp.result.contents[0].mimeType, 'text/plain');
  });

  it('reads a template resource', async () => {
    const templates = new Map([
      ['user', {
        uriTemplate: 'resource:///users/{id}',
        name: 'user',
        mimeType: 'application/json',
        read: async (params) => JSON.stringify({ userId: params.id }),
      }],
    ]);
    const state = makeState({ templates });
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'resources/read', params: { uri: 'resource:///users/42' } },
      state,
    );
    const parsed = JSON.parse(resp.result.contents[0].text);
    assert.equal(parsed.userId, '42');
  });

  it('returns error for not found resource', async () => {
    const state = makeState();
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'resources/read', params: { uri: 'resource:///nope' } },
      state,
    );
    assert.ok(resp.error);
    assert.equal(resp.error.code, -32002);
  });

  it('returns error when static read throws', async () => {
    const resources = new Map([
      ['bad', { uri: 'resource:///bad', name: 'bad', mimeType: 'text/plain', read: async () => { throw new Error('read failed'); } }],
    ]);
    const state = makeState({ resources });
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'resources/read', params: { uri: 'resource:///bad' } },
      state,
    );
    assert.ok(resp.error);
    assert.equal(resp.error.code, -32603);
    assert.match(resp.error.message, /read failed/);
  });

  it('returns error when template read throws', async () => {
    const templates = new Map([
      ['bad', {
        uriTemplate: 'resource:///bad/{id}',
        name: 'bad',
        mimeType: 'text/plain',
        read: async () => { throw new Error('template error'); },
      }],
    ]);
    const state = makeState({ templates });
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'resources/read', params: { uri: 'resource:///bad/1' } },
      state,
    );
    assert.ok(resp.error);
    assert.equal(resp.error.code, -32603);
  });
});

describe('handleRequest - resources/subscribe', () => {
  it('subscribes to a resource URI', async () => {
    const state = makeState();
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'resources/subscribe', params: { uri: 'resource:///r' } },
      state,
    );
    assert.deepEqual(resp.result, {});
    assert.ok(state.subscriptions.has('resource:///r'));
  });
});

describe('handleRequest - resources/templates/list', () => {
  it('lists templates', async () => {
    const templates = new Map([
      ['user', {
        uriTemplate: 'resource:///users/{id}',
        name: 'user',
        description: 'User by ID',
        mimeType: 'application/json',
        read: async () => '',
      }],
    ]);
    const state = makeState({ templates });
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'resources/templates/list', params: {} },
      state,
    );
    const items = resp.result.resourceTemplates;
    assert.equal(items.length, 1);
    assert.equal(items[0].uriTemplate, 'resource:///users/{id}');
  });

  it('includes icon on templates', async () => {
    const templates = new Map([
      ['t', { uriTemplate: 'resource:///t/{x}', name: 't', mimeType: 'text/plain', read: async () => '' }],
    ]);
    const state = makeState({ templates, icon: 'data:image/png;base64,xyz' });
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'resources/templates/list', params: {} },
      state,
    );
    assert.ok(resp.result.resourceTemplates[0].icons);
  });
});

describe('handleRequest - prompts/list', () => {
  it('lists prompts with description and arguments', async () => {
    const prompts = new Map([
      ['greeting', {
        name: 'greeting',
        description: 'Greet someone',
        arguments: [{ name: 'name', required: true }],
        render: async () => [],
      }],
    ]);
    const state = makeState({ prompts });
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'prompts/list', params: {} },
      state,
    );
    const items = resp.result.prompts;
    assert.equal(items.length, 1);
    assert.equal(items[0].name, 'greeting');
    assert.equal(items[0].description, 'Greet someone');
    assert.ok(items[0].arguments);
  });

  it('omits description and arguments when not set', async () => {
    const prompts = new Map([
      ['p', { name: 'p', render: async () => [] }],
    ]);
    const state = makeState({ prompts });
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'prompts/list', params: {} },
      state,
    );
    const item = resp.result.prompts[0];
    assert.equal(item.description, undefined);
    assert.equal(item.arguments, undefined);
  });

  it('includes icon on prompts', async () => {
    const prompts = new Map([
      ['p', { name: 'p', description: 'desc', render: async () => [] }],
    ]);
    const state = makeState({ prompts, icon: 'data:image/png;base64,abc' });
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'prompts/list', params: {} },
      state,
    );
    assert.ok(resp.result.prompts[0].icons);
  });
});

describe('handleRequest - prompts/get', () => {
  it('renders a prompt', async () => {
    const prompts = new Map([
      ['greeting', {
        name: 'greeting',
        render: async (args) => [{ role: 'user', content: { type: 'text', text: `Hi ${args.name}` } }],
      }],
    ]);
    const state = makeState({ prompts });
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'prompts/get', params: { name: 'greeting', arguments: { name: 'Alice' } } },
      state,
    );
    assert.equal(resp.result.messages.length, 1);
    assert.match(resp.result.messages[0].content.text, /Alice/);
  });

  it('returns error for not found prompt', async () => {
    const state = makeState();
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'prompts/get', params: { name: 'nope' } },
      state,
    );
    assert.ok(resp.error);
    assert.equal(resp.error.code, -32002);
  });

  it('returns error when render throws', async () => {
    const prompts = new Map([
      ['bad', {
        name: 'bad',
        render: async () => { throw new Error('render failed'); },
      }],
    ]);
    const state = makeState({ prompts });
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'prompts/get', params: { name: 'bad' } },
      state,
    );
    assert.ok(resp.error);
    assert.equal(resp.error.code, -32603);
    assert.match(resp.error.message, /render failed/);
  });

  it('handles missing arguments param', async () => {
    const prompts = new Map([
      ['simple', {
        name: 'simple',
        render: async (args) => [{ role: 'user', content: { type: 'text', text: 'no args' } }],
      }],
    ]);
    const state = makeState({ prompts });
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'prompts/get', params: { name: 'simple' } },
      state,
    );
    assert.equal(resp.result.messages[0].content.text, 'no args');
  });
});

describe('handleRequest - logging/setLevel', () => {
  it('sets the log level', async () => {
    const state = makeState();
    assert.equal(state.logLevel, 'info');
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'logging/setLevel', params: { level: 'debug' } },
      state,
    );
    assert.deepEqual(resp.result, {});
    assert.equal(state.logLevel, 'debug');
  });

  it('keeps level unchanged when no level param', async () => {
    const state = makeState();
    await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'logging/setLevel', params: {} },
      state,
    );
    assert.equal(state.logLevel, 'info');
  });
});

describe('handleRequest - completion/complete', () => {
  it('returns empty values', async () => {
    const state = makeState();
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'completion/complete', params: {} },
      state,
    );
    assert.deepEqual(resp.result.completion.values, []);
  });
});

describe('handleRequest - tools/list with pagination', () => {
  function makeToolsMap(count) {
    const map = new Map();
    for (let i = 0; i < count; i++) {
      map.set(...makeTool(`tool_${i}`, { description: `Tool ${i}` }));
    }
    return map;
  }

  it('returns all tools when no pagination', async () => {
    const tools = makeToolsMap(3);
    const state = makeState({ tools });
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} },
      state,
    );
    assert.equal(resp.result.tools.length, 3);
    assert.equal(resp.result.nextCursor, undefined);
  });

  it('paginates tools when pageSize set', async () => {
    const tools = makeToolsMap(5);
    const state = makeState({ tools, pageSize: 2 });
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} },
      state,
    );
    assert.equal(resp.result.tools.length, 2);
    assert.ok(resp.result.nextCursor);
  });

  it('full traversal with pagination collects all tools', async () => {
    const tools = makeToolsMap(5);
    const state = makeState({ tools, pageSize: 2 });
    const allNames = [];
    let cursor;
    for (let i = 0; i < 10; i++) {
      const params = cursor ? { cursor } : {};
      const resp = await handleRequest(
        { jsonrpc: '2.0', id: 1, method: 'tools/list', params },
        state,
      );
      for (const t of resp.result.tools) allNames.push(t.name);
      cursor = resp.result.nextCursor;
      if (!cursor) break;
    }
    assert.equal(allNames.length, 5);
  });

  it('includes icon on tools when set', async () => {
    const tools = makeToolsMap(1);
    const state = makeState({ tools, icon: 'data:image/png;base64,abc' });
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} },
      state,
    );
    assert.ok(resp.result.tools[0].icons);
  });
});

describe('handleRequest - tools/call', () => {
  it('calls a tool successfully', async () => {
    const tools = new Map();
    tools.set(...makeTool('echo', {
      execute: async (args) => `echo: ${args.msg}`,
      input: { msg: 'string' },
      cachedSchema: { type: 'object', properties: { msg: { type: 'string' } }, required: ['msg'] },
    }));
    const state = makeState({ tools });
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'echo', arguments: { msg: 'hi' } } },
      state,
    );
    assert.equal(resp.result.content[0].text, 'echo: hi');
    assert.equal(resp.result.isError, undefined);
  });

  it('returns JSON for non-string results', async () => {
    const tools = new Map();
    tools.set(...makeTool('obj', { execute: async () => ({ key: 'val' }) }));
    const state = makeState({ tools });
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'obj', arguments: {} } },
      state,
    );
    const parsed = JSON.parse(resp.result.content[0].text);
    assert.equal(parsed.key, 'val');
  });

  it('returns error for unknown tool', async () => {
    const state = makeState();
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'nope', arguments: {} } },
      state,
    );
    assert.equal(resp.result.isError, true);
    assert.match(resp.result.content[0].text, /Unknown tool/);
  });

  it('returns validation error', async () => {
    const tools = new Map();
    tools.set(...makeTool('strict', {
      input: { name: 'string' },
      cachedSchema: { type: 'object', properties: { name: { type: 'string' } }, required: ['name'] },
    }));
    const state = makeState({ tools });
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'strict', arguments: {} } },
      state,
    );
    assert.equal(resp.result.isError, true);
    assert.match(resp.result.content[0].text, /Validation errors/);
  });

  it('returns error when execute throws', async () => {
    const tools = new Map();
    tools.set(...makeTool('fail', {
      execute: async () => { throw new Error('boom'); },
    }));
    const state = makeState({ tools });
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'fail', arguments: {} } },
      state,
    );
    assert.equal(resp.result.isError, true);
    assert.match(resp.result.content[0].text, /boom/);
  });

  it('handles missing arguments param', async () => {
    const tools = new Map();
    tools.set(...makeTool('noargs', { execute: async () => 'done' }));
    const state = makeState({ tools });
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'noargs' } },
      state,
    );
    assert.equal(resp.result.content[0].text, 'done');
  });
});

describe('handleRequest - unknown method', () => {
  it('returns method not found error', async () => {
    const state = makeState();
    const resp = await handleRequest(
      { jsonrpc: '2.0', id: 1, method: 'unknown/method', params: {} },
      state,
    );
    assert.ok(resp.error);
    assert.equal(resp.error.code, -32601);
    assert.match(resp.error.message, /Method not found/);
  });
});

describe('handleRequest - null/invalid input', () => {
  it('returns null for null request', async () => {
    const state = makeState();
    const resp = await handleRequest(null, state);
    assert.equal(resp, null);
  });

  it('returns null for non-object request', async () => {
    const state = makeState();
    const resp = await handleRequest('bad', state);
    assert.equal(resp, null);
  });
});
