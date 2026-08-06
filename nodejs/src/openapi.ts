/** Shared OpenAPI 3.0 document builder — used by both the built-in HTTP server and the framework-neutral registry. */
import type { JsonSchema } from './schema.js';

export interface OpenApiToolSource {
  description: string;
  cachedSchema: JsonSchema;
  route?: { method: string; path: string };
}

export interface OpenApiOptions {
  title?: string;
  version?: string;
}

export function buildOpenApiSpec(
  tools: Map<string, OpenApiToolSource> | Record<string, OpenApiToolSource>,
  options: OpenApiOptions = {},
): Record<string, unknown> {
  const paths: Record<string, Record<string, unknown>> = {};
  const entries = tools instanceof Map ? tools.entries() : Object.entries(tools);

  for (const [name, tool] of entries) {
    if (!tool.route) continue;
    const { method, path } = tool.route;
    const openApiPath = path.replace(/:([a-zA-Z_]+)/g, '{$1}');
    const pathParamNames = (path.match(/:([a-zA-Z_]+)/g) ?? []).map(p => p.slice(1));
    const schema = tool.cachedSchema;
    const properties = schema.properties ?? {};
    const required = schema.required ?? [];

    const pathParameters = pathParamNames.map(pname => ({
      name: pname,
      in: 'path',
      required: true,
      schema: { type: 'string' },
    }));

    let operation: Record<string, unknown>;

    if (method.toUpperCase() === 'GET') {
      const queryParameters = Object.entries(properties)
        .filter(([key]) => !pathParamNames.includes(key))
        .map(([key, prop]) => ({
          name: key,
          in: 'query',
          required: required.includes(key),
          schema: prop,
        }));
      operation = {
        operationId: name,
        description: tool.description || '',
        parameters: [...pathParameters, ...queryParameters],
        responses: { '200': { description: 'Success' }, '500': { description: 'Error' } },
      };
    } else {
      const bodyProperties = Object.fromEntries(
        Object.entries(properties).filter(([key]) => !pathParamNames.includes(key)),
      );
      const bodyRequired = required.filter(key => !pathParamNames.includes(key));
      operation = {
        operationId: name,
        description: tool.description || '',
        ...(pathParameters.length ? { parameters: pathParameters } : {}),
        requestBody: {
          required: true,
          content: {
            'application/json': {
              schema: { type: 'object', properties: bodyProperties, ...(bodyRequired.length ? { required: bodyRequired } : {}) },
            },
          },
        },
        responses: { '200': { description: 'Success' }, '500': { description: 'Error' } },
      };
    }

    paths[openApiPath] ??= {};
    (paths[openApiPath] as Record<string, unknown>)[method.toLowerCase()] = operation;
  }

  return {
    openapi: '3.0.0',
    info: { title: options.title ?? 'ZeroMCP', version: options.version ?? '1.0.0' },
    paths,
  };
}
