#!/usr/bin/env node

/**
 * Run mixed workload benchmark against all 10 languages.
 * Each language's server starts inside the container, benchmark runs locally.
 *
 * Usage: node tests/performance/run-mixed-all.mjs [--language "Node.js"]
 *   ENV DURATION (default 300)
 *   ENV INTERVAL (default 10)
 */

import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';

const DURATION = parseInt(process.env.DURATION || '300');
const INTERVAL = parseInt(process.env.INTERVAL || '10');
const PORT = 3000;
const WARMUP = 100;

// Server configs: command to start each language's resource-test server
const SERVERS = [
  {
    name: 'Node.js',
    command: 'node',
    args: ['-e', `
      import {createHandler} from '/zeromcp/nodejs/dist/handler.js';
      import {createServer} from 'http';
      const handler = await createHandler({
        tools: ['/zeromcp/nodejs/examples/tools'],
        resources: ['/zeromcp/nodejs/examples/resources'],
        prompts: ['/zeromcp/nodejs/examples/prompts']
      });
      createServer(async (req,res) => {
        if(req.url==='/health'){res.writeHead(200).end('{"status":"ok"}');return}
        if(req.method==='POST'&&req.url==='/mcp'){
          let b='';for await(const c of req)b+=c;
          const r=await handler(JSON.parse(b));
          res.writeHead(200,{'Content-Type':'application/json'}).end(JSON.stringify(r||{}));return}
        res.writeHead(404).end();
      }).listen(${PORT},()=>console.error('ready'));
    `],
  },
  {
    name: 'Python',
    command: 'python3',
    args: ['-c', `
import sys, os, asyncio, json
sys.path.insert(0, '/zeromcp/python')
from zeromcp.server import create_handler

async def main():
    handler = await create_handler({
        "tools": ["/zeromcp/python/examples/tools"],
        "resources": ["/zeromcp/tests/conformance/test-resources-python"],
        "prompts": ["/zeromcp/tests/conformance/test-prompts-python"]
    })
    # Simple HTTP server
    from http.server import HTTPServer, BaseHTTPRequestHandler
    class H(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path == '/health':
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.end_headers()
                self.wfile.write(b'{"status":"ok"}')
            else:
                self.send_response(404)
                self.end_headers()
        def do_POST(self):
            length = int(self.headers.get('Content-Length', 0))
            body = json.loads(self.rfile.read(length))
            loop = asyncio.new_event_loop()
            result = loop.run_until_complete(handler(body))
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(result or {}).encode())
            loop.close()
        def log_message(self, *a): pass
    server = HTTPServer(('0.0.0.0', ${PORT}), H)
    sys.stderr.write('ready\\n')
    server.serve_forever()

asyncio.run(main())
    `],
    env: { PYTHONPATH: '/zeromcp/python', PYTHONUNBUFFERED: '1' },
  },
  {
    name: 'Go',
    command: '/usr/local/bin/zeromcp-go-resource',
    args: [],
    env: { PORT: String(PORT) },
    needsHttp: true, // Go resource-test serves HTTP directly
  },
  {
    name: 'Ruby',
    command: 'ruby',
    args: ['-I', '/zeromcp/ruby/lib', '/zeromcp/ruby/bin/zeromcp', 'serve', '--config', '/zeromcp/tests/conformance/resource-config-ruby.json'],
    stdio: true,
  },
  {
    name: 'PHP',
    command: 'php',
    args: ['/zeromcp/php/zeromcp.php', 'serve', '--config', '/zeromcp/tests/conformance/resource-config-php.json'],
    stdio: true,
  },
  {
    name: 'Rust',
    command: '/zeromcp/rust/target/release/examples/resource_test',
    args: [],
    stdio: true,
  },
  {
    name: 'Java',
    command: 'java',
    args: ['-Dfile.encoding=UTF-8', '-cp', '/zeromcp/java/target/zeromcp-0.1.1.jar:/zeromcp/java/target/deps/*:/tmp/java-out', 'ResourceTest'],
    stdio: true,
  },
  {
    name: 'Kotlin',
    command: '/zeromcp/kotlin/example/build/install/example/bin/example',
    args: [],
    env: { JAVA_TOOL_OPTIONS: '-Dfile.encoding=UTF-8', ZEROMCP_RESOURCE_TEST: 'true' },
    stdio: true,
  },
  {
    name: 'Swift',
    command: '/usr/local/bin/zeromcp-swift-resource',
    args: [],
    stdio: true,
  },
  {
    name: 'C#',
    command: '/tmp/csharp-resource-out/ResourceTest',
    args: [],
    stdio: true,
  },
];

// --- Utilities ---

function percentile(sorted, p) {
  if (!sorted.length) return 0;
  return sorted[Math.ceil(sorted.length * p / 100) - 1];
}
function round(v, d = 2) { return Math.round(v * 10 ** d) / 10 ** d; }

let _id = 1000;
function nextId() { return _id++; }

const REQUEST_POOL = [
  ...Array(40).fill(() => ({ jsonrpc: '2.0', id: nextId(), method: 'tools/call', params: { name: 'hello', arguments: { name: 'bench' } } })),
  ...Array(15).fill(() => ({ jsonrpc: '2.0', id: nextId(), method: 'tools/call', params: { name: 'add', arguments: { a: 42, b: 58 } } })),
  ...Array(10).fill(() => ({ jsonrpc: '2.0', id: nextId(), method: 'tools/list' })),
  ...Array(10).fill(() => ({ jsonrpc: '2.0', id: nextId(), method: 'resources/list' })),
  ...Array(10).fill(() => ({ jsonrpc: '2.0', id: nextId(), method: 'resources/read', params: { uri: 'resource:///data.json' } })),
  ...Array(5).fill(() => ({ jsonrpc: '2.0', id: nextId(), method: 'prompts/list' })),
  ...Array(5).fill(() => ({ jsonrpc: '2.0', id: nextId(), method: 'prompts/get', params: { name: 'greet', arguments: { name: 'Alice' } } })),
  ...Array(3).fill(() => ({ jsonrpc: '2.0', id: nextId(), method: 'ping' })),
  ...Array(2).fill(() => ({ jsonrpc: '2.0', id: nextId(), method: 'initialize', params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'bench', version: '1.0' } } })),
];

function pickRequest() { return REQUEST_POOL[Math.floor(Math.random() * REQUEST_POOL.length)](); }

// --- HTTP benchmark for servers that serve HTTP ---

async function benchmarkHttp(name, url) {
  async function req(body) {
    const res = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
    return res.json();
  }

  await req({ jsonrpc: '2.0', id: 0, method: 'initialize', params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'bench', version: '1.0' } } });
  for (let i = 0; i < WARMUP; i++) try { await req(pickRequest()); } catch {}

  const snapshots = [];
  let latencies = [];
  let errors = 0;
  const t0 = performance.now();
  let nextSnap = INTERVAL * 1000;

  while (performance.now() - t0 < DURATION * 1000) {
    const start = performance.now();
    try { await req(pickRequest()); latencies.push(performance.now() - start); } catch { latencies.push(performance.now() - start); errors++; }
    if (performance.now() - t0 >= nextSnap) {
      const sorted = [...latencies].sort((a, b) => a - b);
      snapshots.push({ t: Math.round((performance.now() - t0) / 1000), rps: Math.round(latencies.length / INTERVAL), p50: round(percentile(sorted, 50)), p99: round(percentile(sorted, 99)), errors });
      console.error(`    t=${snapshots.at(-1).t}s  rps=${snapshots.at(-1).rps}  p50=${snapshots.at(-1).p50}ms  err=${snapshots.at(-1).errors}`);
      latencies = []; errors = 0; nextSnap += INTERVAL * 1000;
    }
  }
  const avg = Math.round(snapshots.reduce((s, x) => s + x.rps, 0) / snapshots.length);
  console.error(`  DONE: avg=${avg} rps`);
  return { name, avg_rps: avg, snapshots };
}

// --- Stdio benchmark (proxy through stdin/stdout) ---

async function benchmarkStdio(name, proc) {
  const { createInterface } = await import('node:readline');
  const rl = createInterface({ input: proc.stdout });
  const pending = [];

  rl.on('line', (line) => {
    const trimmed = line.trim();
    if (!trimmed) return;
    try {
      const msg = JSON.parse(trimmed);
      if (msg.id !== undefined && pending.length > 0) {
        const { resolve, timer } = pending.shift();
        clearTimeout(timer);
        resolve(msg);
      }
    } catch {}
  });

  function send(body) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { pending.shift(); reject(new Error('Timeout')); }, 5000);
      pending.push({ resolve, timer });
      proc.stdin.write(JSON.stringify(body) + '\n');
    });
  }

  // Init
  await send({ jsonrpc: '2.0', id: 0, method: 'initialize', params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'bench', version: '1.0' } } });
  proc.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');

  for (let i = 0; i < WARMUP; i++) try { await send(pickRequest()); } catch {}

  const snapshots = [];
  let latencies = [];
  let errors = 0;
  const t0 = performance.now();
  let nextSnap = INTERVAL * 1000;

  while (performance.now() - t0 < DURATION * 1000) {
    const start = performance.now();
    try { await send(pickRequest()); latencies.push(performance.now() - start); } catch { latencies.push(performance.now() - start); errors++; }
    if (performance.now() - t0 >= nextSnap) {
      const sorted = [...latencies].sort((a, b) => a - b);
      snapshots.push({ t: Math.round((performance.now() - t0) / 1000), rps: Math.round(latencies.length / INTERVAL), p50: round(percentile(sorted, 50)), p99: round(percentile(sorted, 99)), errors });
      console.error(`    t=${snapshots.at(-1).t}s  rps=${snapshots.at(-1).rps}  p50=${snapshots.at(-1).p50}ms  err=${snapshots.at(-1).errors}`);
      latencies = []; errors = 0; nextSnap += INTERVAL * 1000;
    }
  }
  const avg = Math.round(snapshots.reduce((s, x) => s + x.rps, 0) / snapshots.length);
  console.error(`  DONE: avg=${avg} rps`);
  return { name, avg_rps: avg, snapshots };
}

// --- Main ---

async function main() {
  console.error(`ZeroMCP Mixed Workload — All 10 Languages`);
  console.error(`  Duration: ${DURATION}s, Interval: ${INTERVAL}s\n`);

  const langFilter = process.argv.find((a, i) => process.argv[i - 1] === '--language');
  const results = {};

  for (const server of SERVERS) {
    if (langFilter && server.name.toLowerCase() !== langFilter.toLowerCase()) continue;
    console.error(`=== ${server.name} ===`);

    const env = { ...process.env, PORT: String(PORT), ...(server.env || {}) };
    const proc = spawn(server.command, server.args, { stdio: ['pipe', 'pipe', 'pipe'], env });

    proc.stderr.on('data', (d) => {
      const msg = d.toString().trim();
      if (msg) console.error(`  [${server.name}] ${msg.slice(0, 100)}`);
    });

    // Wait for startup
    await new Promise(r => setTimeout(r, server.name === 'Java' || server.name === 'Kotlin' ? 5000 : 2000));

    try {
      if (server.stdio) {
        results[server.name] = await benchmarkStdio(server.name, proc);
      } else if (server.needsHttp) {
        // Wait for HTTP server
        for (let i = 0; i < 20; i++) {
          try { await fetch(`http://127.0.0.1:${PORT}/health`); break; } catch { await new Promise(r => setTimeout(r, 500)); }
        }
        results[server.name] = await benchmarkHttp(server.name, `http://127.0.0.1:${PORT}/mcp`);
      } else {
        // Node/Python start their own HTTP servers
        for (let i = 0; i < 20; i++) {
          try { await fetch(`http://127.0.0.1:${PORT}/health`); break; } catch { await new Promise(r => setTimeout(r, 500)); }
        }
        results[server.name] = await benchmarkHttp(server.name, `http://127.0.0.1:${PORT}/mcp`);
      }
    } catch (err) {
      console.error(`  ERROR: ${err.message}`);
      results[server.name] = { name: server.name, error: err.message };
    }

    proc.kill();
    await new Promise(r => setTimeout(r, 500));
    console.error('');
  }

  // Summary
  console.error(`\n=== Summary ===`);
  for (const [name, r] of Object.entries(results)) {
    if (r.error) console.error(`  ${name}: ERROR — ${r.error}`);
    else console.error(`  ${name}: ${r.avg_rps} rps`);
  }

  console.log(JSON.stringify(results, null, 2));
}

main().catch(err => { console.error(err); process.exit(1); });
