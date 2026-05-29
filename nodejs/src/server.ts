import { createInterface } from 'node:readline';
import { createServer } from 'node:http';
import { ToolScanner } from './scanner.js';
import { ResourceScanner } from './resource-scanner.js';
import { PromptScanner } from './prompt-scanner.js';
import { RemoteManager } from './remote.js';
import { loadConfig, resolveTransports, resolveAuth, resolveIcon, type Config } from './config.js';
import { handleRequest, createState, type JsonRpcRequest, type ServerState } from './dispatch.js';

export async function serve(configOrPath?: Config | string): Promise<void> {
  let config: Config;
  if (typeof configOrPath === 'string') {
    config = await loadConfig(configOrPath);
  } else {
    config = configOrPath || {};
  }

  // --- Tools ---
  const allTools = new Map<string, import('./scanner.js').ToolDefinition>();
  const remoteManager = new RemoteManager();

  if (config.remote?.length) {
    const remoteTools = await remoteManager.connect(config.remote);
    for (const [name, tool] of remoteTools) {
      allTools.set(name, tool);
    }
  }

  const toolScanner = new ToolScanner(config);
  try {
    await toolScanner.scan();
    for (const [name, tool] of toolScanner.tools) {
      if (allTools.has(name)) console.error(`[zeromcp] Local tool "${name}" overrides remote`);
      allTools.set(name, tool);
    }
  } catch {
    if (!config.remote?.length && !config.resources && !config.prompts) {
      console.error(`[zeromcp] No tools directory and no remote servers configured`);
      process.exit(1);
    }
  }

  // --- Resources ---
  const resourceScanner = new ResourceScanner(config);
  await resourceScanner.scan();

  // --- Prompts ---
  const promptScanner = new PromptScanner(config);
  await promptScanner.scan();

  // --- Icon ---
  const icon = await resolveIcon(config.icon);

  // --- State ---
  const state = createState({
    tools: allTools,
    resources: resourceScanner.resources,
    templates: resourceScanner.templates,
    prompts: promptScanner.prompts,
    executeTimeout: config.execute_timeout ?? 30000,
    pageSize: config.page_size ?? 0,
    version: '0.2.0',
    icon,
  });

  const toolCount = allTools.size;
  const resourceCount = resourceScanner.resources.size + resourceScanner.templates.size;
  const promptCount = promptScanner.prompts.size;
  console.error(`[zeromcp] ${toolCount} tool(s), ${resourceCount} resource(s), ${promptCount} prompt(s)`);

  // --- Hot reload ---
  if (config.autoload_tools) {
    toolScanner.watch(() => {
      for (const [name, tool] of toolScanner.tools) {
        allTools.set(name, tool);
      }
      state.notify?.('notifications/tools/list_changed', {});
    }).catch(() => {});
    console.error(`[zeromcp] autoload_tools enabled — watching for changes`);
  }

  // --- Transports ---
  const transports = resolveTransports(config);
  const hasHttp = transports.some(t => t.type === 'http');

  for (const t of transports) {
    if (t.type === 'stdio') {
      startStdio(state, hasHttp);
    } else if (t.type === 'http') {
      startHttp(state, t.port || 4242, t.auth, config);
    }
  }

  const cleanup = () => {
    toolScanner.stop();
    remoteManager.stop();
    process.exit(0);
  };
  process.on('SIGINT', cleanup);
}

function startStdio(state: ServerState, httpAlso: boolean): void {
  const rl = createInterface({ input: process.stdin });
  console.error(`[zeromcp] stdio transport ready`);

  state.notify = (method: string, params?: unknown) => {
    const notification: Record<string, unknown> = { jsonrpc: '2.0', method };
    if (params) notification.params = params;
    process.stdout.write(JSON.stringify(notification) + '\n');
  };

  rl.on('line', async (line: string) => {
    let request: JsonRpcRequest;
    try {
      request = JSON.parse(line);
    } catch {
      return;
    }
    if (!request || typeof request !== 'object' || Array.isArray(request)) return;

    const response = await handleRequest(request, state);
    if (response) {
      process.stdout.write(JSON.stringify(response) + '\n');
    }
  });

  rl.on('close', () => {
    if (!httpAlso) process.exit(0);
  });
}

function buildOpenApiSpec(state: ServerState, title: string): unknown {
  const paths: Record<string, unknown> = {};

  for (const [toolName, tool] of state.tools) {
    if (!tool.route) continue;
    const method = tool.route.method.toLowerCase();
    const path = tool.route.path.replace(/:([^/]+)/g, '{$1}');
    const pathParamNames = (tool.route.path.match(/:([^/]+)/g) || []).map((s: string) => s.slice(1));
    const inputSchema = tool.input || {};

    let operation: Record<string, unknown>;

    if (method === 'get') {
      const parameters: unknown[] = pathParamNames.map((pname: string) => ({
        name: pname,
        in: 'path',
        required: true,
        schema: { type: 'string' },
      }));
      for (const [key, field] of Object.entries(inputSchema)) {
        if (pathParamNames.includes(key)) continue;
        const isOptional = typeof field === 'object' && field !== null && (field as unknown as Record<string, unknown>).optional === true;
        const fieldType = typeof field === 'string' ? field : ((field as unknown as Record<string, unknown>).type as string) ?? 'string';
        const fieldDesc = typeof field === 'object' && field !== null ? (field as unknown as Record<string, unknown>).description as string | undefined : undefined;
        const schema: Record<string, unknown> = { type: fieldType };
        if (fieldDesc) schema.description = fieldDesc;
        parameters.push({ name: key, in: 'query', required: !isOptional, schema });
      }
      operation = {
        operationId: toolName,
        description: tool.description || '',
        parameters,
        responses: { '200': { description: 'Success' }, '500': { description: 'Error' } },
      };
    } else {
      const properties: Record<string, unknown> = {};
      const required: string[] = [];
      for (const [key, field] of Object.entries(inputSchema)) {
        const isOptional = typeof field === 'object' && field !== null && (field as unknown as Record<string, unknown>).optional === true;
        const fieldType = typeof field === 'string' ? field : ((field as unknown as Record<string, unknown>).type as string) ?? 'string';
        const fieldDesc = typeof field === 'object' && field !== null ? (field as unknown as Record<string, unknown>).description as string | undefined : undefined;
        const prop: Record<string, unknown> = { type: fieldType };
        if (fieldDesc) prop.description = fieldDesc;
        properties[key] = prop;
        if (!isOptional) required.push(key);
      }
      const pathParameters = pathParamNames.map((pname: string) => ({
        name: pname,
        in: 'path',
        required: true,
        schema: { type: 'string' },
      }));
      operation = {
        operationId: toolName,
        description: tool.description || '',
        ...(pathParameters.length ? { parameters: pathParameters } : {}),
        requestBody: {
          content: {
            'application/json': {
              schema: { type: 'object', properties, ...(required.length ? { required } : {}) },
            },
          },
        },
        responses: { '200': { description: 'Success' }, '500': { description: 'Error' } },
      };
    }

    if (!paths[path]) paths[path] = {};
    (paths[path] as Record<string, unknown>)[method] = operation;
  }

  return {
    openapi: '3.0.0',
    info: { title, version: '0.5.0' },
    paths,
  };
}

const SWAGGER_HTML = `<!DOCTYPE html>
<html>
<head>
  <title>ZeroMCP API</title>
  <meta charset="utf-8"/>
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist/swagger-ui.css">
</head>
<body>
<div id="swagger-ui"></div>
<script src="https://unpkg.com/swagger-ui-dist/swagger-ui-bundle.js"></script>
<script>SwaggerUIBundle({ url: '/openapi.json', dom_id: '#swagger-ui' })</script>
</body>
</html>`;

function startHttp(state: ServerState, port: number, authConfig?: string, config: Config = {}): void {
  const expectedToken = authConfig ? resolveAuth(authConfig) : undefined;

  const server = createServer(async (req, res) => {
    res.setHeader('Access-Control-Allow-Origin', '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');

    if (req.method === 'OPTIONS') { res.writeHead(204); res.end(); return; }

    if (expectedToken) {
      const authHeader = req.headers.authorization;
      if (!authHeader || authHeader !== `Bearer ${expectedToken}`) {
        json(res, { error: 'Unauthorized' }, 401);
        return;
      }
    }

    const url = new URL(req.url || '/', `http://localhost:${port}`);

    if (url.pathname === '/health' && req.method === 'GET') {
      json(res, { status: 'ok', tools: state.tools.size, resources: state.resources.size, prompts: state.prompts.size });
      return;
    }

    if (url.pathname === '/mcp' && req.method === 'POST') {
      const body = await parseBody(req);
      const response = await handleRequest(body, state);
      json(res, response || { jsonrpc: '2.0', result: {} });
      return;
    }

    if (url.pathname === '/openapi.json' && req.method === 'GET') {
      const title = config.title || 'ZeroMCP';
      json(res, buildOpenApiSpec(state, title));
      return;
    }

    if (url.pathname === '/docs' && req.method === 'GET') {
      res.writeHead(200, { 'Content-Type': 'text/html' });
      res.end(SWAGGER_HTML);
      return;
    }

    for (const [, tool] of state.tools) {
      if (!tool.route) continue;
      if (tool.route.method.toUpperCase() !== req.method) continue;
      const pathParams = matchRoute(tool.route.path, url.pathname);
      if (pathParams === null) continue;

      try {
        let args: Record<string, unknown> = { ...pathParams };
        if (req.method === 'GET') {
          for (const [k, v] of url.searchParams) args[k] = v;
        } else {
          const body = await parseBody(req);
          if (body && typeof body === 'object' && !Array.isArray(body)) {
            args = { ...args, ...(body as unknown as Record<string, unknown>) };
          }
        }
        const result = await tool.execute(args);
        json(res, { ok: true, result });
      } catch (err) {
        json(res, { ok: false, error: (err as Error).message }, 500);
      }
      return;
    }

    json(res, { error: 'Not found' }, 404);
  });

  server.listen(port, () => {
    console.error(`[zeromcp] http transport ready on port ${port}`);
  });
}

function matchRoute(pattern: string, pathname: string): Record<string, string> | null {
  const patternParts = pattern.split('/');
  const pathParts = pathname.split('/');
  if (patternParts.length !== pathParts.length) return null;
  const params: Record<string, string> = {};
  for (let i = 0; i < patternParts.length; i++) {
    if (patternParts[i].startsWith(':')) {
      params[patternParts[i].slice(1)] = decodeURIComponent(pathParts[i]);
    } else if (patternParts[i] !== pathParts[i]) {
      return null;
    }
  }
  return params;
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
