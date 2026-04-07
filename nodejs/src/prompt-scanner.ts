/**
 * Prompt scanner — discovers prompts from a directory.
 *
 * Prompt files export { description?, arguments?, render(args) }.
 */

import { readdir } from 'node:fs/promises';
import { join, relative, extname } from 'node:path';
import { pathToFileURL } from 'node:url';
import type { Config } from './config.js';
import { toJsonSchema, type InputSchema, type JsonSchema } from './schema.js';

export interface PromptArgument {
  name: string;
  description?: string;
  required?: boolean;
}

export interface PromptDefinition {
  name: string;
  description?: string;
  arguments?: PromptArgument[];
  cachedArgumentSchema?: JsonSchema;
  render: (args: Record<string, unknown>) => Promise<unknown[]>;
}

const DYNAMIC_EXTS = new Set(['.js', '.mjs']);

export class PromptScanner {
  readonly prompts = new Map<string, PromptDefinition>();
  private dirs: string[];
  private separator: string;

  constructor(config: Config) {
    const sources = config.prompts
      ? (typeof config.prompts === 'string' ? [{ path: config.prompts }] : config.prompts.map(s => typeof s === 'string' ? { path: s } : s))
      : [];
    this.dirs = sources.map(s => s.path);
    this.separator = config.separator || '_';
  }

  async scan(): Promise<void> {
    this.prompts.clear();

    for (const dir of this.dirs) {
      await this._scanDir(dir, dir).catch(() => {});
    }
  }

  private async _scanDir(baseDir: string, currentDir: string): Promise<void> {
    let entries;
    try {
      entries = await readdir(currentDir, { withFileTypes: true });
    } catch {
      return;
    }

    for (const entry of entries) {
      const fullPath = join(currentDir, entry.name);

      if (entry.isDirectory()) {
        await this._scanDir(baseDir, fullPath);
        continue;
      }

      if (!entry.isFile()) continue;

      const ext = extname(entry.name);
      if (!DYNAMIC_EXTS.has(ext)) continue;

      const relPath = relative(baseDir, fullPath);
      const name = relPath.replace(/\.[^.]+$/, '').replace(/[\\/]/g, this.separator);

      await this._loadPrompt(fullPath, name);
    }
  }

  private async _loadPrompt(filePath: string, name: string): Promise<void> {
    try {
      const url = pathToFileURL(filePath).href + `?t=${Date.now()}`;
      const mod = await import(url);
      const def = mod.default || mod;

      if (!def.render || typeof def.render !== 'function') {
        console.error(`[zeromcp] Prompt ${filePath}: missing render() function`);
        return;
      }

      // Convert input schema shorthand to MCP prompt arguments
      const promptArgs: PromptArgument[] = [];
      if (def.arguments) {
        for (const [key, val] of Object.entries(def.arguments)) {
          if (typeof val === 'string') {
            promptArgs.push({ name: key, required: true });
          } else {
            const v = val as Record<string, unknown>;
            promptArgs.push({
              name: key,
              description: v.description as string | undefined,
              required: v.optional ? false : true,
            });
          }
        }
      }

      this.prompts.set(name, {
        name,
        description: def.description,
        arguments: promptArgs.length > 0 ? promptArgs : undefined,
        render: def.render,
      });
    } catch (err) {
      console.error(`[zeromcp] Failed to load prompt ${filePath}: ${(err as Error).message}`);
    }
  }
}
