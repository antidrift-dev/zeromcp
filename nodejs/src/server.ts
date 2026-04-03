import { createInterface } from 'readline';
import { createServer } from 'http';
import { ToolScanner, type ToolDefinition } from './scanner.js';
import { RemoteManager } from './remote.js';
import { loadConfig, resolveTransports, resolveAuth, type Config, type TransportConfig } from './config.js';
import { toJsonSchema, validate } from './schema.js';

interface JsonRpcRequest {
  jsonrpc: string;
  id?: number | string;
  method: string;
  params?: Record<string, unknown>;
}

interface JsonRpcResponse {
  jsonrpc: string;
  id?: number | string;
  result?: unknown;
  error?: { code: number; message: string };
}

export async function serve(configOrPath?: Config | string): Promise<void> {
  let config: Config;
  if (typeof configOrPath === 'string') {
    config = await loadConfig(configOrPath);
  } else {
    config = configOrPath || {};
  }

  const allTools = new Map<string, ToolDefinition>();
  const remoteManager = new RemoteManager();

  // 1. Load remote tools first (lower precedence)
  if (config.remote?.length) {
    const remoteTools = await remoteManager.connect(config.remote);
    for (const [name, tool] of remoteTools) {
      allTools.set(name, tool);
    }
  }

  // 2. Load local tools on top (higher precedence, overrides remote)
  const scanner = new ToolScanner(config);

  try {
    await scanner.scan();
    for (const [name, tool] of scanner.tools) {
      if (allTools.has(name)) {
        console.error(`[zeromcp] Local tool "${name}" overrides remote`);
      }
      allTools.set(name, tool);
    }
  } catch {
    if (!config.remote?.length) {
      console.error(`[zeromcp] No tools directory and no remote servers configured`);
      process.exit(1);
    }
  }

  // Watch for local changes (off by default)
  if (config.autoload_tools) {
    scanner.watch(() => {
      for (const [name, tool] of scanner.tools) {
        allTools.set(name, tool);
      }
    }).catch(() => {});
    console.error(`[zeromcp] autoload_tools enabled — watching for changes`);
  }

  const localCount = scanner.tools.size;
  const remoteCount = allTools.size - localCount;
  console.error(`[zeromcp] ${localCount} local + ${remoteCount} remote = ${allTools.size} tool(s)`);

  // Start transports
  const transports = resolveTransports(config);
  const hasHttp = transports.some(t => t.type === 'http');

  for (const t of transports) {
    if (t.type === 'stdio') {
      startStdio(allTools, hasHttp);
    } else if (t.type === 'http') {
      startHttp(allTools, t.port || 4242, t.auth);
    }
  }

  const cleanup = () => {
    scanner.stop();
    remoteManager.stop();
    process.exit(0);
  };

  process.on('SIGINT', cleanup);
}

function startStdio(tools: Map<string, ToolDefinition>, httpAlso: boolean): void {
  const rl = createInterface({ input: process.stdin });
  console.error(`[zeromcp] stdio transport ready`);

  rl.on('line', async (line: string) => {
    let request: JsonRpcRequest;
    try {
      request = JSON.parse(line);
    } catch {
      return;
    }

    const response = await handleRequest(request, tools);
    if (response) {
      process.stdout.write(JSON.stringify(response) + '\n');
    }
  });

  rl.on('close', () => {
    if (!httpAlso) process.exit(0);
  });
}

function startHttp(tools: Map<string, ToolDefinition>, port: number, authConfig?: string): void {
  const expectedToken = authConfig ? resolveAuth(authConfig) : undefined;

  const server = createServer(async (req, res) => {
    // CORS
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');

    if (req.method === 'OPTIONS') {
      res.writeHead(204);
      res.end();
      return;
    }

    // Auth check
    if (expectedToken) {
      const authHeader = req.headers.authorization;
      if (!authHeader || authHeader !== `Bearer ${expectedToken}`) {
        json(res, { error: 'Unauthorized' }, 401);
        return;
      }
    }

    const url = new URL(req.url || '/', `http://localhost:${port}`);

    // Health check
    if (url.pathname === '/health' && req.method === 'GET') {
      json(res, { status: 'ok', tools: tools.size });
      return;
    }

    // MCP JSON-RPC endpoint
    if (url.pathname === '/mcp' && req.method === 'POST') {
      const body = await parseBody(req);
      const response = await handleRequest(body, tools);
      json(res, response || { jsonrpc: '2.0', result: {} });
      return;
    }

    json(res, { error: 'Not found', endpoints: { 'POST /mcp': 'MCP JSON-RPC', 'GET /health': 'Health check' } }, 404);
  });

  server.listen(port, () => {
    console.error(`[zeromcp] http transport ready on port ${port} (development only — use a reverse proxy or adapter for production)`);
  });
}

function parseBody(req: import('http').IncomingMessage): Promise<JsonRpcRequest> {
  return new Promise((resolve, reject) => {
    let body = '';
    req.on('data', (chunk: string) => body += chunk);
    req.on('end', () => {
      try { resolve(JSON.parse(body)); }
      catch { resolve({ jsonrpc: '2.0', method: '' } as JsonRpcRequest); }
    });
    req.on('error', reject);
  });
}

function json(res: import('http').ServerResponse, data: unknown, status = 200): void {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(data));
}

async function handleRequest(
  request: JsonRpcRequest,
  tools: Map<string, ToolDefinition>
): Promise<JsonRpcResponse | null> {
  const { id, method, params } = request;

  if (id === undefined && method === 'notifications/initialized') {
    return null;
  }

  switch (method) {
    case 'initialize':
      return {
        jsonrpc: '2.0',
        id,
        result: {
          protocolVersion: '2024-11-05',
          capabilities: {
            tools: { listChanged: true },
          },
          serverInfo: {
            name: 'zeromcp',
            version: '0.1.0',
          },
        },
      };

    case 'tools/list':
      return {
        jsonrpc: '2.0',
        id,
        result: {
          tools: buildToolList(tools),
        },
      };

    case 'tools/call':
      return {
        jsonrpc: '2.0',
        id,
        result: await callTool(tools, params as { name: string; arguments?: Record<string, unknown> }),
      };

    case 'ping':
      return { jsonrpc: '2.0', id, result: {} };

    default:
      if (id === undefined) return null;
      return {
        jsonrpc: '2.0',
        id,
        error: { code: -32601, message: `Method not found: ${method}` },
      };
  }
}

function buildToolList(tools: Map<string, ToolDefinition>) {
  const list = [];
  for (const [name, tool] of tools) {
    list.push({
      name,
      description: tool.description,
      inputSchema: toJsonSchema(tool.input),
    });
  }
  return list;
}

async function callTool(
  tools: Map<string, ToolDefinition>,
  params: { name: string; arguments?: Record<string, unknown> }
) {
  const { name, arguments: args = {} } = params;

  const tool = tools.get(name);
  if (!tool) {
    return {
      content: [{ type: 'text', text: `Unknown tool: ${name}` }],
      isError: true,
    };
  }

  const schema = toJsonSchema(tool.input);
  const errors = validate(args, schema);
  if (errors.length > 0) {
    return {
      content: [{ type: 'text', text: `Validation errors:\n${errors.join('\n')}` }],
      isError: true,
    };
  }

  try {
    const result = await tool.execute(args);
    const text = typeof result === 'string' ? result : JSON.stringify(result, null, 2);
    return {
      content: [{ type: 'text', text }],
    };
  } catch (err) {
    return {
      content: [{ type: 'text', text: `Error: ${(err as Error).message}` }],
      isError: true,
    };
  }
}
