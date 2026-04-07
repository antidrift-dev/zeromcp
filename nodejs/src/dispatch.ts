/**
 * Unified JSON-RPC dispatcher for ZeroMCP.
 * Handles tools, resources, prompts, and protocol passthrough methods.
 */

import type { ToolDefinition } from './scanner.js';
import type { ResourceDefinition, ResourceTemplateDefinition } from './resource-scanner.js';
import type { PromptDefinition } from './prompt-scanner.js';
import { validate } from './schema.js';
import { paginate } from './pagination.js';

export interface JsonRpcRequest {
  jsonrpc: string;
  id?: number | string;
  method: string;
  params?: Record<string, unknown>;
}

export interface JsonRpcResponse {
  jsonrpc: string;
  id?: number | string;
  result?: unknown;
  error?: { code: number; message: string };
}

export interface ServerState {
  tools: Map<string, ToolDefinition>;
  resources: Map<string, ResourceDefinition>;
  templates: Map<string, ResourceTemplateDefinition>;
  prompts: Map<string, PromptDefinition>;
  subscriptions: Set<string>; // subscribed resource URIs
  executeTimeout: number;
  pageSize: number;
  version: string;
  logLevel: string;
  roots: Array<{ uri: string; name?: string }>;
  clientCapabilities: Record<string, unknown>;
  icon?: string;
  notify?: (method: string, params?: unknown) => void;
}

export function createState(overrides: Partial<ServerState> & Pick<ServerState, 'tools' | 'executeTimeout' | 'version'>): ServerState {
  return {
    resources: new Map(),
    templates: new Map(),
    prompts: new Map(),
    subscriptions: new Set(),
    pageSize: 0,
    logLevel: 'info',
    roots: [],
    clientCapabilities: {},
    ...overrides,
  };
}

export async function handleRequest(
  request: JsonRpcRequest,
  state: ServerState
): Promise<JsonRpcResponse | null> {
  if (!request || typeof request !== 'object') return null;

  const { id, method, params } = request;

  // Notifications (no id)
  if (id === undefined) {
    handleNotification(method, params, state);
    return null;
  }

  switch (method) {
    case 'initialize':
      return handleInitialize(id, params, state);
    case 'ping':
      return { jsonrpc: '2.0', id, result: {} };

    // Tools
    case 'tools/list':
      return handleToolsList(id, params, state);
    case 'tools/call':
      return handleToolsCall(id, params, state);

    // Resources
    case 'resources/list':
      return handleResourcesList(id, params, state);
    case 'resources/read':
      return handleResourcesRead(id, params, state);
    case 'resources/subscribe':
      return handleResourcesSubscribe(id, params, state);
    case 'resources/templates/list':
      return handleResourcesTemplatesList(id, params, state);

    // Prompts
    case 'prompts/list':
      return handlePromptsList(id, params, state);
    case 'prompts/get':
      return handlePromptsGet(id, params, state);

    // Passthrough
    case 'logging/setLevel':
      return handleLoggingSetLevel(id, params, state);
    case 'completion/complete':
      return handleCompletionComplete(id, params, state);

    default:
      return {
        jsonrpc: '2.0',
        id,
        error: { code: -32601, message: `Method not found: ${method}` },
      };
  }
}

// --- Notifications ---

function handleNotification(method: string, params: Record<string, unknown> | undefined, state: ServerState): void {
  switch (method) {
    case 'notifications/initialized':
      break;
    case 'notifications/roots/list_changed':
      if (params?.roots && Array.isArray(params.roots)) {
        state.roots = params.roots as Array<{ uri: string; name?: string }>;
      }
      break;
  }
}

// --- Initialize ---

function handleInitialize(id: number | string, params: Record<string, unknown> | undefined, state: ServerState): JsonRpcResponse {
  if (params?.capabilities) {
    state.clientCapabilities = params.capabilities as Record<string, unknown>;
  }

  const capabilities: Record<string, unknown> = {
    tools: { listChanged: true },
  };

  if (state.resources.size > 0 || state.templates.size > 0) {
    capabilities.resources = { subscribe: true, listChanged: true };
  }

  if (state.prompts.size > 0) {
    capabilities.prompts = { listChanged: true };
  }

  capabilities.logging = {};

  return {
    jsonrpc: '2.0',
    id,
    result: {
      protocolVersion: '2024-11-05',
      capabilities,
      serverInfo: { name: 'zeromcp', version: state.version },
    },
  };
}

// --- Tools ---

function handleToolsList(id: number | string, params: Record<string, unknown> | undefined, state: ServerState): JsonRpcResponse {
  const cursor = (params as { cursor?: string })?.cursor;
  const list = [];
  for (const [name, tool] of state.tools) {
    const entry: Record<string, unknown> = { name, description: tool.description, inputSchema: tool.cachedSchema };
    if (state.icon) entry.icons = [{ uri: state.icon }];
    list.push(entry);
  }
  const { items, nextCursor } = paginate(list, cursor, state.pageSize);
  const result: Record<string, unknown> = { tools: items };
  if (nextCursor) result.nextCursor = nextCursor;
  return { jsonrpc: '2.0', id, result };
}

async function handleToolsCall(id: number | string, params: Record<string, unknown> | undefined, state: ServerState): Promise<JsonRpcResponse> {
  const p = params as { name: string; arguments?: Record<string, unknown> } | undefined;
  const name = p?.name ?? '';
  const args = p?.arguments ?? {};

  const tool = state.tools.get(name);
  if (!tool) {
    return { jsonrpc: '2.0', id, result: { content: [{ type: 'text', text: `Unknown tool: ${name}` }], isError: true } };
  }

  const errors = validate(args, tool.cachedSchema);
  if (errors.length > 0) {
    return { jsonrpc: '2.0', id, result: { content: [{ type: 'text', text: `Validation errors:\n${errors.join('\n')}` }], isError: true } };
  }

  const timeout = tool.execute_timeout ?? state.executeTimeout;

  try {
    const result = await withTimeout(tool.execute(args), timeout, name);
    const text = typeof result === 'string' ? result : JSON.stringify(result);
    return { jsonrpc: '2.0', id, result: { content: [{ type: 'text', text }] } };
  } catch (err) {
    return { jsonrpc: '2.0', id, result: { content: [{ type: 'text', text: `Error: ${(err as Error).message}` }], isError: true } };
  }
}

// --- Resources ---

function handleResourcesList(id: number | string, params: Record<string, unknown> | undefined, state: ServerState): JsonRpcResponse {
  const cursor = (params as { cursor?: string })?.cursor;
  const list = [];
  for (const [, res] of state.resources) {
    const entry: Record<string, unknown> = { uri: res.uri, name: res.name, description: res.description, mimeType: res.mimeType };
    if (state.icon) entry.icons = [{ uri: state.icon }];
    list.push(entry);
  }
  const { items, nextCursor } = paginate(list, cursor, state.pageSize);
  const result: Record<string, unknown> = { resources: items };
  if (nextCursor) result.nextCursor = nextCursor;
  return { jsonrpc: '2.0', id, result };
}

async function handleResourcesRead(id: number | string, params: Record<string, unknown> | undefined, state: ServerState): Promise<JsonRpcResponse> {
  const uri = (params as { uri?: string })?.uri ?? '';

  // Check static resources
  for (const [, res] of state.resources) {
    if (res.uri === uri) {
      try {
        const text = await res.read();
        return { jsonrpc: '2.0', id, result: { contents: [{ uri, mimeType: res.mimeType, text }] } };
      } catch (err) {
        return { jsonrpc: '2.0', id, error: { code: -32603, message: `Error reading resource: ${(err as Error).message}` } };
      }
    }
  }

  // Check templates
  for (const [, tmpl] of state.templates) {
    const match = matchTemplate(tmpl.uriTemplate, uri);
    if (match) {
      try {
        const text = await tmpl.read(match);
        return { jsonrpc: '2.0', id, result: { contents: [{ uri, mimeType: tmpl.mimeType, text }] } };
      } catch (err) {
        return { jsonrpc: '2.0', id, error: { code: -32603, message: `Error reading resource: ${(err as Error).message}` } };
      }
    }
  }

  return { jsonrpc: '2.0', id, error: { code: -32002, message: `Resource not found: ${uri}` } };
}

function handleResourcesSubscribe(id: number | string, params: Record<string, unknown> | undefined, state: ServerState): JsonRpcResponse {
  const uri = (params as { uri?: string })?.uri;
  if (uri) state.subscriptions.add(uri);
  return { jsonrpc: '2.0', id, result: {} };
}

function handleResourcesTemplatesList(id: number | string, params: Record<string, unknown> | undefined, state: ServerState): JsonRpcResponse {
  const cursor = (params as { cursor?: string })?.cursor;
  const list = [];
  for (const [, tmpl] of state.templates) {
    const entry: Record<string, unknown> = { uriTemplate: tmpl.uriTemplate, name: tmpl.name, description: tmpl.description, mimeType: tmpl.mimeType };
    if (state.icon) entry.icons = [{ uri: state.icon }];
    list.push(entry);
  }
  const { items, nextCursor } = paginate(list, cursor, state.pageSize);
  const result: Record<string, unknown> = { resourceTemplates: items };
  if (nextCursor) result.nextCursor = nextCursor;
  return { jsonrpc: '2.0', id, result };
}

// --- Prompts ---

function handlePromptsList(id: number | string, params: Record<string, unknown> | undefined, state: ServerState): JsonRpcResponse {
  const cursor = (params as { cursor?: string })?.cursor;
  const list = [];
  for (const [, prompt] of state.prompts) {
    const entry: Record<string, unknown> = { name: prompt.name };
    if (prompt.description) entry.description = prompt.description;
    if (prompt.arguments) entry.arguments = prompt.arguments;
    if (state.icon) entry.icons = [{ uri: state.icon }];
    list.push(entry);
  }
  const { items, nextCursor } = paginate(list, cursor, state.pageSize);
  const result: Record<string, unknown> = { prompts: items };
  if (nextCursor) result.nextCursor = nextCursor;
  return { jsonrpc: '2.0', id, result };
}

async function handlePromptsGet(id: number | string, params: Record<string, unknown> | undefined, state: ServerState): Promise<JsonRpcResponse> {
  const p = params as { name?: string; arguments?: Record<string, unknown> } | undefined;
  const name = p?.name ?? '';
  const args = p?.arguments ?? {};

  const prompt = state.prompts.get(name);
  if (!prompt) {
    return { jsonrpc: '2.0', id, error: { code: -32002, message: `Prompt not found: ${name}` } };
  }

  try {
    const messages = await prompt.render(args);
    return { jsonrpc: '2.0', id, result: { messages } };
  } catch (err) {
    return { jsonrpc: '2.0', id, error: { code: -32603, message: `Error rendering prompt: ${(err as Error).message}` } };
  }
}

// --- Passthrough ---

function handleLoggingSetLevel(id: number | string, params: Record<string, unknown> | undefined, state: ServerState): JsonRpcResponse {
  const level = (params as { level?: string })?.level;
  if (level) state.logLevel = level;
  return { jsonrpc: '2.0', id, result: {} };
}

function handleCompletionComplete(id: number | string, params: Record<string, unknown> | undefined, state: ServerState): JsonRpcResponse {
  // TODO: look up tool/resource/prompt completions when they export a completions object
  return { jsonrpc: '2.0', id, result: { completion: { values: [] } } };
}

// --- Utilities ---

function matchTemplate(template: string, uri: string): Record<string, string> | null {
  const regex = template.replace(/\{(\w+)\}/g, '(?<$1>[^/]+)');
  const match = uri.match(new RegExp(`^${regex}$`));
  return match?.groups ? { ...match.groups } : null;
}

function withTimeout<T>(promise: Promise<T>, ms: number, toolName: string): Promise<T> {
  if (ms <= 0) return promise;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      reject(new Error(`Tool "${toolName}" timed out after ${ms}ms`));
    }, ms);
    promise.then(
      (val) => { clearTimeout(timer); resolve(val); },
      (err) => { clearTimeout(timer); reject(err); }
    );
  });
}
