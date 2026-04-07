#!/usr/bin/env node

/**
 * ZeroMCP Chaos Monkey — SSE protocol version
 * For frameworks that use SSE transport (Spring AI, fast-mcp Ruby, etc.)
 *
 * Usage: node chaos-sse.mjs <sse-url> [message-url]
 *   e.g. node chaos-sse.mjs http://127.0.0.1:3000/sse http://127.0.0.1:3000/mcp/message
 *
 * If message-url is not provided, it's discovered from the SSE endpoint event.
 */

const SSE_URL = process.argv[2];
const MSG_URL_OVERRIDE = process.argv[3];
const TIMEOUT = 10000;

if (!SSE_URL) {
  console.error('Usage: node chaos-sse.mjs <sse-url> [message-url]');
  process.exit(1);
}

const baseUrl = new URL(SSE_URL).origin;
let messageUrl = MSG_URL_OVERRIDE || null;
let sseController = null;
let nextId = 1;

// Connect to SSE and discover message endpoint
async function connectSSE() {
  return new Promise(async (resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('SSE connect timeout')), 15000);
    try {
      sseController = new AbortController();
      const res = await fetch(SSE_URL, {
        headers: { 'Accept': 'text/event-stream' },
        signal: sseController.signal,
      });

      const reader = res.body.getReader();
      const decoder = new TextDecoder();
      let buffer = '';

      const read = async () => {
        try {
          const { done, value } = await reader.read();
          if (done) return;
          buffer += decoder.decode(value, { stream: true });

          // Parse SSE events
          const lines = buffer.split('\n');
          buffer = lines.pop() || '';

          for (const line of lines) {
            if (line.startsWith('data:')) {
              const data = line.slice(5).trim();
              if (data.startsWith('/') || data.startsWith('http')) {
                // This is the endpoint URL
                if (!MSG_URL_OVERRIDE) {
                  messageUrl = data.startsWith('http') ? data : baseUrl + data;
                }
                clearTimeout(timer);
                resolve(true);
              }
            }
          }

          // Keep reading in background
          read();
        } catch {}
      };
      read();
    } catch (err) {
      clearTimeout(timer);
      reject(err);
    }
  });
}

// Track SSE responses
const sseResponses = new Map(); // id -> resolve function

function startSSEListener() {
  // We already have the SSE connection from connectSSE
  // For simplicity, we'll just POST and parse the JSON response directly
  // since the SSE connection is already consuming the stream
}

async function mcpPost(body, timeoutMs = TIMEOUT) {
  if (!messageUrl) throw new Error('No message URL discovered');

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await fetch(messageUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: typeof body === 'string' ? body : JSON.stringify(body),
      signal: controller.signal,
    });
    clearTimeout(timer);

    // Some SSE servers return 202 Accepted (response comes via SSE)
    // Others return the JSON directly
    if (res.status === 202 || res.status === 204) {
      // Response will come via SSE — wait a bit
      await new Promise(r => setTimeout(r, 500));
      return { status: res.status };
    }

    const text = await res.text();
    try { return JSON.parse(text); } catch { return { raw: text, status: res.status }; }
  } catch (err) {
    clearTimeout(timer);
    throw err;
  }
}

async function rawPost(body, contentType = 'application/json') {
  if (!messageUrl) return;
  try {
    await fetch(messageUrl, {
      method: 'POST',
      headers: { 'Content-Type': contentType },
      body,
      signal: AbortSignal.timeout(5000),
    });
  } catch {}
}

async function initSession() {
  try {
    await mcpPost({
      jsonrpc: '2.0', id: nextId++, method: 'initialize',
      params: { protocolVersion: '2024-11-05', capabilities: {}, clientInfo: { name: 'chaos-sse', version: '1.0' } },
    });
    await mcpPost({ jsonrpc: '2.0', method: 'notifications/initialized' });
    return true;
  } catch { return false; }
}

async function healthCheck() {
  try {
    const id = nextId++;
    const res = await fetch(messageUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id, method: 'tools/call', params: { name: 'hello', arguments: { name: 'healthcheck' } } }),
      signal: AbortSignal.timeout(TIMEOUT),
    });

    // Check if response is direct JSON or 202
    if (res.status === 202 || res.status === 204) {
      // SSE-routed response — we can't easily read it here
      // Just check the server didn't crash
      await new Promise(r => setTimeout(r, 500));
      // Try another request to see if server is alive
      const probe = await fetch(messageUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ jsonrpc: '2.0', id: nextId++, method: 'ping' }),
        signal: AbortSignal.timeout(5000),
      });
      return probe.ok || probe.status === 202 ? 'survived' : 'crashed';
    }

    const text = await res.text();
    let data;
    try { data = JSON.parse(text); } catch { return res.ok ? 'survived' : 'corrupted'; }

    const content = data?.result?.content?.[0]?.text || '';
    if (content.includes('Hello, healthcheck!')) return 'survived';

    // If server responded with something (even an error), it's alive
    if (data?.jsonrpc || data?.result || data?.error) return 'survived';

    return 'corrupted';
  } catch { return 'crashed'; }
}

// --- Attacks (same as HTTP version) ---

const attacks = [
  { name: 'malformed_json', run: async () => { await rawPost('{{{{not json!!!!'); await new Promise(r => setTimeout(r, 300)); return healthCheck(); }},
  { name: 'truncated_json', run: async () => { await rawPost('{"jsonrpc":"2.0","id":1,"meth'); await new Promise(r => setTimeout(r, 300)); return healthCheck(); }},
  { name: 'missing_id', run: async () => { await rawPost(JSON.stringify({ jsonrpc: '2.0', method: 'tools/call', params: { name: 'hello', arguments: { name: 'noid' } } })); await new Promise(r => setTimeout(r, 300)); return healthCheck(); }},
  { name: 'missing_method', run: async () => { try { await mcpPost({ jsonrpc: '2.0', id: nextId++ }); } catch {} return healthCheck(); }},
  { name: 'null_id', run: async () => { await rawPost(JSON.stringify({ jsonrpc: '2.0', id: null, method: 'tools/call', params: { name: 'hello', arguments: { name: 'n' } } })); await new Promise(r => setTimeout(r, 300)); return healthCheck(); }},
  { name: 'negative_id', run: async () => { try { await mcpPost({ jsonrpc: '2.0', id: -1, method: 'tools/call', params: { name: 'hello', arguments: { name: 'neg' } } }); } catch {} return healthCheck(); }},
  { name: 'unknown_method', run: async () => { try { await mcpPost({ jsonrpc: '2.0', id: nextId++, method: 'nonexistent/method' }); } catch {} return healthCheck(); }},
  { name: 'giant_string', run: async () => { try { await mcpPost({ jsonrpc: '2.0', id: nextId++, method: 'tools/call', params: { name: 'hello', arguments: { name: 'A'.repeat(1024*1024) } } }, 15000); } catch {} await new Promise(r => setTimeout(r, 500)); return healthCheck(); }},
  { name: 'deeply_nested', run: async () => { let n={v:'deep'}; for(let i=0;i<100;i++) n={c:n}; try { await mcpPost({ jsonrpc: '2.0', id: nextId++, method: 'tools/call', params: { name: 'hello', arguments: { name: n } } }); } catch {} return healthCheck(); }},
  { name: 'empty_tool_name', run: async () => { try { await mcpPost({ jsonrpc: '2.0', id: nextId++, method: 'tools/call', params: { name: '', arguments: {} } }); } catch {} return healthCheck(); }},
  { name: 'null_arguments', run: async () => { try { await mcpPost({ jsonrpc: '2.0', id: nextId++, method: 'tools/call', params: { name: 'hello', arguments: null } }); } catch {} return healthCheck(); }},
  { name: 'binary_garbage', run: async () => { const buf = new Uint8Array(256); for(let i=0;i<256;i++) buf[i]=Math.floor(Math.random()*256); await rawPost(buf, 'application/octet-stream'); await new Promise(r => setTimeout(r, 500)); return healthCheck(); }},
  { name: 'tool_throws', run: async () => { try { await mcpPost({ jsonrpc: '2.0', id: nextId++, method: 'tools/call', params: { name: 'nonexistent_xyz', arguments: {} } }); } catch {} return healthCheck(); }},
  { name: 'rapid_fire_100', run: async () => { const ps=[]; for(let i=0;i<100;i++) ps.push(mcpPost({ jsonrpc:'2.0', id:nextId++, method:'tools/call', params:{name:'hello',arguments:{name:'r'}} }, 15000).catch(()=>null)); await Promise.allSettled(ps); await new Promise(r=>setTimeout(r,500)); return healthCheck(); }},
  { name: '10mb_payload', run: async () => { try { await mcpPost({ jsonrpc: '2.0', id: nextId++, method: 'tools/call', params: { name: 'hello', arguments: { name: 'A'.repeat(10*1024*1024) } } }, 15000); } catch {} await new Promise(r => setTimeout(r, 500)); return healthCheck(); }},
  { name: '1000_level_nesting', run: async () => { let n={v:'deep'}; for(let i=0;i<1000;i++) n={c:n}; try { await mcpPost({ jsonrpc: '2.0', id: nextId++, method: 'tools/call', params: { name: 'hello', arguments: { name: n } } }, 10000); } catch {} await new Promise(r => setTimeout(r, 500)); return healthCheck(); }},
  { name: '50_concurrent', run: async () => { const ps=[]; for(let i=0;i<50;i++) ps.push(mcpPost({ jsonrpc:'2.0', id:nextId++, method:'tools/call', params:{name:'hello',arguments:{name:`c${i}`}} }).catch(()=>null)); await Promise.allSettled(ps); await new Promise(r=>setTimeout(r,500)); return healthCheck(); }},
  { name: 'unicode_emoji', run: async () => { try { await mcpPost({ jsonrpc: '2.0', id: nextId++, method: 'tools/call', params: { name: 'hello', arguments: { name: '🔥💀🎉 你好' } } }); } catch {} return healthCheck(); }},
  { name: 'null_bytes', run: async () => { try { await mcpPost({ jsonrpc: '2.0', id: nextId++, method: 'tools/call', params: { name: 'hello', arguments: { name: 'a\x00b' } } }); } catch {} return healthCheck(); }},
  { name: '1000_rapid_fire', run: async () => { const ps=[]; for(let i=0;i<1000;i++) ps.push(mcpPost({ jsonrpc:'2.0', id:nextId++, method:'tools/call', params:{name:'hello',arguments:{name:'r'}} }, 30000).catch(()=>null)); await Promise.allSettled(ps); await new Promise(r=>setTimeout(r,500)); return healthCheck(); }},
  { name: '10000_args', run: async () => { const a={}; for(let i=0;i<10000;i++) a[`k${i}`]=`v${i}`; try { await mcpPost({ jsonrpc:'2.0', id:nextId++, method:'tools/call', params:{name:'hello',arguments:a} }, 10000); } catch {} await new Promise(r=>setTimeout(r,500)); return healthCheck(); }},
  { name: 'array_arguments', run: async () => { await rawPost(JSON.stringify({ jsonrpc:'2.0', id:nextId++, method:'tools/call', params:{name:'hello',arguments:['not','object']} })); await new Promise(r=>setTimeout(r,300)); return healthCheck(); }},
  { name: 'wrong_content_type', run: async () => { await rawPost(JSON.stringify({ jsonrpc:'2.0', id:nextId++, method:'tools/call', params:{name:'hello',arguments:{name:'t'}} }), 'text/plain'); await new Promise(r=>setTimeout(r,300)); return healthCheck(); }},
];

async function main() {
  console.log(`\nChaos L1+L2 over SSE — ${SSE_URL}`);
  console.log(`Attacks: ${attacks.length}\n`);

  try {
    await connectSSE();
    console.log(`  Connected. Message endpoint: ${messageUrl}\n`);
  } catch (err) {
    console.log(`  Failed to connect SSE: ${err.message}`);
    process.exit(1);
  }

  const ok = await initSession();
  if (!ok) { console.log('  Failed to initialize session'); process.exit(1); }

  let passed = 0, failed = 0;
  for (const a of attacks) {
    let result;
    try { result = await a.run(); } catch { result = 'crashed'; }
    const icon = result==='survived'?'✓':result==='degraded'?'~':'✗';
    console.log(`  ${icon} ${a.name} — ${result}`);
    result==='survived'||result==='degraded' ? passed++ : failed++;
  }
  console.log(`\nResults: ${passed}/${attacks.length} passed, ${failed} failed`);

  // Cleanup SSE connection
  if (sseController) sseController.abort();
  process.exit(failed > 0 ? 1 : 0);
}

main();
