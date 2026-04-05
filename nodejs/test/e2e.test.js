import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const BIN = resolve(__dirname, '../bin/mcp.js');
const TOOLS = resolve(__dirname, '../examples/tools');

function sendRequest(proc, request) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error('Timeout')), 5000);
    proc.stdout.once('data', (data) => {
      clearTimeout(timeout);
      resolve(JSON.parse(data.toString().trim()));
    });
    proc.stdin.write(JSON.stringify(request) + '\n');
  });
}

describe('MCP server e2e', () => {
  it('handles initialize, list, and call', async () => {
    const proc = spawn('node', [BIN, 'serve', TOOLS], {
      stdio: ['pipe', 'pipe', 'pipe'],
    });

    // Give it a moment to load tools
    await new Promise((r) => setTimeout(r, 500));

    // Initialize
    const initRes = await sendRequest(proc, {
      jsonrpc: '2.0',
      id: 1,
      method: 'initialize',
      params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'test', version: '1.0' } },
    });
    assert.equal(initRes.result.protocolVersion, '2024-11-05');
    assert.equal(initRes.result.serverInfo.name, 'zeromcp');

    // Send initialized notification
    proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');

    // List tools
    const listRes = await sendRequest(proc, {
      jsonrpc: '2.0',
      id: 2,
      method: 'tools/list',
      params: {},
    });
    const toolNames = listRes.result.tools.map((t) => t.name).sort();
    assert.ok(toolNames.includes('hello'));
    assert.ok(toolNames.includes('add'));
    assert.ok(toolNames.includes('create_invoice'));

    // Call hello tool
    const callRes = await sendRequest(proc, {
      jsonrpc: '2.0',
      id: 3,
      method: 'tools/call',
      params: { name: 'hello', arguments: { name: 'World' } },
    });
    assert.equal(callRes.result.content[0].text, 'Hello, World!');

    // Call add tool
    const addRes = await sendRequest(proc, {
      jsonrpc: '2.0',
      id: 4,
      method: 'tools/call',
      params: { name: 'add', arguments: { a: 3, b: 4 } },
    });
    const sum = JSON.parse(addRes.result.content[0].text);
    assert.equal(sum.sum, 7);

    // Validation error
    const errRes = await sendRequest(proc, {
      jsonrpc: '2.0',
      id: 5,
      method: 'tools/call',
      params: { name: 'add', arguments: { a: 'not a number', b: 4 } },
    });
    assert.equal(errRes.result.isError, true);

    proc.kill();
  });
});
