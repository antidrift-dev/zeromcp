/**
 * Tests for template matching logic via resources/read dispatch.
 * matchTemplate is internal to dispatch.ts, so we test it through handleRequest.
 */
import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { handleRequest, createState } from '../dist/dispatch.js';

function makeStateWithTemplate(uriTemplate) {
  const templates = new Map([
    ['tmpl', {
      uriTemplate,
      name: 'tmpl',
      mimeType: 'text/plain',
      read: async (params) => JSON.stringify(params),
    }],
  ]);
  return createState({
    tools: new Map(),
    executeTimeout: 30000,
    version: '0.1.0',
    templates,
  });
}

async function readUri(state, uri) {
  return handleRequest(
    { jsonrpc: '2.0', id: 1, method: 'resources/read', params: { uri } },
    state,
  );
}

describe('template matching - single param', () => {
  it('matches single parameter', async () => {
    const state = makeStateWithTemplate('resource:///users/{id}');
    const resp = await readUri(state, 'resource:///users/42');
    assert.ok(resp.result);
    const params = JSON.parse(resp.result.contents[0].text);
    assert.equal(params.id, '42');
  });
});

describe('template matching - multiple params', () => {
  it('matches multiple parameters', async () => {
    const state = makeStateWithTemplate('resource:///users/{user_id}/posts/{post_id}');
    const resp = await readUri(state, 'resource:///users/5/posts/99');
    assert.ok(resp.result);
    const params = JSON.parse(resp.result.contents[0].text);
    assert.equal(params.user_id, '5');
    assert.equal(params.post_id, '99');
  });
});

describe('template matching - no match', () => {
  it('does not match wrong prefix', async () => {
    const state = makeStateWithTemplate('resource:///users/{id}');
    const resp = await readUri(state, 'resource:///items/42');
    assert.ok(resp.error);
    assert.equal(resp.error.code, -32002);
  });

  it('does not match extra segments', async () => {
    const state = makeStateWithTemplate('resource:///users/{id}');
    const resp = await readUri(state, 'resource:///users/42/extra');
    assert.ok(resp.error);
  });

  it('does not match missing segment', async () => {
    const state = makeStateWithTemplate('resource:///users/{id}/profile');
    const resp = await readUri(state, 'resource:///users/42');
    assert.ok(resp.error);
  });

  it('does not match empty segment', async () => {
    const state = makeStateWithTemplate('resource:///users/{id}');
    const resp = await readUri(state, 'resource:///users/');
    assert.ok(resp.error);
  });
});

describe('template matching - literal only', () => {
  it('literal template without params does not match (matchTemplate requires named groups)', async () => {
    // matchTemplate returns null when there are no named capture groups,
    // so a literal-only template won't resolve via the template path.
    const state = makeStateWithTemplate('resource:///health');
    const resp = await readUri(state, 'resource:///health');
    // No match because matchTemplate requires groups
    assert.ok(resp.error);
    assert.equal(resp.error.code, -32002);
  });

  it('does not match different literal', async () => {
    const state = makeStateWithTemplate('resource:///health');
    const resp = await readUri(state, 'resource:///status');
    assert.ok(resp.error);
  });
});

describe('template matching - edge cases', () => {
  it('matches param with special characters', async () => {
    const state = makeStateWithTemplate('resource:///files/{name}');
    const resp = await readUri(state, 'resource:///files/my-file_v2');
    assert.ok(resp.result);
    const params = JSON.parse(resp.result.contents[0].text);
    assert.equal(params.name, 'my-file_v2');
  });

  it('matches param with dots', async () => {
    const state = makeStateWithTemplate('resource:///files/{name}');
    const resp = await readUri(state, 'resource:///files/doc.txt');
    assert.ok(resp.result);
    const params = JSON.parse(resp.result.contents[0].text);
    assert.equal(params.name, 'doc.txt');
  });

  it('static resource takes priority over template', async () => {
    // If a static resource matches the URI, it should be returned
    const resources = new Map([
      ['r', { uri: 'resource:///users/special', name: 'r', mimeType: 'text/plain', read: async () => 'static hit' }],
    ]);
    const templates = new Map([
      ['t', {
        uriTemplate: 'resource:///users/{id}',
        name: 't',
        mimeType: 'text/plain',
        read: async (params) => `template ${params.id}`,
      }],
    ]);
    const state = createState({
      tools: new Map(),
      executeTimeout: 30000,
      version: '0.1.0',
      resources,
      templates,
    });
    const resp = await readUri(state, 'resource:///users/special');
    assert.ok(resp.result);
    assert.equal(resp.result.contents[0].text, 'static hit');
  });
});
