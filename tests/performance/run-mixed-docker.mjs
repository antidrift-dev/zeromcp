#!/usr/bin/env node

/**
 * ZeroMCP Mixed Workload — All 10 Languages
 * Server in Docker, client on host, HTTP.
 *
 * Usage: node tests/performance/run-mixed-docker.mjs [--language "Node.js"]
 *   ENV DURATION (default 300)
 *   ENV INTERVAL (default 10)
 */

import { execSync } from 'node:child_process';

const DURATION = parseInt(process.env.DURATION || '300');
const INTERVAL = parseInt(process.env.INTERVAL || '10');
const PORT = 3000;
const WARMUP = 100;
const IMAGE = 'zeromcp-mixed';

const langFilter = process.argv.find((a, i) => process.argv[i - 1] === '--language');

// Each entry: name, docker run args to start an HTTP server on port 3000
const SERVERS = [
  {
    name: 'Node.js',
    cmd: `node -e "
      import {createHandler} from '/zeromcp/nodejs/dist/handler.js';
      import {createServer} from 'http';
      const handler = await createHandler({
        tools: ['/zeromcp/nodejs/examples/tools'],
        resources: ['/zeromcp/nodejs/examples/resources'],
        prompts: ['/zeromcp/nodejs/examples/prompts']
      });
      createServer(async (req,res) => {
        if(req.url==='/health'){res.writeHead(200).end('{\"status\":\"ok\"}');return}
        if(req.method==='POST'&&req.url==='/mcp'){
          let b='';for await(const c of req)b+=c;
          const r=await handler(JSON.parse(b));
          res.writeHead(200,{'Content-Type':'application/json'}).end(JSON.stringify(r||{}));return}
        res.writeHead(404).end();
      }).listen(3000,()=>console.error('ready'));
    "`,
  },
  {
    name: 'Python',
    cmd: `python3 -c "
import sys,os,asyncio,json
sys.path.insert(0,'/zeromcp/python')
from zeromcp.server import create_handler
from http.server import HTTPServer,BaseHTTPRequestHandler
import threading

handler = None

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path=='/health':
            self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers()
            self.wfile.write(b'{\"status\":\"ok\"}')
        else: self.send_response(404);self.end_headers()
    def do_POST(self):
        l=int(self.headers.get('Content-Length',0));body=json.loads(self.rfile.read(l))
        loop=asyncio.new_event_loop();r=loop.run_until_complete(handler(body));loop.close()
        self.send_response(200);self.send_header('Content-Type','application/json');self.end_headers()
        self.wfile.write(json.dumps(r or {}).encode())
    def log_message(self,*a):pass

async def main():
    global handler
    handler=await create_handler({'tools':['/zeromcp/python/examples/tools'],'resources':['/zeromcp/tests/conformance/test-resources-python'],'prompts':['/zeromcp/tests/conformance/test-prompts-python']})
    s=HTTPServer(('0.0.0.0',3000),H);sys.stderr.write('ready\n');s.serve_forever()
asyncio.run(main())
"`,
    env: 'PYTHONPATH=/zeromcp/python PYTHONUNBUFFERED=1',
  },
  {
    name: 'Go',
    cmd: 'PORT=3000 /usr/local/bin/zeromcp-go-resource',
  },
  {
    name: 'Ruby',
    cmd: `ruby -I /zeromcp/ruby/lib -e "
require 'zeromcp';require 'webrick';require 'json'
config = ZeroMcp::Config.new(JSON.parse(File.read('/zeromcp/tests/conformance/resource-config-ruby.json')))
server = ZeroMcp::Server.new(config)
server.load_tools
ws = WEBrick::HTTPServer.new(Port:3000,Logger:WEBrick::Log.new('/dev/null'),AccessLog:[])
ws.mount_proc('/health'){|r,res|res.body='{\"status\":\"ok\"}'}
ws.mount_proc('/mcp'){|req,res|
  body=JSON.parse(req.body)
  result=server.handle_request(body)
  res['Content-Type']='application/json'
  res.body=(result||{}).to_json
}
STDERR.puts 'ready'
ws.start
"`,
  },
  {
    name: 'PHP',
    cmd: 'php -S 0.0.0.0:3000 /zeromcp/php/examples/http-server.php',
    skip: true, // needs a PHP HTTP wrapper — skip for now
  },
  {
    name: 'Rust',
    cmd: '/zeromcp/rust/target/release/examples/resource_test',
    stdio: true, // Rust resource_test is stdio only
    skip: true,
  },
  {
    name: 'Java',
    cmd: 'java -Dfile.encoding=UTF-8 -cp /zeromcp/java/target/zeromcp-0.1.1.jar:/zeromcp/java/target/deps/*:/tmp/java-out ResourceTest',
    stdio: true,
    skip: true,
  },
  {
    name: 'Kotlin',
    cmd: 'ZEROMCP_RESOURCE_TEST=true /zeromcp/kotlin/example/build/install/example/bin/example',
    stdio: true,
    skip: true,
  },
  {
    name: 'Swift',
    cmd: '/usr/local/bin/zeromcp-swift-resource',
    stdio: true,
    skip: true,
  },
  {
    name: 'C#',
    cmd: '/tmp/csharp-resource-out/ResourceTest',
    stdio: true,
    skip: true,
  },
];

// --- Request pool ---

let _id = 1000;
function nextId() { return _id++; }

const POOL = [
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

function pickRequest() { return POOL[Math.floor(Math.random() * POOL.length)](); }
function percentile(s, p) { return s[Math.ceil(s.length * p / 100) - 1]; }
function round(v) { return Math.round(v * 100) / 100; }

function getDockerStats(name) {
  try {
    const raw = execSync(`docker stats --no-stream --format '{{.MemUsage}}|||{{.CPUPerc}}' ${name}`, { encoding: 'utf8', timeout: 5000 }).trim();
    const [m, c] = raw.split('|||');
    let mem = null;
    const mm = m.match(/([\d.]+)\s*(MiB|GiB)/);
    if (mm) { mem = parseFloat(mm[1]); if (mm[2] === 'GiB') mem *= 1024; mem = round(mem); }
    let cpu = null;
    const cm = c.match(/([\d.]+)%/);
    if (cm) cpu = round(parseFloat(cm[1]));
    return { mem, cpu };
  } catch { return { mem: null, cpu: null }; }
}

async function waitForHealth(timeout = 30000) {
  const start = Date.now();
  while (Date.now() - start < timeout) {
    try {
      const res = await fetch(`http://127.0.0.1:${PORT}/health`);
      if (res.ok) return true;
    } catch {}
    await new Promise(r => setTimeout(r, 500));
  }
  return false;
}

async function benchmark(name, containerName) {
  async function req(body) {
    const res = await fetch(`http://127.0.0.1:${PORT}/mcp`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    return res.json();
  }

  // Init + warmup
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
      const stats = getDockerStats(containerName);
      const snap = {
        t: Math.round((performance.now() - t0) / 1000),
        rps: Math.round(latencies.length / INTERVAL),
        p50: round(percentile(sorted, 50)),
        p99: round(percentile(sorted, 99)),
        errors,
        mem: stats.mem,
        cpu: stats.cpu,
      };
      snapshots.push(snap);
      console.error(`    t=${snap.t}s  rps=${snap.rps}  p50=${snap.p50}ms  p99=${snap.p99}ms  err=${snap.errors}  mem=${snap.mem}MB  cpu=${snap.cpu}%`);
      latencies = []; errors = 0; nextSnap += INTERVAL * 1000;
    }
  }

  const avg = Math.round(snapshots.reduce((s, x) => s + x.rps, 0) / snapshots.length);
  const avgP50 = round(snapshots.reduce((s, x) => s + x.p50, 0) / snapshots.length);
  const avgP99 = round(snapshots.reduce((s, x) => s + x.p99, 0) / snapshots.length);
  const mems = snapshots.map(s => s.mem).filter(Boolean);
  const avgCpu = round(snapshots.filter(s => s.cpu != null).reduce((s, x) => s + x.cpu, 0) / snapshots.filter(s => s.cpu != null).length);
  const totalErrors = snapshots.reduce((s, x) => s + x.errors, 0);

  console.error(`  DONE: avg=${avg} rps, p50=${avgP50}ms, p99=${avgP99}ms, mem=${Math.min(...mems)}-${Math.max(...mems)}MB, cpu=${avgCpu}%, errors=${totalErrors}`);

  return { name, avg_rps: avg, avg_p50_ms: avgP50, avg_p99_ms: avgP99, memory_mb: { min: Math.min(...mems), max: Math.max(...mems) }, avg_cpu_pct: avgCpu, total_errors: totalErrors, snapshots };
}

// --- Main ---

async function main() {
  console.error(`ZeroMCP Mixed Workload — Host to Docker, HTTP`);
  console.error(`  Duration: ${DURATION}s, Interval: ${INTERVAL}s\n`);

  const results = {};

  for (const server of SERVERS) {
    if (langFilter && server.name.toLowerCase() !== langFilter.toLowerCase()) continue;
    if (server.skip) {
      console.error(`=== ${server.name} === SKIPPED (needs HTTP server)\n`);
      continue;
    }

    const containerName = `bench-mixed-${server.name.toLowerCase().replace(/[^a-z]/g, '')}`;
    console.error(`=== ${server.name} ===`);

    try { execSync(`docker rm -f ${containerName} 2>/dev/null`, { stdio: 'pipe' }); } catch {}

    const envStr = server.env ? server.env.split(' ').map(e => `-e ${e}`).join(' ') : '';
    const dockerCmd = `docker run --rm -d --name ${containerName} -p ${PORT}:${PORT} ${envStr} ${IMAGE} sh -c '${server.cmd.replace(/'/g, "'\\''")}'`;

    try {
      execSync(dockerCmd, { stdio: 'pipe' });
    } catch (err) {
      console.error(`  Container start failed`);
      results[server.name] = { name: server.name, error: 'Container start failed' };
      continue;
    }

    const ready = await waitForHealth();
    if (!ready) {
      console.error(`  Server failed to start within 30s`);
      try { execSync(`docker logs ${containerName} 2>&1 | tail -5`, { stdio: 'inherit' }); } catch {}
      execSync(`docker rm -f ${containerName}`, { stdio: 'pipe' });
      results[server.name] = { name: server.name, error: 'Server failed to start' };
      continue;
    }

    console.error(`  Server ready`);

    try {
      results[server.name] = await benchmark(server.name, containerName);
    } catch (err) {
      console.error(`  ERROR: ${err.message}`);
      results[server.name] = { name: server.name, error: err.message };
    }

    execSync(`docker rm -f ${containerName}`, { stdio: 'pipe' });
    console.error('');
  }

  // Summary
  console.error(`\n=== Summary ===`);
  for (const [name, r] of Object.entries(results)) {
    if (r.error) console.error(`  ${name}: ERROR — ${r.error}`);
    else console.error(`  ${name}: ${r.avg_rps} rps, p50=${r.avg_p50_ms}ms, mem=${r.memory_mb?.min}-${r.memory_mb?.max}MB`);
  }

  console.log(JSON.stringify(results, null, 2));
}

main().catch(err => { console.error(err); process.exit(1); });
