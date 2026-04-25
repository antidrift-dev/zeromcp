import { readFile, readFileSync } from 'node:fs';
import { readFile as readFileAsync } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';

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
  cache_credentials?: boolean; // default true — set false to re-read credentials on every tool call
  remote?: RemoteServer[];
  execute_timeout?: number; // ms, default 30000
  page_size?: number; // 0 = no pagination (default)
  resources?: string | (string | ToolSource)[];
  prompts?: string | (string | ToolSource)[];
  icon?: string; // URL, file path, or data URI — applied to all tools/resources/prompts
}

const ICON_MIME: Record<string, string> = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.webp': 'image/webp',
};

/**
 * Resolve an icon config value to a data URI.
 * Accepts: data URI (passthrough), URL (fetched), file path (read).
 */
export async function resolveIcon(icon: string | undefined): Promise<string | undefined> {
  if (!icon) return undefined;

  // Already a data URI
  if (icon.startsWith('data:')) return icon;

  // URL — fetch and convert
  if (icon.startsWith('http://') || icon.startsWith('https://')) {
    try {
      const res = await fetch(icon);
      if (!res.ok) {
        console.error(`[zeromcp] Warning: failed to fetch icon ${icon}: ${res.status}`);
        return undefined;
      }
      const contentType = res.headers.get('content-type') || 'image/png';
      const buf = Buffer.from(await res.arrayBuffer());
      return `data:${contentType};base64,${buf.toString('base64')}`;
    } catch (err) {
      console.error(`[zeromcp] Warning: failed to fetch icon ${icon}: ${(err as Error).message}`);
      return undefined;
    }
  }

  // File path — read and convert
  try {
    const { readFile: readFileAsync } = await import('node:fs/promises');
    const { extname } = await import('node:path');
    const path = icon.replace(/^~/, process.env.HOME || '');
    const buf = await readFileAsync(path);
    const ext = extname(path).toLowerCase();
    const mime = ICON_MIME[ext] || 'image/png';
    return `data:${mime};base64,${buf.toString('base64')}`;
  } catch (err) {
    console.error(`[zeromcp] Warning: failed to read icon file ${icon}: ${(err as Error).message}`);
    return undefined;
  }
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
