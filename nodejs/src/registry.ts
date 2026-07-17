/**
 * ZeroMCP Hono registry — mounts tools as HTTP routes and an MCP endpoint.
 *
 * Usage:
 *   import { registerTools } from '@antidrift/zeromcp/registry'
 *
 *   const mcp = registerTools(tools, app, { getEnv: () => env })
 *   app.post('/mcp', async (c) => c.json(await mcp(await c.req.json())))
 */

import type { Hono, Context } from 'hono'
import { createState, handleRequest, type JsonRpcRequest, type JsonRpcResponse } from './dispatch.js'
import { toJsonSchema, type InputSchema } from './schema.js'

export type McpHandler = (request: JsonRpcRequest) => Promise<JsonRpcResponse | null>

export interface Tool<TEnv = Record<string, unknown>> {
  description: string
  input: InputSchema
  route?: {
    method: 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE'
    path: string
  }
  execute: (args: Record<string, unknown>, env: TEnv) => Promise<unknown>
}

export interface RegisterOptions<TEnv> {
  /** Provide env for MCP-path tool calls (no Hono context available there). */
  getEnv?: () => TEnv
  /** Return a Response to reject the request, or null to allow. Called before any protected route. */
  auth?: (c: Context, toolName: string) => Promise<Response | null>
}

function queryParams(url: string): Record<string, string> {
  const out: Record<string, string> = {}
  new URL(url).searchParams.forEach((v, k) => { out[k] = v })
  return out
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

export function registerTools<TEnv = Record<string, unknown>>(
  tools: Record<string, Tool<TEnv>>,
  app: Hono,
  options: RegisterOptions<TEnv> = {},
): McpHandler {
  const { getEnv = () => ({} as TEnv), auth } = options
  const toolMap = new Map()

  for (const [name, tool] of Object.entries(tools)) {
    toolMap.set(name, {
      description: tool.description,
      input: tool.input,
      cachedSchema: toJsonSchema(tool.input),
      execute: (args: Record<string, unknown>) => tool.execute(args, getEnv()),
    })

    if (tool.route) {
      const { method, path } = tool.route
      const m = method.toLowerCase() as 'get' | 'post' | 'put' | 'patch' | 'delete'
      console.log(`[zeromcp] registering ${method} ${path}`)

      app[m](path, async (c) => {
        if (auth) {
          const rejection = await auth(c, name)
          if (rejection) return rejection
        }

        const args = m === 'get'
          ? { ...c.req.param(), ...queryParams(c.req.url) }
          : { ...c.req.param(), ...await c.req.json().catch(() => ({})) }

        try {
          const result = await tool.execute(args, c.env as TEnv ?? getEnv())
          return c.json({ ok: true, result })
        } catch (err) {
          const message = err instanceof Error ? err.message : String(err)
          console.error(`[zeromcp:${name}] ${message}`)
          return c.json({ ok: false, error: message }, 500)
        }
      })
    }
  }

  app.get('/openapi.json', (c) => c.json(buildOpenApiSpec(tools as Record<string, Tool>)))

  const state = createState({ tools: toolMap, executeTimeout: 30_000, version: '1.0.0' })
  return (request: JsonRpcRequest) => handleRequest(request, state)
}
