#!/usr/bin/env node

/**
 * HTTP transport + Bearer auth conformance tests.
 * Tests Node.js and Go HTTP server implementations.
 */

import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, '..', '..');

const TOKEN = 'test-token-xyz-789';

const implementations = [
  {
    name: 'Node.js',
    command: 'node',
    args: [join(root, 'nodejs/bin/mcp.js'), 'serve', '--config', join(__dirname, 'http-config-node.json')],
    env: { TEST_MCP_TOKEN: TOKEN },
    port: 14242,
  },
  {
    name: 'Go',
    command: 'bash',
    args: ['-c', `cp ${join(__dirname, 'http-config-go.json')} /tmp/zeromcp.config.json && cd /tmp && zeromcp-go-advanced`],
    env: { TEST_MCP_TOKEN: TOKEN },
    port: 14243,
    optional: true,
  },
];

const noAuthImplementations = [
  {
    name: 'Node.js (no auth)',
    command: 'node',
    args: [join(root, 'nodejs/bin/mcp.js'), 'serve', '--config', join(__dirname, 'http-config-node-noauth.json')],
    env: {},
    port: 14244,
  },
];

async function waitForPort(port, timeout = 10000) {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    try {
      const res = await fetch(`http://localhost:${port}/health`).catch(() => null);
      if (res) return true;
    } catch {}
    await new Promise(r => setTimeout(r, 200));
  }
  return false;
}

async function httpRequest(port, method, path, body, token) {
  const url = `http://localhost:${port}${path}`;
  const headers = { 'Content-Type': 'application/json' };
  if (token) headers['Authorization'] = `Bearer ${token}`;

  const opts = { method, headers };
  if (body) opts.body = JSON.stringify(body);

  const res = await fetch(url, opts);
  const text = await res.text();
  let json;
  try { json = JSON.parse(text); } catch { json = null; }
  return { status: res.status, body: json, text };
}

async function runAuthTests(impl) {
  const env = { ...process.env, ...impl.env };
  const proc = spawn(impl.command, impl.args, { stdio: ['pipe', 'pipe', 'pipe'], env });

  const ready = await waitForPort(impl.port);
  if (!ready) {
    proc.kill();
    return { name: impl.name, passed: 0, failed: 1, failures: [{ test: 'startup', errors: ['Server did not start'] }] };
  }

  let passed = 0, failed = 0;
  const failures = [];

  // Test 1: No auth → 401
  {
    const res = await httpRequest(impl.port, 'POST', '/mcp', {
      jsonrpc: '2.0', id: 1, method: 'initialize',
      params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'test', version: '1.0' } }
    }, null);
    if (res.status === 401) passed++;
    else { failed++; failures.push({ test: 'http_no_auth_rejected', errors: [`Expected 401, got ${res.status}`] }); }
  }

  // Test 2: Wrong token → 401
  {
    const res = await httpRequest(impl.port, 'POST', '/mcp', {
      jsonrpc: '2.0', id: 2, method: 'ping'
    }, 'wrong-token');
    if (res.status === 401) passed++;
    else { failed++; failures.push({ test: 'http_wrong_token', errors: [`Expected 401, got ${res.status}`] }); }
  }

  // Test 3: Valid token → initialize succeeds
  {
    const res = await httpRequest(impl.port, 'POST', '/mcp', {
      jsonrpc: '2.0', id: 3, method: 'initialize',
      params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'test', version: '1.0' } }
    }, TOKEN);
    if (res.status === 200 && res.body?.result?.protocolVersion === '2024-11-05') passed++;
    else { failed++; failures.push({ test: 'http_valid_auth_init', errors: [`Status ${res.status}, body: ${JSON.stringify(res.body).slice(0, 200)}`] }); }
  }

  // Test 4: Valid token → tools/list
  {
    const res = await httpRequest(impl.port, 'POST', '/mcp', {
      jsonrpc: '2.0', id: 4, method: 'tools/list', params: {}
    }, TOKEN);
    if (res.status === 200 && Array.isArray(res.body?.result?.tools)) passed++;
    else { failed++; failures.push({ test: 'http_valid_auth_list', errors: [`Status ${res.status}`] }); }
  }

  // Test 5: Valid token → tools/call (use first available tool or ping)
  {
    // Get tool list first to find a tool name that exists
    const listRes = await httpRequest(impl.port, 'POST', '/mcp', {
      jsonrpc: '2.0', id: 50, method: 'tools/list', params: {}
    }, TOKEN);
    const tools = listRes.body?.result?.tools || [];
    const toolName = tools.find(t => t.name === 'hello')?.name || tools[0]?.name;

    if (toolName) {
      const args = toolName === 'hello' ? { name: 'World' } : {};
      const res = await httpRequest(impl.port, 'POST', '/mcp', {
        jsonrpc: '2.0', id: 5, method: 'tools/call',
        params: { name: toolName, arguments: args }
      }, TOKEN);
      if (res.status === 200 && res.body?.result?.content) passed++;
      else { failed++; failures.push({ test: 'http_valid_auth_call', errors: [`Status ${res.status}`] }); }
    } else {
      // No tools — just verify ping works with auth
      const res = await httpRequest(impl.port, 'POST', '/mcp', {
        jsonrpc: '2.0', id: 5, method: 'ping'
      }, TOKEN);
      if (res.status === 200) passed++;
      else { failed++; failures.push({ test: 'http_valid_auth_call', errors: [`No tools and ping failed`] }); }
    }
  }

  // Test 6: CORS preflight
  {
    const res = await fetch(`http://localhost:${impl.port}/mcp`, { method: 'OPTIONS' });
    const allow = res.headers.get('access-control-allow-origin');
    if ((res.status === 204 || res.status === 200) && allow === '*') passed++;
    else { failed++; failures.push({ test: 'http_cors_preflight', errors: [`Status ${res.status}, CORS: ${allow}`] }); }
  }

  proc.kill();
  return { name: impl.name, passed, failed, failures };
}

async function runNoAuthTests(impl) {
  const env = { ...process.env, ...impl.env };
  const proc = spawn(impl.command, impl.args, { stdio: ['pipe', 'pipe', 'pipe'], env });

  const ready = await waitForPort(impl.port);
  if (!ready) {
    proc.kill();
    return { name: impl.name, passed: 0, failed: 1, failures: [{ test: 'startup', errors: ['Server did not start'] }] };
  }

  let passed = 0, failed = 0;
  const failures = [];

  // No auth configured → requests pass without token
  {
    const res = await httpRequest(impl.port, 'POST', '/mcp', {
      jsonrpc: '2.0', id: 1, method: 'initialize',
      params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'test', version: '1.0' } }
    }, null);
    if (res.status === 200 && res.body?.result?.protocolVersion === '2024-11-05') passed++;
    else { failed++; failures.push({ test: 'http_no_auth_config', errors: [`Status ${res.status}`] }); }
  }

  proc.kill();
  return { name: impl.name, passed, failed, failures };
}

export async function runHttpSuite() {
  const results = [];

  for (const impl of implementations) {
    results.push(await runAuthTests(impl));
  }
  for (const impl of noAuthImplementations) {
    results.push(await runNoAuthTests(impl));
  }

  return results;
}

// Run standalone
if (process.argv[1] && process.argv[1].includes('run-http')) {
  console.log('\n  HTTP Transport + Auth\n');
  const results = await runHttpSuite();
  let totalFailed = 0;
  for (const r of results) {
    const status = r.failed === 0 ? '✓' : '✗';
    console.log(`  ${status} ${r.name} — ${r.passed}/${r.passed + r.failed} passed`);
    if (r.failures?.length) {
      for (const f of r.failures) {
        console.log(`    ✗ ${f.test}: ${f.errors[0]}`);
      }
    }
    totalFailed += r.failed;
  }
  console.log();
  process.exit(totalFailed > 0 ? 1 : 0);
}
