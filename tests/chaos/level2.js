#!/usr/bin/env node

/**
 * ZeroMCP Chaos Monkey Level 2 — Stress Testing
 * Extreme payloads, concurrency, and edge cases.
 *
 * Each attack:
 *   1. Does something extreme
 *   2. Sends a normal "hello" request to check if server still works
 *   3. Scores: survived / degraded / crashed / corrupted
 *
 * Usage: node tests/chaos/level2.js <command> [args...]
 *   e.g. node tests/chaos/level2.js node bin/mcp.js serve examples/tools
 */

import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, '..', '..');

const TIMEOUT = 10000; // 10s for level 2 (some attacks are slow)

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

function sendRaw(proc, data) {
  proc.stdin.write(data);
}

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

// --- Level 2 Attacks ---

const attacks = [
  // Extreme payloads
  {
    name: '10mb_payload',
    description: 'Send a 10MB JSON-RPC request',
    run: async (send, proc) => {
      const bigString = 'A'.repeat(10 * 1024 * 1024);
      try {
        await send({
          jsonrpc: '2.0', id: 20001, method: 'tools/call',
          params: { name: 'hello', arguments: { name: bigString } },
        }, 15000);
      } catch {}
      await new Promise(r => setTimeout(r, 500));
      return healthCheck(send, 20002);
    },
  },
  {
    name: '1000_level_nesting',
    description: 'Send 1000-level deep nested JSON',
    run: async (send, proc) => {
      let nested = { value: 'deep' };
      for (let i = 0; i < 1000; i++) {
        nested = { child: nested };
      }
      try {
        await send({
          jsonrpc: '2.0', id: 20003, method: 'tools/call',
          params: { name: 'hello', arguments: { name: nested } },
        }, 10000);
      } catch {}
      await new Promise(r => setTimeout(r, 500));
      return healthCheck(send, 20004);
    },
  },
  {
    name: '50_concurrent_calls',
    description: 'Fire 50 tool calls simultaneously',
    run: async (send, proc) => {
      const promises = [];
      for (let i = 0; i < 50; i++) {
        promises.push(
          send({
            jsonrpc: '2.0', id: 20100 + i, method: 'tools/call',
            params: { name: 'hello', arguments: { name: `concurrent_${i}` } },
          }).catch(() => null)
        );
      }
      await Promise.allSettled(promises);
      await new Promise(r => setTimeout(r, 500));
      return healthCheck(send, 20200);
    },
  },
  {
    name: 'unicode_emoji_args',
    description: 'Unicode and emoji in tool arguments',
    run: async (send, proc) => {
      try {
        const res = await send({
          jsonrpc: '2.0', id: 20005, method: 'tools/call',
          params: { name: 'hello', arguments: { name: '🔥💀🎉 héllo wörld 你好 مرحبا' } },
        });
        const text = res?.result?.content?.[0]?.text || '';
        if (text.includes('🔥💀🎉')) return healthCheck(send, 20006);
      } catch {}
      return healthCheck(send, 20006);
    },
  },
  {
    name: 'null_bytes_in_strings',
    description: 'Null bytes embedded in argument strings',
    run: async (send, proc) => {
      try {
        await send({
          jsonrpc: '2.0', id: 20007, method: 'tools/call',
          params: { name: 'hello', arguments: { name: 'before\x00after' } },
        });
      } catch {}
      await new Promise(r => setTimeout(r, 200));
      return healthCheck(send, 20008);
    },
  },
  {
    name: 'interleaved_calls',
    description: 'Call tool while another is mid-execution (uses tool_slow if available)',
    run: async (send, proc) => {
      // Start a potentially slow call
      const slow = send({
        jsonrpc: '2.0', id: 20009, method: 'tools/call',
        params: { name: 'hello', arguments: { name: 'slow_start' } },
      }).catch(() => null);

      // Immediately send another
      const fast = send({
        jsonrpc: '2.0', id: 20010, method: 'tools/call',
        params: { name: 'hello', arguments: { name: 'interleaved' } },
      }).catch(() => null);

      await Promise.allSettled([slow, fast]);
      await new Promise(r => setTimeout(r, 200));
      return healthCheck(send, 20011);
    },
  },
  {
    name: '1000_rapid_fire',
    description: 'Send same request 1000 times as fast as possible',
    run: async (send, proc) => {
      const promises = [];
      for (let i = 0; i < 1000; i++) {
        promises.push(
          send({
            jsonrpc: '2.0', id: 21000 + i, method: 'tools/call',
            params: { name: 'hello', arguments: { name: 'rapid' } },
          }, 30000).catch(() => null)
        );
      }
      const results = await Promise.allSettled(promises);
      const fulfilled = results.filter(r => r.status === 'fulfilled' && r.value).length;
      await new Promise(r => setTimeout(r, 500));
      const health = await healthCheck(send, 22000);
      if (health === 'survived' && fulfilled < 900) return 'degraded';
      return health;
    },
  },
  {
    name: 'huge_number_of_args',
    description: 'Send 10000 argument keys',
    run: async (send, proc) => {
      const args = {};
      for (let i = 0; i < 10000; i++) {
        args[`key_${i}`] = `value_${i}`;
      }
      try {
        await send({
          jsonrpc: '2.0', id: 20012, method: 'tools/call',
          params: { name: 'hello', arguments: args },
        }, 10000);
      } catch {}
      await new Promise(r => setTimeout(r, 500));
      return healthCheck(send, 20013);
    },
  },
  {
    name: 'max_int_id',
    description: 'Use Number.MAX_SAFE_INTEGER as request id',
    run: async (send, proc) => {
      try {
        const res = await send({
          jsonrpc: '2.0', id: Number.MAX_SAFE_INTEGER, method: 'tools/call',
          params: { name: 'hello', arguments: { name: 'maxint' } },
        });
        const text = res?.result?.content?.[0]?.text || '';
        if (text.includes('Hello, maxint!')) return 'survived';
        return 'corrupted';
      } catch {
        return healthCheck(send, 20014);
      }
    },
  },
  {
    name: 'float_id',
    description: 'Use float as request id',
    run: async (send, proc) => {
      try {
        await send({
          jsonrpc: '2.0', id: 3.14159, method: 'tools/call',
          params: { name: 'hello', arguments: { name: 'float' } },
        });
      } catch {}
      return healthCheck(send, 20015);
    },
  },
  {
    name: 'string_id',
    description: 'Use string as request id (valid per JSON-RPC spec)',
    run: async (send, proc) => {
      sendRaw(proc, JSON.stringify({
        jsonrpc: '2.0', id: 'string-id-test', method: 'tools/call',
        params: { name: 'hello', arguments: { name: 'stringid' } },
      }) + '\n');
      await new Promise(r => setTimeout(r, 500));
      return healthCheck(send, 20016);
    },
  },
  {
    name: 'empty_string_args',
    description: 'All arguments are empty strings',
    run: async (send, proc) => {
      try {
        await send({
          jsonrpc: '2.0', id: 20017, method: 'tools/call',
          params: { name: 'hello', arguments: { name: '' } },
        });
      } catch {}
      return healthCheck(send, 20018);
    },
  },
  {
    name: 'array_arguments',
    description: 'Send arguments as array instead of object',
    run: async (send, proc) => {
      sendRaw(proc, JSON.stringify({
        jsonrpc: '2.0', id: 20019, method: 'tools/call',
        params: { name: 'hello', arguments: ['not', 'an', 'object'] },
      }) + '\n');
      await new Promise(r => setTimeout(r, 300));
      return healthCheck(send, 20020);
    },
  },
  {
    name: 'boolean_arguments',
    description: 'Send arguments as boolean instead of object',
    run: async (send, proc) => {
      sendRaw(proc, JSON.stringify({
        jsonrpc: '2.0', id: 20021, method: 'tools/call',
        params: { name: 'hello', arguments: true },
      }) + '\n');
      await new Promise(r => setTimeout(r, 300));
      return healthCheck(send, 20022);
    },
  },
  {
    name: 'number_arguments',
    description: 'Send arguments as number instead of object',
    run: async (send, proc) => {
      sendRaw(proc, JSON.stringify({
        jsonrpc: '2.0', id: 20023, method: 'tools/call',
        params: { name: 'hello', arguments: 42 },
      }) + '\n');
      await new Promise(r => setTimeout(r, 300));
      return healthCheck(send, 20024);
    },
  },
];

// --- Runner ---

async function runSuite(command, args) {
  console.log(`\nZeroMCP Chaos Monkey — Level 2 (Stress)`);
  console.log(`Command: ${command} ${args.join(' ')}`);
  console.log(`Attacks: ${attacks.length}\n`);

  let passed = 0;
  let failed = 0;
  const results = [];

  for (const attack of attacks) {
    // Fresh server per attack
    const proc = spawn(command, args, {
      stdio: ['pipe', 'pipe', 'pipe'],
      cwd: process.env.CHAOS_CWD || root,
    });

    const send = createHandler(proc);

    // Wait for startup
    await new Promise(r => setTimeout(r, 500));

    // Initialize
    try {
      await send({
        jsonrpc: '2.0', id: 0, method: 'initialize',
        params: {
          protocolVersion: '2024-11-05', capabilities: {},
          clientInfo: { name: 'chaos-l2', version: '1.0' },
        },
      });
      sendRaw(proc, JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
    } catch {
      console.log(`  ✗ ${attack.name} — server failed to initialize`);
      proc.kill();
      failed++;
      results.push({ name: attack.name, result: 'crashed', description: attack.description });
      continue;
    }

    // Run attack
    let result;
    try {
      result = await attack.run(send, proc);
    } catch (err) {
      result = 'crashed';
    }

    const icon = result === 'survived' ? '✓' : result === 'degraded' ? '~' : '✗';
    console.log(`  ${icon} ${attack.name} — ${result} (${attack.description})`);

    if (result === 'survived' || result === 'degraded') {
      passed++;
    } else {
      failed++;
    }

    results.push({ name: attack.name, result, description: attack.description });

    proc.kill();
    await new Promise(r => setTimeout(r, 200));
  }

  console.log(`\nResults: ${passed}/${attacks.length} passed, ${failed} failed`);
  return { passed, failed, total: attacks.length, results };
}

// --- Main ---

const cmdArgs = process.argv.slice(2);
if (cmdArgs.length === 0) {
  console.error('Usage: node tests/chaos/level2.js <command> [args...]');
  console.error('  e.g. node tests/chaos/level2.js node bin/mcp.js serve examples/tools');
  process.exit(1);
}

const [cmd, ...rest] = cmdArgs;
const { passed, total } = await runSuite(cmd, rest);
process.exit(passed === total ? 0 : 1);
