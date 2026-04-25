import { readdir, watch } from 'node:fs/promises';
import { join, basename, extname, relative, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { type InputSchema, toJsonSchema, type JsonSchema } from './schema.js';
import type { Config, NamespaceOverride, CredentialSource, ToolSource } from './config.js';
import { resolveCredentials, resolveToolSources } from './config.js';
import { validatePermissions, createSandbox, type ToolPermissions, type SandboxContext, type SandboxOptions } from './sandbox.js';

export interface ToolContext {
  credentials?: unknown;
  fetch: SandboxContext['fetch'];
}

export interface ToolDefinition {
  description: string;
  input: InputSchema;
  cachedSchema: JsonSchema;
  execute: (args: Record<string, unknown>, ctx?: ToolContext) => Promise<unknown>;
  execute_timeout?: number; // ms, per-tool override
}

export class ToolScanner {
  tools: Map<string, ToolDefinition>;
  private sources: ToolSource[];
  private watchers: AbortController[];
  private separator: string;
  private namespacing: Record<string, NamespaceOverride>;
  private credentialSources: Record<string, CredentialSource>;
  private credentialCache: Map<string, unknown>;
  private cacheCredentials: boolean;
  private logging: boolean;
  private bypass: boolean;

  constructor(config?: Config) {
    this.tools = new Map();
    this.sources = resolveToolSources(config?.tools);
    this.watchers = [];
    this.separator = config?.separator || '_';
    this.namespacing = config?.namespacing || {};
    this.credentialSources = config?.credentials || {};
    this.credentialCache = new Map();
    this.cacheCredentials = config?.cache_credentials ?? true;
    this.logging = config?.logging ?? false;
    this.bypass = config?.bypass_permissions ?? false;
  }

  async scan(): Promise<Map<string, ToolDefinition>> {
    this.tools.clear();
    for (const source of this.sources) {
      const dir = resolve(source.path);
      await this._scanDir(dir, dir, source.prefix);
    }
    return this.tools;
  }

  private async _scanDir(dir: string, rootDir: string, sourcePrefix?: string): Promise<void> {
    let entries;
    try {
      entries = await readdir(dir, { withFileTypes: true });
    } catch {
      console.error(`[zeromcp] Cannot read tools directory: ${dir}`);
      return;
    }

    for (const entry of entries) {
      const fullPath = join(dir, entry.name);

      if (entry.isDirectory()) {
        if (entry.name === 'node_modules') continue;
        await this._scanDir(fullPath, rootDir, sourcePrefix);
        continue;
      }

      if (!entry.isFile()) continue;
      const ext = extname(entry.name);
      if (ext !== '.js' && ext !== '.mjs') continue;

      await this._loadTool(fullPath, rootDir, sourcePrefix);
    }
  }

  private _buildName(filePath: string, rootDir: string, sourcePrefix?: string): string {
    const rel = relative(rootDir, filePath);
    const parts = rel.split('/');
    const file = parts.pop()!;
    const filename = basename(file, extname(file));

    // Build the inner name (directory-based)
    let innerName = filename;
    if (parts.length > 0) {
      const dir = parts[0];
      const override = this.namespacing[dir];
      const dirPrefix = override?.prefix !== undefined ? override.prefix : dir;
      if (dirPrefix) {
        innerName = `${dirPrefix}${this.separator}${filename}`;
      }
    }

    // Apply source-level prefix
    if (sourcePrefix) {
      return `${sourcePrefix}${this.separator}${innerName}`;
    }

    return innerName;
  }

  private _getCredentialSource(filePath: string, rootDir: string): CredentialSource | undefined {
    const rel = relative(rootDir, filePath);
    const parts = rel.split('/');
    if (parts.length < 2) return undefined;
    return this.credentialSources[parts[0]];
  }

  private _resolveCredentials(filePath: string, rootDir: string): unknown {
    const source = this._getCredentialSource(filePath, rootDir);
    if (!source) return undefined;
    if (this.cacheCredentials) {
      const dir = relative(rootDir, filePath).split('/')[0];
      if (this.credentialCache.has(dir)) return this.credentialCache.get(dir);
      const creds = resolveCredentials(source);
      this.credentialCache.set(dir, creds);
      return creds;
    }
    return resolveCredentials(source);
  }

  private async _loadTool(filePath: string, rootDir: string, sourcePrefix?: string): Promise<void> {
    const fileUrl = pathToFileURL(filePath).href;

    try {
      const mod = await import(`${fileUrl}?t=${Date.now()}`);
      const tool = mod.default as {
        description?: string;
        input?: InputSchema;
        permissions?: ToolPermissions;
        execute?: Function;
      };

      if (!tool || !tool.execute || typeof tool.execute !== 'function') {
        return;
      }

      const name = this._buildName(filePath, rootDir, sourcePrefix);
      validatePermissions(name, tool.permissions);

      const sandboxOpts: SandboxOptions = {
        logging: this.logging,
        bypass: this.bypass,
      };
      const sandbox = createSandbox(name, tool.permissions, sandboxOpts);
      const rawExecute = tool.execute;

      const input = tool.input || {};
      this.tools.set(name, {
        description: tool.description || '',
        input,
        cachedSchema: toJsonSchema(input),
        execute: (args: Record<string, unknown>) => {
          const credentials = this._resolveCredentials(filePath, rootDir);
          const ctx: ToolContext = { credentials, fetch: sandbox.fetch };
          return rawExecute(args, ctx);
        },
        execute_timeout: tool.permissions?.execute_timeout,
      });

      console.error(`[zeromcp] Loaded: ${name}`);
    } catch (err) {
      const rel = relative(rootDir, filePath);
      console.error(`[zeromcp] Error loading ${rel}: ${(err as Error).message}`);
    }
  }

  async watch(onChange?: (tools: Map<string, ToolDefinition>) => void): Promise<void> {
    for (const source of this.sources) {
      const dir = resolve(source.path);
      const ac = new AbortController();
      this.watchers.push(ac);

      (async () => {
        try {
          const watcher = watch(dir, { recursive: true, signal: ac.signal });
          for await (const event of watcher) {
            const ext = extname(event.filename || '');
            if (ext !== '.js' && ext !== '.mjs') continue;

            console.error(`[zeromcp] Change detected: ${event.filename}`);
            await this.scan();
            if (onChange) onChange(this.tools);
          }
        } catch (err) {
          if ((err as Error).name !== 'AbortError') throw err;
        }
      })();
    }
  }

  stop(): void {
    for (const ac of this.watchers) ac.abort();
  }
}
