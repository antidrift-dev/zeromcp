import { createInterface } from 'node:readline';
import { ToolScanner } from './scanner.js';
import { ResourceScanner } from './resource-scanner.js';
import { PromptScanner } from './prompt-scanner.js';
import { RemoteManager } from './remote.js';
import { loadConfig, resolveTransports, resolveIcon, type Config } from './config.js';
import { handleRequest, createState, type JsonRpcRequest, type ServerState } from './dispatch.js';

export async function serve(configOrPath?: Config | string): Promise<void> {
  let config: Config;
  if (typeof configOrPath === 'string') {
    config = await loadConfig(configOrPath);
  } else {
    config = configOrPath || {};
  }

  // --- Transports (checked before anything starts) ---
  const transports = resolveTransports(config);
  if (transports.some(t => (t as { type: string }).type !== 'stdio')) {
    throw new Error(
      "The built-in HTTP transport was removed. Mount createHandler ('@antidrift/zeromcp/handler') " +
      "or createRegistry ('@antidrift/zeromcp/registry') in your own HTTP server."
    );
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
  for (const t of transports) {
    if (t.type === 'stdio') startStdio(state);
  }

  const cleanup = () => {
    toolScanner.stop();
    remoteManager.stop();
    process.exit(0);
  };
  process.on('SIGINT', cleanup);
}

function startStdio(state: ServerState): void {
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
    process.exit(0);
  });
}
