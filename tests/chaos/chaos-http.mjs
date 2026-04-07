#!/usr/bin/env node

/**
 * ZeroMCP Chaos Monkey — HTTP version
 * Runs Level 1 (22 attacks) or Level 2 (15 attacks) over HTTP POST.
 * Server must be running on the specified URL.
 *
 * Usage: node chaos-http.mjs [--level 1|2] [url]
 *   Default: both levels, URL http://127.0.0.1:3000/mcp
 */

const args = process.argv.slice(2);
let level = 0; // 0 = both
let urlArg = null;
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--level' && args[i+1]) { level = parseInt(args[++i]); }
  else if (!urlArg) { urlArg = args[i]; }
}
const BASE_URL = urlArg || 'http://127.0.0.1:3000/mcp';
const TIMEOUT = 10000;

async function mcpPost(body, timeoutMs = TIMEOUT) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(BASE_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
      },
      body: typeof body === 'string' ? body : JSON.stringify(body),
      signal: controller.signal,
    });
    clearTimeout(timer);
    const ct = res.headers.get('content-type') || '';
    if (ct.includes('text/event-stream')) {
      const text = await res.text();
      for (const line of text.split('\n')) {
        if (line.startsWith('data: ')) {
          try { return JSON.parse(line.slice(6)); } catch {}
        }
      }
      return null;
    }
    return res.json().catch(() => ({ status: res.status }));
  } catch (err) {
    clearTimeout(timer);
    throw err;
  }
}

async function rawPost(body, contentType = 'application/json') {
  try {
    await fetch(BASE_URL, {
      method: 'POST',
      headers: { 'Content-Type': contentType },
      body,
      signal: AbortSignal.timeout(5000),
    });
  } catch {}
}

let sessionId = null;
let nextId = 1;

async function initSession() {
  try {
    const res = await fetch(BASE_URL, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
      },
      body: JSON.stringify({
        jsonrpc: '2.0', id: nextId++, method: 'initialize',
        params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'chaos', version: '1.0' } },
      }),
    });
    const sid = res.headers.get('mcp-session-id');
    if (sid) sessionId = sid;

    // Send initialized notification
    const headers = { 'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream' };
    if (sessionId) headers['Mcp-Session-Id'] = sessionId;
    await fetch(BASE_URL, { method: 'POST', headers, body: JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) });
    return true;
  } catch { return false; }
}

async function healthCheck() {
  try {
    const id = nextId++;
    const headers = { 'Content-Type': 'application/json', 'Accept': 'application/json, text/event-stream' };
    if (sessionId) headers['Mcp-Session-Id'] = sessionId;
    const res = await fetch(BASE_URL, {
      method: 'POST', headers,
      body: JSON.stringify({ jsonrpc: '2.0', id, method: 'tools/call', params: { name: 'hello', arguments: { name: 'healthcheck' } } }),
      signal: AbortSignal.timeout(TIMEOUT),
    });
    const ct = res.headers.get('content-type') || '';
    let data;
    if (ct.includes('text/event-stream')) {
      const text = await res.text();
      for (const line of text.split('\n')) {
        if (line.startsWith('data: ')) { try { data = JSON.parse(line.slice(6)); break; } catch {} }
      }
    } else {
      data = await res.json();
    }
    const text = data?.result?.content?.[0]?.text || '';
    if (text.includes('Hello, healthcheck!')) return 'survived';
    return 'corrupted';
  } catch { return 'crashed'; }
}

// --- Level 1 Attacks (22) — Protocol chaos, malformed input, abuse ---

const level1 = [
  { name: 'malformed_json', run: async () => { await rawPost('{{{{not json!!!!'); await new Promise(r => setTimeout(r, 200)); return healthCheck(); }},
  { name: 'truncated_json', run: async () => { await rawPost('{"jsonrpc":"2.0","id":1,"meth'); await new Promise(r => setTimeout(r, 200)); return healthCheck(); }},
  { name: 'empty_body', run: async () => { await rawPost(''); await new Promise(r => setTimeout(r, 200)); return healthCheck(); }},
  { name: 'missing_id', run: async () => { await rawPost(JSON.stringify({ jsonrpc: '2.0', method: 'tools/call', params: { name: 'hello', arguments: { name: 'noid' } } })); await new Promise(r => setTimeout(r, 200)); return healthCheck(); }},
  { name: 'missing_method', run: async () => { try { await mcpPost({ jsonrpc: '2.0', id: nextId++ }); } catch {} return healthCheck(); }},
  { name: 'null_id', run: async () => { await rawPost(JSON.stringify({ jsonrpc: '2.0', id: null, method: 'tools/call', params: { name: 'hello', arguments: { name: 'nullid' } } })); await new Promise(r => setTimeout(r, 200)); return healthCheck(); }},
  { name: 'negative_id', run: async () => { try { await mcpPost({ jsonrpc: '2.0', id: -1, method: 'tools/call', params: { name: 'hello', arguments: { name: 'neg' } } }); } catch {} return healthCheck(); }},
  { name: 'duplicate_id', run: async () => { mcpPost({ jsonrpc: '2.0', id: 99999, method: 'tools/call', params: { name: 'hello', arguments: { name: 'dup1' } } }).catch(()=>{}); await new Promise(r => setTimeout(r, 100)); try { await mcpPost({ jsonrpc: '2.0', id: 99999, method: 'tools/call', params: { name: 'hello', arguments: { name: 'dup2' } } }); } catch {} return healthCheck(); }},
  { name: 'double_initialize', run: async () => { try { await mcpPost({ jsonrpc: '2.0', id: nextId++, method: 'initialize', params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'chaos2', version: '1.0' } } }); } catch {} return healthCheck(); }},
  { name: 'unknown_method', run: async () => { try { await mcpPost({ jsonrpc: '2.0', id: nextId++, method: 'nonexistent/method' }); } catch {} return healthCheck(); }},
  { name: 'giant_string', run: async () => { try { await mcpPost({ jsonrpc: '2.0', id: nextId++, method: 'tools/call', params: { name: 'hello', arguments: { name: 'A'.repeat(1024*1024) } } }, 15000); } catch {} await new Promise(r => setTimeout(r, 500)); return healthCheck(); }},
  { name: 'deeply_nested', run: async () => { let n={v:'deep'}; for(let i=0;i<100;i++) n={c:n}; try { await mcpPost({ jsonrpc: '2.0', id: nextId++, method: 'tools/call', params: { name: 'hello', arguments: { name: n } } }); } catch {} return healthCheck(); }},
  { name: 'empty_tool_name', run: async () => { try { await mcpPost({ jsonrpc: '2.0', id: nextId++, method: 'tools/call', params: { name: '', arguments: {} } }); } catch {} return healthCheck(); }},
  { name: 'null_arguments', run: async () => { try { await mcpPost({ jsonrpc: '2.0', id: nextId++, method: 'tools/call', params: { name: 'hello', arguments: null } }); } catch {} return healthCheck(); }},
  { name: 'binary_garbage', run: async () => { const buf = new Uint8Array(256); for(let i=0;i<256;i++) buf[i]=Math.floor(Math.random()*256); await rawPost(buf, 'application/octet-stream'); await new Promise(r => setTimeout(r, 500)); return healthCheck(); }},
  { name: 'tool_throws', run: async () => { try { await mcpPost({ jsonrpc: '2.0', id: nextId++, method: 'tools/call', params: { name: 'nonexistent_tool_xyz', arguments: {} } }); } catch {} return healthCheck(); }},
  { name: 'wrong_jsonrpc_version', run: async () => { try { await mcpPost({ jsonrpc: '1.0', id: nextId++, method: 'tools/call', params: { name: 'hello', arguments: { name: 'v1' } } }); } catch {} return healthCheck(); }},
  { name: 'extra_fields', run: async () => { try { await mcpPost({ jsonrpc: '2.0', id: nextId++, method: 'tools/call', params: { name: 'hello', arguments: { name: 'extra' } }, extra: 'field', foo: [1,2,3] }); } catch {} return healthCheck(); }},
  { name: 'wrong_content_type', run: async () => { await rawPost(JSON.stringify({ jsonrpc: '2.0', id: nextId++, method: 'tools/call', params: { name: 'hello', arguments: { name: 'ct' } } }), 'text/plain'); await new Promise(r => setTimeout(r, 300)); return healthCheck(); }},
  { name: 'array_as_body', run: async () => { await rawPost(JSON.stringify([{ jsonrpc: '2.0', id: nextId++, method: 'tools/call', params: { name: 'hello', arguments: { name: 'arr' } } }])); await new Promise(r => setTimeout(r, 300)); return healthCheck(); }},
  { name: 'number_as_body', run: async () => { await rawPost('42'); await new Promise(r => setTimeout(r, 200)); return healthCheck(); }},
  { name: 'rapid_fire_100', run: async () => { const ps=[]; for(let i=0;i<100;i++) ps.push(mcpPost({ jsonrpc:'2.0', id:nextId++, method:'tools/call', params:{name:'hello',arguments:{name:'rapid'}} }, 15000).catch(()=>null)); await Promise.allSettled(ps); await new Promise(r=>setTimeout(r,500)); return healthCheck(); }},
];

// --- Level 2 Attacks (15) — Extreme payloads, concurrency, edge cases ---

const level2 = [
  { name: '10mb_payload', run: async () => { try { await mcpPost({ jsonrpc: '2.0', id: nextId++, method: 'tools/call', params: { name: 'hello', arguments: { name: 'A'.repeat(10*1024*1024) } } }, 15000); } catch {} await new Promise(r => setTimeout(r, 500)); return healthCheck(); }},
  { name: '1000_level_nesting', run: async () => { let n={v:'deep'}; for(let i=0;i<1000;i++) n={c:n}; try { await mcpPost({ jsonrpc: '2.0', id: nextId++, method: 'tools/call', params: { name: 'hello', arguments: { name: n } } }, 10000); } catch {} await new Promise(r => setTimeout(r, 500)); return healthCheck(); }},
  { name: '50_concurrent_calls', run: async () => { const ps=[]; for(let i=0;i<50;i++) ps.push(mcpPost({ jsonrpc:'2.0', id:nextId++, method:'tools/call', params:{name:'hello',arguments:{name:`c${i}`}} }).catch(()=>null)); await Promise.allSettled(ps); await new Promise(r=>setTimeout(r,500)); return healthCheck(); }},
  { name: 'unicode_emoji', run: async () => { try { await mcpPost({ jsonrpc: '2.0', id: nextId++, method: 'tools/call', params: { name: 'hello', arguments: { name: '🔥💀🎉 héllo wörld 你好 مرحبا' } } }); } catch {} return healthCheck(); }},
  { name: 'null_bytes', run: async () => { try { await mcpPost({ jsonrpc: '2.0', id: nextId++, method: 'tools/call', params: { name: 'hello', arguments: { name: 'before\x00after' } } }); } catch {} return healthCheck(); }},
  { name: 'interleaved_calls', run: async () => { const a = mcpPost({ jsonrpc:'2.0', id:nextId++, method:'tools/call', params:{name:'hello',arguments:{name:'slow'}} }).catch(()=>null); const b = mcpPost({ jsonrpc:'2.0', id:nextId++, method:'tools/call', params:{name:'hello',arguments:{name:'fast'}} }).catch(()=>null); await Promise.allSettled([a,b]); return healthCheck(); }},
  { name: '1000_rapid_fire', run: async () => { const ps=[]; for(let i=0;i<1000;i++) ps.push(mcpPost({ jsonrpc:'2.0', id:nextId++, method:'tools/call', params:{name:'hello',arguments:{name:'r'}} }, 30000).catch(()=>null)); const res = await Promise.allSettled(ps); const ok = res.filter(r=>r.status==='fulfilled'&&r.value).length; await new Promise(r=>setTimeout(r,500)); const h = await healthCheck(); if (h==='survived' && ok < 900) return 'degraded'; return h; }},
  { name: '10000_args', run: async () => { const a={}; for(let i=0;i<10000;i++) a[`k${i}`]=`v${i}`; try { await mcpPost({ jsonrpc: '2.0', id: nextId++, method: 'tools/call', params: { name: 'hello', arguments: a } }, 10000); } catch {} await new Promise(r => setTimeout(r, 500)); return healthCheck(); }},
  { name: 'max_int_id', run: async () => { try { const res = await mcpPost({ jsonrpc: '2.0', id: Number.MAX_SAFE_INTEGER, method: 'tools/call', params: { name: 'hello', arguments: { name: 'maxint' } } }); const t = res?.result?.content?.[0]?.text||''; if (t.includes('Hello, maxint!')) return 'survived'; return 'corrupted'; } catch { return healthCheck(); } }},
  { name: 'float_id', run: async () => { try { await mcpPost({ jsonrpc: '2.0', id: 3.14159, method: 'tools/call', params: { name: 'hello', arguments: { name: 'float' } } }); } catch {} return healthCheck(); }},
  { name: 'string_id', run: async () => { await rawPost(JSON.stringify({ jsonrpc: '2.0', id: 'string-id', method: 'tools/call', params: { name: 'hello', arguments: { name: 'sid' } } })); await new Promise(r => setTimeout(r, 500)); return healthCheck(); }},
  { name: 'empty_string_args', run: async () => { try { await mcpPost({ jsonrpc: '2.0', id: nextId++, method: 'tools/call', params: { name: 'hello', arguments: { name: '' } } }); } catch {} return healthCheck(); }},
  { name: 'array_arguments', run: async () => { await rawPost(JSON.stringify({ jsonrpc: '2.0', id: nextId++, method: 'tools/call', params: { name: 'hello', arguments: ['not','an','object'] } })); await new Promise(r => setTimeout(r, 300)); return healthCheck(); }},
  { name: 'boolean_arguments', run: async () => { await rawPost(JSON.stringify({ jsonrpc: '2.0', id: nextId++, method: 'tools/call', params: { name: 'hello', arguments: true } })); await new Promise(r => setTimeout(r, 300)); return healthCheck(); }},
  { name: 'number_arguments', run: async () => { await rawPost(JSON.stringify({ jsonrpc: '2.0', id: nextId++, method: 'tools/call', params: { name: 'hello', arguments: 42 } })); await new Promise(r => setTimeout(r, 300)); return healthCheck(); }},
];

const attacks = level === 1 ? level1 : level === 2 ? level2 : [...level1, ...level2];

// --- Run ---

async function main() {
  const label = level === 1 ? 'Level 1' : level === 2 ? 'Level 2' : 'Level 1 + 2';
  console.log(`\nChaos ${label} over HTTP — ${BASE_URL}`);
  console.log(`Attacks: ${attacks.length} (L1: ${level1.length}, L2: ${level2.length})\n`);

  const ok = await initSession();
  if (!ok) { console.log('Failed to initialize session'); process.exit(1); }

  let passed = 0, failed = 0;
  for (const a of attacks) {
    let result;
    try { result = await a.run(); } catch { result = 'crashed'; }
    const icon = result==='survived'?'✓':result==='degraded'?'~':'✗';
    console.log(`  ${icon} ${a.name} — ${result}`);
    result==='survived'||result==='degraded' ? passed++ : failed++;
  }
  console.log(`\nResults: ${passed}/${attacks.length} passed, ${failed} failed`);
  process.exit(failed > 0 ? 1 : 0);
}

main();
