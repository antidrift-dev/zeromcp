import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import test from 'node:test';
import { createHandler } from '../dist/handler.js';

function responseFor(request) {
  if (request.method === 'initialize') return { result: { protocolVersion: '2025-03-26', capabilities: {}, serverInfo: { name: 'probeo', version: 'test' } } };
  if (request.method === 'tools/list') {
    return { result: { tools: [{ name: 'list_pages', description: 'Lists pages.', inputSchema: { type: 'object', properties: { domain: { type: 'string' } }, required: ['domain'] } }] } };
  }
  if (request.method === 'tools/call') {
    return { result: { content: [{ type: 'text', text: JSON.stringify({ pages: [] }) }] } };
  }
  return { error: { message: `Unexpected method: ${request.method}` } };
}

test('createHandler composes configured remote tools', async (t) => {
  const server = createServer(async (request, response) => {
    let body = '';
    for await (const chunk of request) body += chunk;
    response.setHeader('Content-Type', 'application/json');
    response.end(JSON.stringify({ jsonrpc: '2.0', id: JSON.parse(body).id, ...responseFor(JSON.parse(body)) }));
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  t.after(() => server.close());
  const address = server.address();
  const handler = await createHandler({ tools: [], remote: [{ name: 'probeo', url: `http://127.0.0.1:${address.port}` }] });

  const listed = await handler({ jsonrpc: '2.0', id: 1, method: 'tools/list' });
  assert.equal(listed.result.tools[0].name, 'probeo.list_pages');

  const called = await handler({ jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'probeo.list_pages', arguments: { domain: 'example.com' } } });
  assert.deepEqual(called.result.content, [{ type: 'text', text: JSON.stringify({ pages: [] }) }]);
});
