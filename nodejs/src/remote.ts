import type { RemoteServer } from './config.js';
import { resolveAuth } from './config.js';
import type { ToolDefinition } from './scanner.js';
import { type InputSchema, toJsonSchema } from './schema.js';

interface RemoteTool {
  name: string;
  description: string;
  inputSchema: { type: string; properties: Record<string, unknown>; required?: string[] };
}

interface RemoteConnection {
  server: RemoteServer;
  tools: Map<string, ToolDefinition>;
}

export class RemoteManager {
  connections: Map<string, RemoteConnection> = new Map();

  async connect(servers: RemoteServer[]): Promise<Map<string, ToolDefinition>> {
    const allTools = new Map<string, ToolDefinition>();

    for (const server of servers) {
      try {
        const tools = await this.connectOne(server);
        // Namespace: servername.toolname
        for (const [toolName, tool] of tools) {
          const namespacedName = `${server.name}.${toolName}`;
          allTools.set(namespacedName, tool);
          console.error(`[mcp] Remote tool: ${namespacedName}`);
        }
      } catch (err) {
        console.error(`[mcp] Failed to connect to ${server.name}: ${(err as Error).message}`);
      }
    }

    return allTools;
  }

  private async connectOne(server: RemoteServer): Promise<Map<string, ToolDefinition>> {
    if (!server.url.startsWith('http://') && !server.url.startsWith('https://')) {
      throw new Error(`Remote server "${server.name}" must have an HTTP/HTTPS URL, got: ${server.url}`);
    }
    return this.connectHttp(server);
  }

  private async connectHttp(server: RemoteServer): Promise<Map<string, ToolDefinition>> {
    const tools = new Map<string, ToolDefinition>();
    const auth = resolveAuth(server.auth);

    // Initialize
    const initRes = await this.httpRpc(server.url, {
      jsonrpc: '2.0', id: 1, method: 'initialize', params: {}
    }, auth);

    // List tools
    const listRes = await this.httpRpc(server.url, {
      jsonrpc: '2.0', id: 2, method: 'tools/list', params: {}
    }, auth);

    const remoteTools = listRes?.result?.tools as RemoteTool[] || [];

    for (const rt of remoteTools) {
      const input = this.schemaToInput(rt.inputSchema);
      tools.set(rt.name, {
        description: rt.description,
        input,
        cachedSchema: toJsonSchema(input),
        execute: async (args: Record<string, unknown>) => {
          const callRes = await this.httpRpc(server.url, {
            jsonrpc: '2.0', id: Date.now(),
            method: 'tools/call',
            params: { name: rt.name, arguments: args }
          }, auth);

          const content = callRes?.result?.content;
          if (content?.[0]?.text) return content[0].text;
          return callRes?.result;
        }
      });
    }

    console.error(`[mcp] Connected to ${server.name} (HTTP): ${tools.size} tool(s)`);
    return tools;
  }

  private async httpRpc(url: string, body: unknown, auth?: string): Promise<{ result?: { tools?: RemoteTool[]; content?: Array<{ text?: string }> } }> {
    const headers: Record<string, string> = { 'Content-Type': 'application/json' };
    if (auth) headers['Authorization'] = `Bearer ${auth}`;

    const res = await fetch(url, {
      method: 'POST',
      headers,
      body: JSON.stringify(body)
    });

    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    return res.json() as Promise<Record<string, unknown>>;
  }

  private schemaToInput(schema: { properties?: Record<string, unknown>; required?: string[] }): InputSchema {
    const input: InputSchema = {};
    if (!schema?.properties) return input;

    for (const [key, prop] of Object.entries(schema.properties)) {
      const p = prop as { type?: string; description?: string };
      const isRequired = schema.required?.includes(key) ?? false;

      if (p.description || !isRequired) {
        input[key] = {
          type: (p.type || 'string') as 'string',
          ...(p.description ? { description: p.description } : {}),
          ...(!isRequired ? { optional: true } : {})
        };
      } else {
        input[key] = (p.type || 'string') as 'string';
      }
    }

    return input;
  }

  stop(): void {
    this.connections.clear();
  }
}
