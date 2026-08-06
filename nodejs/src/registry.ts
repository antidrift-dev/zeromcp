/** Framework-neutral tool registry for MCP, REST adapters, and OpenAPI adapters. */
import { createState, handleRequest, type JsonRpcRequest, type JsonRpcResponse } from './dispatch.js'
import { toJsonSchema, type InputSchema } from './schema.js'
import { buildOpenApiSpec, type OpenApiToolSource } from './openapi.js'
import { RemoteManager } from './remote.js'
import type { RemoteServer } from './config.js'

export type RouteMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE'
export type McpHandler = (request: JsonRpcRequest) => Promise<JsonRpcResponse | null>

export interface Tool<TEnv = Record<string, unknown>> {
  description: string
  input: InputSchema
  route?: { method: RouteMethod; path: string }
  execute: (args: Record<string, unknown>, env: TEnv) => Promise<unknown>
}

export interface RouteDefinition<TEnv = Record<string, unknown>> {
  name: string
  method: RouteMethod
  path: string
  tool: Tool<TEnv>
}

export interface RegistryOptions<TEnv> {
  getEnv?: () => TEnv
  /** Server name/version reported in `initialize` and the OpenAPI `info` block. Defaults to 'ZeroMCP' / '1.0.0'. */
  title?: string
  version?: string
  /** Default per-tool execute timeout in ms, unless a tool overrides it. Defaults to 30_000. */
  executeTimeout?: number
  /** Remote MCP servers to federate. Their tools are merged in as `servername.toolname`; a local tool with the same name overrides the remote one. */
  remote?: RemoteServer[]
}

export interface ToolRegistry<TEnv = Record<string, unknown>> {
  routes: RouteDefinition<TEnv>[]
  openapi: Record<string, unknown>
  mcp: McpHandler
}

export async function createRegistry<TEnv = Record<string, unknown>>(
  tools: Record<string, Tool<TEnv>>,
  options: RegistryOptions<TEnv> = {},
): Promise<ToolRegistry<TEnv>> {
  const getEnv = options.getEnv ?? (() => ({} as TEnv))
  const toolMap = new Map<string, OpenApiToolSource & { input: InputSchema; execute: (args: Record<string, unknown>) => Promise<unknown> }>()

  if (options.remote?.length) {
    const remoteTools = await new RemoteManager().connect(options.remote)
    for (const [name, tool] of remoteTools) {
      toolMap.set(name, { description: tool.description, input: tool.input, cachedSchema: tool.cachedSchema, execute: tool.execute })
    }
  }

  for (const [name, tool] of Object.entries(tools)) {
    if (toolMap.has(name)) console.error(`[zeromcp] Local tool "${name}" overrides remote`)
    toolMap.set(name, {
      description: tool.description,
      input: tool.input,
      cachedSchema: toJsonSchema(tool.input),
      route: tool.route,
      execute: (args: Record<string, unknown>) => tool.execute(args, getEnv()),
    })
  }

  const routeCounts = new Map<string, number>()
  const routes: RouteDefinition<TEnv>[] = []
  for (const [name, tool] of Object.entries(tools)) {
    if (!tool.route) continue
    const key = `${tool.route.method} ${tool.route.path}`
    routeCounts.set(key, (routeCounts.get(key) ?? 0) + 1)
    routes.push({ name, method: tool.route.method, path: tool.route.path, tool })
  }
  for (const [key, count] of routeCounts) {
    if (count > 1) console.error(`[zeromcp] ${count} tools registered the same route "${key}" — only your own router's route matching, not this registry, decides which one runs`)
  }

  const state = createState({
    tools: toolMap,
    executeTimeout: options.executeTimeout ?? 30_000,
    version: options.version ?? '1.0.0',
  })

  return {
    routes,
    openapi: buildOpenApiSpec(toolMap, { title: options.title, version: options.version }),
    mcp: (request: JsonRpcRequest) => handleRequest(request, state),
  }
}
