/**
 * ZeroMCP HTTP handler — framework-agnostic JSON-RPC handler.
 *
 * Usage:
 *   const handler = await createHandler('./tools');
 *   const handler = await createHandler({ tools: ['./tools'], resources: ['./resources'], prompts: ['./prompts'] });
 *   const response = await handler(jsonRpcRequest);
 */

import { ToolScanner } from './scanner.js';
import { ResourceScanner } from './resource-scanner.js';
import { PromptScanner } from './prompt-scanner.js';
import { loadConfig, resolveIcon, type Config } from './config.js';
import { handleRequest, createState, type JsonRpcRequest, type JsonRpcResponse } from './dispatch.js';

export type McpHandler = (request: JsonRpcRequest) => Promise<JsonRpcResponse | null>;

export async function createHandler(toolsOrConfig?: string | Config): Promise<McpHandler> {
  let config: Config;

  if (typeof toolsOrConfig === 'string') {
    if (toolsOrConfig.endsWith('.json')) {
      config = await loadConfig(toolsOrConfig);
    } else {
      config = { tools: [toolsOrConfig] };
    }
  } else {
    config = toolsOrConfig || {};
  }

  const toolScanner = new ToolScanner(config);
  await toolScanner.scan();

  const resourceScanner = new ResourceScanner(config);
  await resourceScanner.scan();

  const promptScanner = new PromptScanner(config);
  await promptScanner.scan();

  const icon = await resolveIcon(config.icon);

  const state = createState({
    tools: toolScanner.tools,
    resources: resourceScanner.resources,
    templates: resourceScanner.templates,
    prompts: promptScanner.prompts,
    executeTimeout: config.execute_timeout ?? 30000,
    pageSize: config.page_size ?? 0,
    version: '0.2.0',
    icon,
  });

  const counts = `${state.tools.size} tool(s), ${state.resources.size} resource(s), ${state.prompts.size} prompt(s)`;
  console.error(`[zeromcp] ${counts} loaded`);

  return (request: JsonRpcRequest) => handleRequest(request, state);
}
