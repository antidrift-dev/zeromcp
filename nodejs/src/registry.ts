/** Framework-neutral tool registry for MCP, REST adapters, and OpenAPI adapters. */
import { createState, handleRequest, type JsonRpcRequest, type JsonRpcResponse } from './dispatch.js'
import { toJsonSchema, type InputSchema } from './schema.js'

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
}

export interface ToolRegistry<TEnv = Record<string, unknown>> {
  routes: RouteDefinition<TEnv>[]
  openapi: Record<string, unknown>
  mcp: McpHandler
}

function buildOpenApiSpec(tools: Record<string, Tool>): Record<string, unknown> {
  const paths: Record<string, Record<string, unknown>> = {}
  for (const [name, tool] of Object.entries(tools)) {
    if (!tool.route) continue
    const { method, path } = tool.route
    const openApiPath = path.replace(/:([a-zA-Z_]+)/g, '{$1}')
    const schema = toJsonSchema(tool.input)
    const pathParams = (path.match(/:([a-zA-Z_]+)/g) ?? []).map(p => p.slice(1))
    const operation: Record<string, unknown> = {
      operationId: name,
      description: tool.description,
      responses: { '200': { description: 'Success' }, '500': { description: 'Error' } },
    }
    if (method === 'GET') {
      operation.parameters = Object.entries(schema.properties ?? {}).map(([key, prop]) => ({
        name: key,
        in: pathParams.includes(key) ? 'path' : 'query',
        required: pathParams.includes(key) || (schema.required ?? []).includes(key),
        schema: prop,
      }))
    } else {
      operation.requestBody = { required: true, content: { 'application/json': { schema } } }
    }
    paths[openApiPath] ??= {}
    ;(paths[openApiPath] as Record<string, unknown>)[method.toLowerCase()] = operation
  }
  return { openapi: '3.0.0', info: { title: 'API', version: '1.0.0' }, paths }
}

export function createRegistry<TEnv = Record<string, unknown>>(
  tools: Record<string, Tool<TEnv>>,
  options: RegistryOptions<TEnv> = {},
): ToolRegistry<TEnv> {
  const getEnv = options.getEnv ?? (() => ({} as TEnv))
  const toolMap = new Map()
  for (const [name, tool] of Object.entries(tools)) {
    toolMap.set(name, {
      description: tool.description,
      input: tool.input,
      cachedSchema: toJsonSchema(tool.input),
      execute: (args: Record<string, unknown>) => tool.execute(args, getEnv()),
    })
  }
  const state = createState({ tools: toolMap, executeTimeout: 30_000, version: '1.0.0' })
  return {
    routes: Object.entries(tools).flatMap(([name, tool]) => tool.route ? [{ name, ...tool.route, tool }] : []),
    openapi: buildOpenApiSpec(tools as Record<string, Tool>),
    mcp: (request: JsonRpcRequest) => handleRequest(request, state),
  }
}
