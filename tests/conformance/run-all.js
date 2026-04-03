#!/usr/bin/env node

/**
 * Run conformance tests against all zeromcp implementations.
 * Designed to run inside the Docker container with all runtimes installed.
 */

import { spawn } from 'child_process';
import { readFileSync, existsSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, '..', '..');

const implementations = [
  {
    name: 'Node.js',
    command: 'node',
    args: [join(root, 'nodejs/bin/mcp.js'), 'serve', join(root, 'nodejs/examples/tools')],
  },
  {
    name: 'Python',
    command: 'python3',
    args: ['-m', 'zeromcp', 'serve', join(root, 'python/examples/tools')],
    env: { PYTHONPATH: join(root, 'python') },
  },
  {
    name: 'Go',
    command: 'zeromcp-go',
    args: [],
  },
  {
    name: 'Ruby',
    command: 'ruby',
    args: ['-I', join(root, 'ruby/lib'), join(root, 'ruby/bin/zeromcp'), 'serve', join(root, 'ruby/tools')],
  },
  {
    name: 'Swift',
    // In Docker: /usr/local/bin/zeromcp-swift, locally: .build/debug/zeromcp-example
    command: existsSync('/usr/local/bin/zeromcp-swift') ? '/usr/local/bin/zeromcp-swift' : join(root, 'swift/.build/debug/zeromcp-example'),
    args: [],
    optional: true,
  },
  {
    name: 'Rust',
    command: join(root, 'rust/target/release/examples/hello'),
    args: [],
    optional: true,
  },
  {
    name: 'PHP',
    command: 'php',
    args: [join(root, 'php/zeromcp.php'), 'serve', join(root, 'php/tools')],
    optional: true,
  },
  {
    name: 'Kotlin',
    command: join(root, 'kotlin/example/build/install/example/bin/example'),
    args: [],
    env: { JAVA_TOOL_OPTIONS: '-Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8' },
    optional: true,
  },
  {
    name: 'Java',
    command: 'java',
    args: ['-Dfile.encoding=UTF-8', '-cp', join(root, 'java/target/zeromcp-0.1.0.jar') + ':' + join(root, 'java/target/deps/*') + ':/tmp/java-out', 'Main'],
    optional: true,
  },
  {
    name: 'C#',
    command: existsSync('/tmp/csharp-out/Example') ? '/tmp/csharp-out/Example' : 'dotnet',
    args: existsSync('/tmp/csharp-out/Example') ? [] : ['run', '--project', join(root, 'csharp/Example'), '--no-build'],
    optional: true,
  },
];

const fixtures = JSON.parse(readFileSync(join(__dirname, 'fixtures.json'), 'utf8'));

import { createInterface } from 'readline';

function createRequestHandler(proc) {
  const rl = createInterface({ input: proc.stdout });
  const pending = [];

  rl.on('line', (line) => {
    const trimmed = line.trim();
    if (!trimmed || pending.length === 0) return;
    const { resolve, reject, timer } = pending.shift();
    clearTimeout(timer);
    try { resolve(JSON.parse(trimmed)); }
    catch { reject(new Error(`Invalid JSON: ${trimmed.slice(0, 200)}`)); }
  });

  return (request) => {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        const idx = pending.findIndex(p => p.timer === timer);
        if (idx !== -1) pending.splice(idx, 1);
        reject(new Error('Timeout'));
      }, 10000);
      pending.push({ resolve, reject, timer });
      proc.stdin.write(JSON.stringify(request) + '\n');
    });
  };
}

// Kept for backward compat with runner.js
function sendRequest(proc, request) {
  if (!proc._zeromcpHandler) {
    proc._zeromcpHandler = createRequestHandler(proc);
  }
  return proc._zeromcpHandler(request);
}

function deepPartialMatch(actual, expected, path = '') {
  const errors = [];
  if (Array.isArray(expected)) {
    if (!Array.isArray(actual)) return [`Expected array at ${path}`];
    // Compare string arrays as sets (e.g. "required" field — order doesn't matter)
    if (expected.every(v => typeof v === 'string') && actual.every(v => typeof v === 'string')) {
      const missing = expected.filter(v => !actual.includes(v));
      const extra = actual.filter(v => !expected.includes(v));
      if (missing.length) errors.push(`Missing values at ${path}: ${missing.join(', ')}`);
      if (extra.length) errors.push(`Unexpected values at ${path}: ${extra.join(', ')}`);
      return errors;
    }
    for (let i = 0; i < expected.length; i++) {
      if (i >= actual.length) { errors.push(`Missing item at ${path}[${i}]`); continue; }
      errors.push(...deepPartialMatch(actual[i], expected[i], `${path}[${i}]`));
    }
    return errors;
  }
  if (typeof expected === 'object' && expected !== null) {
    if (typeof actual !== 'object' || actual === null) return [`Expected object at ${path}`];
    for (const [key, val] of Object.entries(expected)) {
      const fp = path ? `${path}.${key}` : key;
      if (!(key in actual)) { errors.push(`Missing: ${fp}`); continue; }
      errors.push(...deepPartialMatch(actual[key], val, fp));
    }
    return errors;
  }
  if (actual !== expected) errors.push(`${path}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  return errors;
}

async function testImplementation(impl) {
  let proc;
  try {
    const env = { ...process.env, ...(impl.env || {}) };
    proc = spawn(impl.command, impl.args, { stdio: ['pipe', 'pipe', 'pipe'], env });
  } catch {
    if (impl.optional) return { name: impl.name, passed: 0, failed: 0, skipped: true };
    return { name: impl.name, passed: 0, failed: 1, error: 'Failed to spawn' };
  }

  // Check if process started
  const started = await new Promise((resolve) => {
    proc.on('error', () => resolve(false));
    setTimeout(() => resolve(true), 2000);
  });

  if (!started) {
    if (impl.optional) return { name: impl.name, passed: 0, failed: 0, skipped: true };
    return { name: impl.name, passed: 0, failed: 1, error: 'Process failed to start' };
  }

  const send = createRequestHandler(proc);

  let passed = 0, failed = 0;
  const failures = [];

  for (const test of fixtures.tests) {
    try {
      if (test.match === 'silent') {
        proc.stdin.write(JSON.stringify(test.request) + '\n');
        await new Promise(r => setTimeout(r, 100));
        passed++;
        continue;
      }

      const response = await send(test.request);
      let errors = [];

      if (test.match === 'exact' || test.match === 'partial') {
        errors = deepPartialMatch(response, test.expect);
      } else if (test.match === 'tools') {
        const tools = response?.result?.tools;
        if (!Array.isArray(tools)) { errors = ['tools not array']; }
        else {
          for (const exp of test.expect_tools) {
            const found = tools.find(t => t.name === exp.name);
            if (!found) { errors.push(`Missing tool: ${exp.name}`); continue; }
            errors.push(...deepPartialMatch(found, exp, exp.name));
          }
        }
      } else if (test.match === 'tool_count') {
        const tools = response?.result?.tools;
        if (!Array.isArray(tools)) errors = ['tools not array'];
        else if (tools.length < test.expect_min_tools) errors = [`Expected at least ${test.expect_min_tools} tools, got ${tools.length}`];
      } else if (test.match === 'tool_structure') {
        const tools = response?.result?.tools;
        if (!Array.isArray(tools)) { errors = ['tools not array']; }
        else {
          for (const t of tools) {
            if (!t.name) errors.push(`Tool missing name`);
            if (!t.description && t.description !== '') errors.push(`Tool ${t.name} missing description`);
            if (!t.inputSchema) errors.push(`Tool ${t.name} missing inputSchema`);
            else if (t.inputSchema.type !== 'object') errors.push(`Tool ${t.name} inputSchema.type is not 'object'`);
          }
        }
      } else if (test.match === 'content_json') {
        const text = response?.result?.content?.[0]?.text;
        try { errors = deepPartialMatch(JSON.parse(text), test.expect_content_json); }
        catch { errors = ['Content not JSON']; }
      } else if (test.match === 'content_contains') {
        const text = response?.result?.content?.[0]?.text || '';
        if (!text.includes(test.expect_content_contains)) {
          errors = [`Content "${text.slice(0, 100)}" does not contain "${test.expect_content_contains}"`];
        }
      } else if (test.match === 'no_error') {
        if (response?.result?.isError) errors = ['Expected no error but got isError: true'];
      } else if (test.match === 'content_is_array') {
        const content = response?.result?.content;
        if (!Array.isArray(content)) errors = ['result.content is not an array'];
      } else if (test.match === 'content_shape') {
        const item = response?.result?.content?.[0];
        if (!item) errors = ['No content item'];
        else {
          if (!item.type) errors.push('Content item missing type');
          if (item.text === undefined) errors.push('Content item missing text');
        }
      }

      if (errors.length === 0) passed++;
      else { failed++; failures.push({ test: test.name, errors }); }
    } catch (err) {
      failed++;
      failures.push({ test: test.name, errors: [err.message] });
    }
  }

  proc.kill();
  return { name: impl.name, passed, failed, failures };
}

async function main() {
  console.log('\n  ZeroMCP Cross-Language Conformance Suite\n');

  let totalPassed = 0, totalFailed = 0, totalSkipped = 0;

  for (const impl of implementations) {
    const result = await testImplementation(impl);

    if (result.skipped) {
      console.log(`  ⊘ ${result.name} — skipped (binary not found)`);
      totalSkipped++;
      continue;
    }

    if (result.error) {
      console.log(`  ✗ ${result.name} — ${result.error}`);
      totalFailed++;
      continue;
    }

    const status = result.failed === 0 ? '✓' : '✗';
    console.log(`  ${status} ${result.name} — ${result.passed}/${result.passed + result.failed} passed`);

    if (result.failures?.length) {
      for (const f of result.failures) {
        console.log(`    ✗ ${f.test}: ${f.errors[0]}`);
      }
    }

    totalPassed += result.failed === 0 ? 1 : 0;
    totalFailed += result.failed > 0 ? 1 : 0;
  }

  console.log(`\n  ${totalPassed} languages passed, ${totalFailed} failed, ${totalSkipped} skipped\n`);
  process.exit(totalFailed > 0 ? 1 : 0);
}

main();
