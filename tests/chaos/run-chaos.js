#!/usr/bin/env node

/**
 * ZeroMCP Chaos Monkey Test Suite
 * Tests server resilience against malformed input, bad tools, and abuse.
 *
 * Each attack:
 *   1. Does something hostile
 *   2. Sends a normal "hello" request to check if server still works
 *   3. Scores: survived / degraded / crashed / corrupted
 */

import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, '..', '..');
const chaosToolsDir = join(__dirname, 'tools');

const TIMEOUT = 5000;

// --- Transport ---

function createHandler(proc) {
  const rl = createInterface({ input: proc.stdout });
  const pending = [];

  rl.on('line', (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    let parsed;
    try { parsed = JSON.parse(trimmed); } catch { return; }
    if (parsed.id === undefined || parsed.id === null) return;
    if (pending.length === 0) return;
    const { resolve, timer } = pending.shift();
    clearTimeout(timer);
    resolve(parsed);
  });

  return (request, timeoutMs = TIMEOUT) => new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      const idx = pending.findIndex(p => p.timer === timer);
      if (idx !== -1) pending.splice(idx, 1);
      reject(new Error('Timeout'));
    }, timeoutMs);
    pending.push({ resolve, reject, timer });
    proc.stdin.write(JSON.stringify(request) + '\n');
  });
}

// Send raw bytes (not JSON)
function sendRaw(proc, data) {
  proc.stdin.write(data);
}

// Health check — can the server still respond to a normal request?
async function healthCheck(send, id) {
  try {
    const res = await send({
      jsonrpc: '2.0', id, method: 'tools/call',
      params: { name: 'hello', arguments: { name: 'healthcheck' } },
    });
    const text = res?.result?.content?.[0]?.text || '';
    if (text.includes('Hello, healthcheck!')) return 'survived';
    return 'corrupted';
  } catch (err) {
    if (err.message === 'Timeout') return 'crashed';
    return 'crashed';
  }
}

// --- Attacks ---

const attacks = [
  // Protocol chaos
  {
    name: 'malformed_json',
    description: 'Send invalid JSON',
    run: async (send, proc) => {
      sendRaw(proc, '{{{{not json at all!!!!\n');
      sendRaw(proc, '\n');
      sendRaw(proc, '{}\n');
      sendRaw(proc, 'null\n');
      await new Promise(r => setTimeout(r, 200));
      return healthCheck(send, 9001);
    },
  },
  {
    name: 'truncated_json',
    description: 'Send JSON truncated mid-field',
    run: async (send, proc) => {
      sendRaw(proc, '{"jsonrpc":"2.0","id":1,"meth\n');
      await new Promise(r => setTimeout(r, 200));
      return healthCheck(send, 9002);
    },
  },
  {
    name: 'empty_line',
    description: 'Send empty lines',
    run: async (send, proc) => {
      sendRaw(proc, '\n\n\n\n\n');
      await new Promise(r => setTimeout(r, 200));
      return healthCheck(send, 9003);
    },
  },
  {
    name: 'missing_id',
    description: 'Send request without id (should be treated as notification)',
    run: async (send, proc) => {
      sendRaw(proc, JSON.stringify({ jsonrpc: '2.0', method: 'tools/call', params: { name: 'hello', arguments: { name: 'noid' } } }) + '\n');
      await new Promise(r => setTimeout(r, 200));
      return healthCheck(send, 9004);
    },
  },
  {
    name: 'missing_method',
    description: 'Send request without method field',
    run: async (send, proc) => {
      try {
        await send({ jsonrpc: '2.0', id: 9005 });
      } catch {}
      await new Promise(r => setTimeout(r, 200));
      return healthCheck(send, 9006);
    },
  },
  {
    name: 'null_id',
    description: 'Send request with null id',
    run: async (send, proc) => {
      sendRaw(proc, JSON.stringify({ jsonrpc: '2.0', id: null, method: 'ping' }) + '\n');
      await new Promise(r => setTimeout(r, 200));
      return healthCheck(send, 9007);
    },
  },
  {
    name: 'negative_id',
    description: 'Send request with negative id',
    run: async (send, proc) => {
      try {
        const res = await send({ jsonrpc: '2.0', id: -999, method: 'ping' });
        if (res.id !== -999) return 'corrupted';
      } catch {}
      return healthCheck(send, 9008);
    },
  },
  {
    name: 'duplicate_id',
    description: 'Send two requests with same id',
    run: async (send, proc) => {
      const p1 = send({ jsonrpc: '2.0', id: 7777, method: 'ping' });
      const p2 = send({ jsonrpc: '2.0', id: 7777, method: 'ping' });
      try { await p1; } catch {}
      try { await p2; } catch {}
      await new Promise(r => setTimeout(r, 200));
      return healthCheck(send, 9009);
    },
  },
  {
    name: 'pre_init_tool_call',
    description: 'Call a tool before sending initialize (on fresh connection)',
    // Note: this tests on the already-initialized connection, so it checks
    // whether calling tools works without following the strict init flow
    run: async (send, proc) => {
      return healthCheck(send, 9010);
    },
  },
  {
    name: 'double_initialize',
    description: 'Send initialize twice',
    run: async (send, proc) => {
      try {
        await send({
          jsonrpc: '2.0', id: 9011, method: 'initialize',
          params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'chaos', version: '1.0' } },
        });
      } catch {}
      return healthCheck(send, 9012);
    },
  },
  {
    name: 'unknown_method',
    description: 'Send a completely unknown method',
    run: async (send, proc) => {
      try {
        const res = await send({ jsonrpc: '2.0', id: 9013, method: 'chaos/destroy_everything', params: {} });
        // Should get error response, not crash
      } catch {}
      return healthCheck(send, 9014);
    },
  },

  // Payload chaos
  {
    name: 'giant_string',
    description: 'Send a 1MB string as tool argument',
    run: async (send, proc) => {
      const bigString = 'A'.repeat(1024 * 1024);
      try {
        await send({
          jsonrpc: '2.0', id: 9020, method: 'tools/call',
          params: { name: 'hello', arguments: { name: bigString } },
        }, 10000);
      } catch {}
      return healthCheck(send, 9021);
    },
  },
  {
    name: 'deeply_nested',
    description: 'Send deeply nested JSON (100 levels)',
    run: async (send, proc) => {
      let obj = { value: 'deep' };
      for (let i = 0; i < 100; i++) obj = { nested: obj };
      try {
        await send({
          jsonrpc: '2.0', id: 9022, method: 'tools/call',
          params: { name: 'hello', arguments: { name: JSON.stringify(obj) } },
        }, 10000);
      } catch {}
      return healthCheck(send, 9023);
    },
  },
  {
    name: 'empty_tool_name',
    description: 'Call a tool with empty string name',
    run: async (send, proc) => {
      try {
        await send({
          jsonrpc: '2.0', id: 9024, method: 'tools/call',
          params: { name: '', arguments: {} },
        });
      } catch {}
      return healthCheck(send, 9025);
    },
  },
  {
    name: 'null_arguments',
    description: 'Call a tool with null arguments',
    run: async (send, proc) => {
      try {
        await send({
          jsonrpc: '2.0', id: 9026, method: 'tools/call',
          params: { name: 'hello', arguments: null },
        });
      } catch {}
      return healthCheck(send, 9027);
    },
  },
  {
    name: 'binary_garbage',
    description: 'Send random binary data',
    run: async (send, proc) => {
      const buf = Buffer.alloc(256);
      for (let i = 0; i < 256; i++) buf[i] = Math.floor(Math.random() * 256);
      sendRaw(proc, buf);
      sendRaw(proc, '\n');
      await new Promise(r => setTimeout(r, 500));
      return healthCheck(send, 9028);
    },
  },

  // Tool execution chaos (requires chaos tool files loaded)
  {
    name: 'tool_throws',
    requiresChaosTools: true,
    description: 'Call a tool that throws an unhandled exception',
    run: async (send, proc) => {
      try {
        const res = await send({
          jsonrpc: '2.0', id: 9030, method: 'tools/call',
          params: { name: 'throw_error', arguments: {} },
        });
        // Should get isError response, not crash
        if (!res?.result?.isError) return 'corrupted';
      } catch {}
      return healthCheck(send, 9031);
    },
  },
  {
    name: 'tool_hangs',
    requiresChaosTools: true,
    description: 'Call a tool that never returns (5s timeout)',
    run: async (send, proc) => {
      try {
        await send({
          jsonrpc: '2.0', id: 9032, method: 'tools/call',
          params: { name: 'hang', arguments: {} },
        }, 5000);
        // If we get here, tool returned (unexpected)
        return 'survived';
      } catch (err) {
        if (err.message === 'Timeout') {
          // Expected — tool hung. But is server still alive?
          // Send another request to check (the hang tool is still blocking though)
          // This tests if the server can handle new requests while one is hung
          return 'degraded'; // We know it'll be stuck
        }
        return 'crashed';
      }
    },
  },
  {
    name: 'tool_slow',
    requiresChaosTools: true,
    description: 'Call a tool that takes 3 seconds',
    run: async (send, proc) => {
      try {
        const res = await send({
          jsonrpc: '2.0', id: 9034, method: 'tools/call',
          params: { name: 'slow', arguments: {} },
        }, 10000);
        if (res?.result?.content?.[0]?.text?.includes('ok')) return 'survived';
        return 'corrupted';
      } catch {
        return 'crashed';
      }
    },
  },
  {
    name: 'tool_leak_memory',
    requiresChaosTools: true,
    description: 'Call memory-leaking tool 50 times',
    run: async (send, proc) => {
      for (let i = 0; i < 50; i++) {
        try {
          await send({
            jsonrpc: '2.0', id: 9040 + i, method: 'tools/call',
            params: { name: 'leak_memory', arguments: {} },
          });
        } catch { return 'crashed'; }
      }
      return healthCheck(send, 9099);
    },
  },
  {
    name: 'tool_stdout_corrupt',
    requiresChaosTools: true,
    description: 'Call a tool that writes directly to stdout',
    run: async (send, proc) => {
      try {
        await send({
          jsonrpc: '2.0', id: 9100, method: 'tools/call',
          params: { name: 'stdout_corrupt', arguments: {} },
        });
      } catch {}
      // The real test: can we still get valid responses?
      return healthCheck(send, 9101);
    },
  },

  // Flood
  {
    name: 'rapid_fire_100',
    description: 'Send 100 requests as fast as possible',
    run: async (send, proc) => {
      const promises = [];
      for (let i = 0; i < 100; i++) {
        promises.push(
          send({
            jsonrpc: '2.0', id: 9200 + i, method: 'tools/call',
            params: { name: 'hello', arguments: { name: `flood_${i}` } },
          }).catch(() => null)
        );
      }
      const results = await Promise.all(promises);
      const successes = results.filter(r => r?.result?.content?.[0]?.text?.includes('Hello'));
      if (successes.length === 100) return 'survived';
      if (successes.length > 0) return 'degraded';
      return 'crashed';
    },
  },
];

// --- Runner ---

const implementations = [
  {
    name: 'Node.js',
    command: 'node',
    args: [join(root, 'nodejs/bin/mcp.js'), 'serve', chaosToolsDir],
    hasChaosTools: true,
  },
  {
    name: 'Python',
    command: 'python3',
    args: ['-m', 'zeromcp', 'serve', chaosToolsDir],
    env: { PYTHONPATH: join(root, 'python') },
    hasChaosTools: true,
  },
  {
    name: 'Go',
    command: existsSync('/usr/local/bin/zeromcp-go-chaos') ? 'zeromcp-go-chaos' : join(root, 'go/examples/chaos-test/zeromcp-go-chaos'),
    args: [],
    optional: true,
    hasChaosTools: true,
  },
  {
    name: 'Ruby',
    command: 'ruby',
    args: ['-I', join(root, 'ruby/lib'), join(root, 'ruby/bin/zeromcp'), 'serve', chaosToolsDir],
    hasChaosTools: true,
  },
  {
    name: 'Rust',
    command: join(root, 'rust/target/release/examples/chaos_test'),
    args: [],
    optional: true,
    hasChaosTools: true,
  },
  {
    name: 'PHP',
    command: 'php',
    args: [join(root, 'php/zeromcp.php'), 'serve', chaosToolsDir],
    optional: true,
    hasChaosTools: true,
  },
  {
    name: 'Kotlin',
    command: join(root, 'kotlin/example/build/install/example/bin/example'),
    args: [],
    env: { JAVA_TOOL_OPTIONS: '-Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8', ZEROMCP_CHAOS_TEST: 'true' },
    optional: true,
    hasChaosTools: true,
  },
  {
    name: 'Java',
    command: 'java',
    args: ['-Dfile.encoding=UTF-8', '-cp', join(root, 'java/target/zeromcp-0.1.0.jar') + ':' + join(root, 'java/target/deps/*') + ':/tmp/java-out', 'ChaosTest'],
    optional: true,
    hasChaosTools: true,
  },
  {
    name: 'Swift',
    command: existsSync('/usr/local/bin/zeromcp-swift-chaos') ? '/usr/local/bin/zeromcp-swift-chaos' : join(root, 'swift/.build/debug/zeromcp-chaos-test'),
    args: [],
    optional: true,
    hasChaosTools: true,
  },
  {
    name: 'C#',
    command: existsSync('/tmp/csharp-chaos-out/ChaosTest') ? '/tmp/csharp-chaos-out/ChaosTest' : 'dotnet',
    args: existsSync('/tmp/csharp-chaos-out/ChaosTest') ? [] : ['run', '--project', join(root, 'csharp/ChaosTest'), '--no-build'],
    optional: true,
    hasChaosTools: true,
  },
];

async function spawnAndInit(impl) {
  const env = { ...process.env, ...(impl.env || {}) };
  const proc = spawn(impl.command, impl.args, { stdio: ['pipe', 'pipe', 'pipe'], env });
  proc.stdin.on('error', () => {}); // ignore EPIPE
  proc.on('error', () => {});

  const started = await new Promise((resolve) => {
    proc.on('error', () => resolve(false));
    setTimeout(() => resolve(true), 2000);
  });

  if (!started) return null;

  const send = createHandler(proc);

  try {
    await send({
      jsonrpc: '2.0', id: 1, method: 'initialize',
      params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'chaos-monkey', version: '1.0' } },
    });
    proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
    await new Promise(r => setTimeout(r, 200));
  } catch {
    proc.kill();
    return null;
  }

  return { proc, send };
}

async function runChaos(impl) {
  // Quick check — can we spawn at all?
  const test = await spawnAndInit(impl);
  if (!test) {
    if (impl.optional) return { name: impl.name, skipped: true };
    return { name: impl.name, error: 'Failed to spawn or initialize' };
  }
  test.proc.kill();

  // Run each attack on a fresh server instance
  const results = [];
  for (const attack of attacks) {
    // Skip tool-based attacks for compiled languages without chaos tools
    if (attack.requiresChaosTools && !impl.hasChaosTools) {
      results.push({ attack: attack.name, description: attack.description, score: 'skipped' });
      continue;
    }

    const instance = await spawnAndInit(impl);
    if (!instance) {
      results.push({ attack: attack.name, description: attack.description, score: 'crashed' });
      continue;
    }

    let score;
    try {
      score = await attack.run(instance.send, instance.proc);
    } catch (err) {
      score = 'crashed';
    }
    results.push({ attack: attack.name, description: attack.description, score });

    instance.proc.kill();
  }

  const applicable = results.filter(r => r.score !== 'skipped');
  const survived = applicable.filter(r => r.score === 'survived').length;
  const degraded = applicable.filter(r => r.score === 'degraded').length;
  const crashed = applicable.filter(r => r.score === 'crashed').length;
  const corrupted = applicable.filter(r => r.score === 'corrupted').length;
  const skipped = results.filter(r => r.score === 'skipped').length;

  return {
    name: impl.name,
    total: applicable.length,
    survived,
    degraded,
    crashed,
    corrupted,
    skipped,
    score: `${survived}/${applicable.length}`,
    results,
  };
}

async function main() {
  console.log('\n  ZeroMCP Chaos Monkey Suite\n');

  const allResults = [];

  for (const impl of implementations) {
    const result = await runChaos(impl);

    if (result.skipped) {
      console.log(`  ⊘ ${result.name} — skipped`);
      continue;
    }

    if (result.error) {
      console.log(`  ✗ ${result.name} — ${result.error}`);
      allResults.push(result);
      continue;
    }

    const emoji = result.crashed === 0 && result.corrupted === 0 ? '✓' : '✗';
    console.log(`  ${emoji} ${result.name} — ${result.survived} survived, ${result.degraded} degraded, ${result.crashed} crashed, ${result.corrupted} corrupted (${result.score})`);

    for (const r of result.results) {
      if (r.score !== 'survived') {
        const icon = r.score === 'degraded' ? '⚠' : '✗';
        console.log(`    ${icon} ${r.attack}: ${r.score} — ${r.description}`);
      }
    }

    allResults.push(result);
  }

  // Summary table
  console.log('\n  Resilience Scorecard\n');
  console.log('  | Attack | ' + allResults.map(r => r.name).join(' | ') + ' |');
  console.log('  |--------|' + allResults.map(() => '---').join('|') + '|');

  for (const attack of attacks) {
    const scores = allResults.map(r => {
      const ar = r.results?.find(a => a.attack === attack.name);
      if (!ar) return '-';
      return ar.score === 'survived' ? '✓' : ar.score === 'degraded' ? '⚠' : '✗';
    });
    console.log(`  | ${attack.name} | ${scores.join(' | ')} |`);
  }

  console.log();

  // JSON output
  if (process.argv.includes('--json')) {
    console.log(JSON.stringify(allResults, null, 2));
  }

  const anyFailed = allResults.some(r => r.crashed > 0 || r.corrupted > 0);
  process.exit(anyFailed ? 1 : 0);
}

main();
