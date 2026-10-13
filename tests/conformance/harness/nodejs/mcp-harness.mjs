#!/usr/bin/env node
/**
 * HTTP conformance harness for Node.js: createHandler mounted at POST /mcp on
 * node:http (port 14244 unless PORT is set). Stands in for the user's own
 * server now that ZeroMCP ships none.
 */
import { createServer } from 'node:http';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, '..', '..', '..', '..');
const { createHandler } = await import(join(root, 'nodejs/dist/handler.js'));

const PORT = Number(process.env.PORT || 14244);
const handler = await createHandler({ tools: [join(root, 'nodejs/examples/tools')] });

createServer(async (req, res) => {
  if (req.method === 'POST' && req.url === '/mcp') {
    let body = '';
    for await (const chunk of req) body += chunk;
    let request;
    try { request = JSON.parse(body); } catch { request = { jsonrpc: '2.0', method: '' }; }
    const response = await handler(request);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify(response ?? { jsonrpc: '2.0', result: {} }));
  }
  res.writeHead(404, { 'Content-Type': 'application/json' });
  res.end('{"error":"Not found"}');
}).listen(PORT, () => console.error(`[mcp-harness] listening on ${PORT}`));
