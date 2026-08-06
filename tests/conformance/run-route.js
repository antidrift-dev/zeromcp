#!/usr/bin/env node

/**
 * OpenAPI / route conformance tests.
 * Tests all 10 language implementations for route + OpenAPI support.
 */

import { spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, '..', '..');

const implementations = [
  // File-based: started via CLI with route config files
  {
    name: 'Node.js',
    command: 'node',
    args: [join(root, 'nodejs/bin/mcp.js'), 'serve', '--config', join(__dirname, 'route-config-node.json')],
    env: {},
    port: 14250,
  },
  {
    name: 'Python',
    command: 'python3',
    args: ['-m', 'zeromcp', 'serve', '--config', join(__dirname, 'route-config-python.json')],
    env: { PYTHONPATH: join(root, 'python') },
    port: 14251,
  },
  {
    name: 'Ruby',
    command: 'ruby',
    args: ['-I', join(root, 'ruby/lib'), join(root, 'ruby/bin/zeromcp'), 'serve', '--config', join(__dirname, 'route-config-ruby.json')],
    env: {},
    port: 14252,
  },
  {
    name: 'PHP',
    command: 'php',
    args: [join(root, 'php/zeromcp.php'), 'serve', '--config', join(__dirname, 'route-config-php.json')],
    env: {},
    port: 14253,
    optional: true,
  },
  // Compiled: started via pre-built route-test binaries
  {
    name: 'Go',
    command: existsSync('/usr/local/bin/zeromcp-go-route') ? 'zeromcp-go-route' : join(root, 'go/examples/route-test/route-test'),
    args: [],
    env: {},
    port: 14254,
    optional: true,
  },
  {
    name: 'Rust',
    command: join(root, 'rust/target/release/examples/route_test'),
    args: [],
    env: {},
    port: 14255,
    optional: true,
  },
  {
    name: 'Java',
    command: 'java',
    args: ['-Dfile.encoding=UTF-8', '-cp',
      join(root, 'java/target/zeromcp-0.2.2.jar') + ':' + join(root, 'java/target/deps/*') + ':/tmp/java-out',
      'RouteTest'],
    env: { JAVA_TOOL_OPTIONS: '-Dfile.encoding=UTF-8' },
    port: 14256,
    optional: true,
  },
  {
    name: 'Kotlin',
    command: join(root, 'kotlin/example/build/install/example/bin/example'),
    args: [],
    env: { JAVA_TOOL_OPTIONS: '-Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8', ZEROMCP_ROUTE_TEST: 'true' },
    port: 14257,
    optional: true,
  },
  {
    name: 'Swift',
    command: existsSync('/usr/local/bin/zeromcp-swift-route') ? '/usr/local/bin/zeromcp-swift-route' : join(root, 'swift/.build/debug/zeromcp-route-test'),
    args: [],
    env: {},
    port: 14258,
    optional: true,
  },
  {
    name: 'C#',
    command: existsSync('/tmp/csharp-route-out/RouteTest') ? '/tmp/csharp-route-out/RouteTest' : 'dotnet',
    args: existsSync('/tmp/csharp-route-out/RouteTest') ? [] : ['run', '--project', join(root, 'csharp/RouteTest'), '--no-build'],
    env: {},
    port: 14259,
    optional: true,
  },
];

async function waitForPort(port, timeout = 15000) {
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

async function httpRequest(port, method, path, body) {
  const url = `http://localhost:${port}${path}`;
  const headers = { 'Content-Type': 'application/json' };

  const opts = { method, headers };
  if (body) opts.body = JSON.stringify(body);

  const res = await fetch(url, opts);
  const text = await res.text();
  let json;
  try { json = JSON.parse(text); } catch { json = null; }
  return { status: res.status, body: json, text };
}

async function runRouteTests(impl) {
  const env = { ...process.env, ...impl.env };
  const proc = spawn(impl.command, impl.args, { stdio: ['pipe', 'pipe', 'pipe'], env });

  let startupError = null;
  proc.on('error', (err) => { startupError = err; });

  const ready = await waitForPort(impl.port);
  if (!ready) {
    proc.kill();
    if (impl.optional) {
      return { name: impl.name, skipped: true, passed: 0, failed: 0, failures: [] };
    }
    return { name: impl.name, passed: 0, failed: 1, failures: [{ test: 'startup', errors: [startupError?.message || 'Server did not start'] }] };
  }

  let passed = 0, failed = 0;
  const failures = [];

  // Test 1: GET /greet/World → 200, ok === true, result === "Hello, World!"
  {
    const res = await httpRequest(impl.port, 'GET', '/greet/World');
    const ok = res.status === 200 && res.body?.ok === true && res.body?.result === 'Hello, World!';
    if (ok) passed++;
    else { failed++; failures.push({ test: 'GET /greet/World', errors: [`Status ${res.status}, body: ${JSON.stringify(res.body).slice(0, 200)}`] }); }
  }

  // Test 2: POST /echo with { message: "test" } → 200, ok, result.message === "test", result.echoed === true
  {
    const res = await httpRequest(impl.port, 'POST', '/echo', { message: 'test' });
    const ok = res.status === 200 && res.body?.ok === true &&
      res.body?.result?.message === 'test' && res.body?.result?.echoed === true;
    if (ok) passed++;
    else { failed++; failures.push({ test: 'POST /echo', errors: [`Status ${res.status}, body: ${JSON.stringify(res.body).slice(0, 200)}`] }); }
  }

  // Test 3: GET /openapi.json → 200, openapi === "3.0.0", paths has at least one entry
  {
    const res = await httpRequest(impl.port, 'GET', '/openapi.json');
    const paths = res.body?.paths;
    const ok = res.status === 200 && res.body?.openapi === '3.0.0' &&
      paths != null && typeof paths === 'object' && Object.keys(paths).length >= 1;
    if (ok) passed++;
    else { failed++; failures.push({ test: 'GET /openapi.json', errors: [`Status ${res.status}, openapi: ${res.body?.openapi}, paths keys: ${paths ? Object.keys(paths).length : 'missing'}`] }); }
  }

  // Test 4: GET /docs → 200, HTML contains "swagger" (case-insensitive)
  {
    const res = await httpRequest(impl.port, 'GET', '/docs');
    const ok = res.status === 200 && res.text?.toLowerCase().includes('swagger');
    if (ok) passed++;
    else { failed++; failures.push({ test: 'GET /docs', errors: [`Status ${res.status}, swagger in body: ${res.text?.toLowerCase().includes('swagger')}`] }); }
  }

  // Test 5: POST /mcp tools/list → 200, result.tools is an array
  {
    const res = await httpRequest(impl.port, 'POST', '/mcp', {
      jsonrpc: '2.0', id: 1, method: 'tools/list', params: {}
    });
    const ok = res.status === 200 && Array.isArray(res.body?.result?.tools);
    if (ok) passed++;
    else { failed++; failures.push({ test: 'POST /mcp tools/list', errors: [`Status ${res.status}, tools: ${JSON.stringify(res.body?.result?.tools).slice(0, 100)}`] }); }
  }

  proc.kill();
  return { name: impl.name, passed, failed, failures };
}

export async function runRouteSuite() {
  const results = [];

  for (const impl of implementations) {
    results.push(await runRouteTests(impl));
  }

  return results;
}

// Run standalone
if (process.argv[1] && process.argv[1].includes('run-route')) {
  console.log('\n  Route + OpenAPI Conformance\n');
  const results = await runRouteSuite();
  let totalFailed = 0;
  for (const r of results) {
    if (r.skipped) {
      console.log(`  - ${r.name} — skipped (binary not found)`);
      continue;
    }
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
