import { readFile, readFileSync } from 'fs';
import { readFile as readFileAsync } from 'fs/promises';
import { resolve, dirname } from 'path';

export interface RemoteServer {
  name: string;
  url: string;
  auth?: string;
}

export interface NamespaceOverride {
  prefix?: string;
}

export interface CredentialSource {
  env?: string;
  file?: string;
}

export interface TransportConfig {
  type: 'stdio' | 'http';
  port?: number;
  auth?: string;
}

export interface ToolSource {
  path: string;
  prefix?: string;
}

export interface Config {
  tools?: string | (string | ToolSource)[];
  transport?: TransportConfig | TransportConfig[];
  logging?: boolean;
  bypass_permissions?: boolean;
  autoload_tools?: boolean;
  separator?: string;
  namespacing?: Record<string, NamespaceOverride>;
  credentials?: Record<string, CredentialSource>;
  remote?: RemoteServer[];
}

export function resolveToolSources(tools?: string | (string | ToolSource)[]): ToolSource[] {
  if (!tools) return [{ path: './tools' }];
  if (typeof tools === 'string') return [{ path: tools }];
  return tools.map(t => typeof t === 'string' ? { path: t } : t);
}

export function resolveTransports(config: Config): TransportConfig[] {
  if (!config.transport) return [{ type: 'stdio' }];
  if (Array.isArray(config.transport)) return config.transport;
  return [config.transport];
}

export function resolveCredentials(source: CredentialSource): unknown {
  if (source.env) {
    const value = process.env[source.env];
    if (!value) {
      console.error(`[zeromcp] Warning: environment variable ${source.env} not set`);
      return undefined;
    }
    // Try parsing as JSON, otherwise return raw string
    try { return JSON.parse(value); } catch { return value; }
  }

  if (source.file) {
    const path = source.file.replace(/^~/, process.env.HOME || '');
    try {
      const raw = readFileSync(path, 'utf8');
      try { return JSON.parse(raw); } catch { return raw; }
    } catch (err) {
      console.error(`[zeromcp] Warning: cannot read credential file ${path}`);
      return undefined;
    }
  }

  return undefined;
}

export async function loadConfig(configPath: string): Promise<Config> {
  try {
    const raw = await readFileAsync(configPath, 'utf8');
    return JSON.parse(raw);
  } catch (err) {
    if ((err as NodeJS.ErrnoException).code === 'ENOENT') {
      return {};
    }
    throw err;
  }
}

export function resolveAuth(auth: string | undefined): string | undefined {
  if (!auth) return undefined;

  if (auth.startsWith('env:')) {
    const envVar = auth.slice(4);
    const value = process.env[envVar];
    if (!value) {
      console.error(`[zeromcp] Warning: environment variable ${envVar} not set`);
    }
    return value;
  }

  return auth;
}
