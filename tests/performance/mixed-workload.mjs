#!/usr/bin/env node

/**
 * ZeroMCP Mixed Workload Benchmark
 * Simulates realistic traffic: tools, resources, prompts, discovery, health checks.
 * Server in Docker, client on host, Docker stats for memory/CPU.
 *
 * Usage: node tests/performance/mixed-workload.mjs [url] [duration] [interval]
 *   Default: http://127.0.0.1:3000/mcp 300s 10s
 *
 * ENV: CONTAINER_NAME (for Docker stats, default: bench-mixed)
 */

import { execSync } from 'node:child_process';

const BASE_URL = process.argv[2] || 'http://127.0.0.1:3000/mcp';
const DURATION = parseInt(process.argv[3] || '300');
const INTERVAL = parseInt(process.argv[4] || '10');
const CONTAINER = process.env.CONTAINER_NAME || 'bench-mixed';
const WARMUP = 100;

// --- Weighted request pool ---

const REQUESTS = [
  // 40% — tools/call hello (simple)
  ...Array(40).fill(() => ({
    jsonrpc: '2.0', id: nextId(), method: 'tools/call',
    params: { name: 'hello', arguments: { name: 'bench' } },
  })),
  // 15% — tools/call add (compute)
  ...Array(15).fill(() => ({
    jsonrpc: '2.0', id: nextId(), method: 'tools/call',
    params: { name: 'add', arguments: { a: Math.random() * 100, b: Math.random() * 100 } },
  })),
  // 10% — tools/call create_invoice (object)
  ...Array(10).fill(() => ({
    jsonrpc: '2.0', id: nextId(), method: 'tools/call',
    params: { name: 'create_invoice', arguments: { customer_id: 'cust-123', amount: 99.99 } },
  })),
  // 10% — resources/read
  ...Array(10).fill(() => ({
    jsonrpc: '2.0', id: nextId(), method: 'resources/read',
    params: { uri: 'resource:///config.json' },
  })),
  // 10% — tools/list
  ...Array(10).fill(() => ({
    jsonrpc: '2.0', id: nextId(), method: 'tools/list',
  })),
  // 5% — prompts/get
  ...Array(5).fill(() => ({
    jsonrpc: '2.0', id: nextId(), method: 'prompts/get',
    params: { name: 'summarize', arguments: { text: 'ZeroMCP is fast', style: 'brief' } },
  })),
  // 5% — resources/list
  ...Array(5).fill(() => ({
    jsonrpc: '2.0', id: nextId(), method: 'resources/list',
  })),
  // 3% — ping
  ...Array(3).fill(() => ({
    jsonrpc: '2.0', id: nextId(), method: 'ping',
  })),
  // 2% — initialize (new connection sim)
  ...Array(2).fill(() => ({
    jsonrpc: '2.0', id: nextId(), method: 'initialize',
    params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'bench', version: '1.0' } },
  })),
];

let _id = 1000;
function nextId() { return _id++; }

function pickRequest() {
  const idx = Math.floor(Math.random() * REQUESTS.length);
  return REQUESTS[idx]();
}

// --- Utilities ---

function percentile(sorted, p) {
  if (!sorted.length) return 0;
  return sorted[Math.ceil(sorted.length * p / 100) - 1];
}

function round(v, d = 2) {
  return Math.round(v * 10 ** d) / 10 ** d;
}

function getDockerStats() {
  try {
    const raw = execSync(
      `docker stats --no-stream --format '{{.MemUsage}}|||{{.CPUPerc}}' ${CONTAINER}`,
      { encoding: 'utf8', timeout: 5000 }
    ).trim();
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

async function mcpRequest(body) {
  const res = await fetch(BASE_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  return res.json();
}

// --- Main ---

async function main() {
  console.error(`ZeroMCP Mixed Workload Benchmark`);
  console.error(`  URL: ${BASE_URL}`);
  console.error(`  Duration: ${DURATION}s, Interval: ${INTERVAL}s`);
  console.error(`  Container: ${CONTAINER}`);
  console.error(`  Mix: 40% hello, 15% add, 10% invoice, 10% resource read,`);
  console.error(`       10% tools/list, 5% prompts/get, 5% resources/list, 3% ping, 2% init\n`);

  // Initialize session
  await mcpRequest({
    jsonrpc: '2.0', id: 0, method: 'initialize',
    params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'bench-mixed', version: '1.0' } },
  });

  // Warmup
  console.error(`  Warming up (${WARMUP} requests)...`);
  for (let i = 0; i < WARMUP; i++) {
    try { await mcpRequest(pickRequest()); } catch {}
  }

  // Benchmark
  const snapshots = [];
  let latencies = [];
  let methodCounts = {};
  let errors = 0;
  const t0 = performance.now();
  let nextSnap = INTERVAL * 1000;

  console.error(`  Running for ${DURATION}s...\n`);

  while (performance.now() - t0 < DURATION * 1000) {
    const req = pickRequest();
    const method = req.method;
    const start = performance.now();

    try {
      const res = await mcpRequest(req);
      latencies.push(performance.now() - start);
      methodCounts[method] = (methodCounts[method] || 0) + 1;
      if (res?.error) errors++;
    } catch {
      latencies.push(performance.now() - start);
      errors++;
    }

    if (performance.now() - t0 >= nextSnap) {
      const sorted = [...latencies].sort((a, b) => a - b);
      const stats = getDockerStats();

      const snap = {
        t: Math.round((performance.now() - t0) / 1000),
        requests: latencies.length,
        rps: Math.round(latencies.length / INTERVAL),
        p50_ms: round(percentile(sorted, 50)),
        p95_ms: round(percentile(sorted, 95)),
        p99_ms: round(percentile(sorted, 99)),
        errors,
        memory_mb: stats.mem,
        cpu_pct: stats.cpu,
      };
      snapshots.push(snap);

      console.error(`    t=${snap.t}s  rps=${snap.rps}  p50=${snap.p50_ms}ms  p99=${snap.p99_ms}ms  err=${snap.errors}  mem=${snap.memory_mb}MB  cpu=${snap.cpu_pct}%`);

      latencies = [];
      errors = 0;
      nextSnap += INTERVAL * 1000;
    }
  }

  // Summary
  const avgRps = snapshots.length > 0
    ? Math.round(snapshots.reduce((s, x) => s + x.rps, 0) / snapshots.length)
    : 0;
  const avgP50 = snapshots.length > 0
    ? round(snapshots.reduce((s, x) => s + x.p50_ms, 0) / snapshots.length)
    : 0;
  const avgP99 = snapshots.length > 0
    ? round(snapshots.reduce((s, x) => s + x.p99_ms, 0) / snapshots.length)
    : 0;
  const mems = snapshots.map(s => s.memory_mb).filter(Boolean);
  const avgCpu = snapshots.length > 0
    ? round(snapshots.filter(s => s.cpu_pct != null).reduce((s, x) => s + x.cpu_pct, 0) / snapshots.filter(s => s.cpu_pct != null).length)
    : 0;
  const totalErrors = snapshots.reduce((s, x) => s + x.errors, 0);

  console.error(`\n  DONE:`);
  console.error(`    avg ${avgRps} rps, p50=${avgP50}ms, p99=${avgP99}ms`);
  console.error(`    mem=${Math.min(...mems)}-${Math.max(...mems)}MB, cpu=${avgCpu}%`);
  console.error(`    errors=${totalErrors}`);
  console.error(`    methods: ${JSON.stringify(methodCounts)}`);

  // JSON output
  console.log(JSON.stringify({
    type: 'mixed-workload',
    url: BASE_URL,
    duration_s: DURATION,
    avg_rps: avgRps,
    avg_p50_ms: avgP50,
    avg_p99_ms: avgP99,
    memory_mb: mems.length > 0 ? { min: Math.min(...mems), max: Math.max(...mems) } : null,
    avg_cpu_pct: avgCpu,
    total_errors: totalErrors,
    method_counts: methodCounts,
    snapshots,
  }, null, 2));
}

main().catch(err => { console.error(err); process.exit(1); });
