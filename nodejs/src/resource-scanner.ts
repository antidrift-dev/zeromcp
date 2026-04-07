/**
 * Resource scanner — discovers resources from a directory.
 *
 * Static files (json, md, txt, etc.) are served as-is.
 * JS/MJS files export { description?, mimeType?, uriTemplate?, read() }.
 */

import { readdir, stat, readFile } from 'node:fs/promises';
import { join, relative, extname } from 'node:path';
import { pathToFileURL } from 'node:url';
import type { Config } from './config.js';
import { resolveToolSources } from './config.js';

export interface ResourceDefinition {
  uri: string;
  name: string;
  description?: string;
  mimeType: string;
  read: () => Promise<string>;
}

export interface ResourceTemplateDefinition {
  uriTemplate: string;
  name: string;
  description?: string;
  mimeType: string;
  read: (params: Record<string, string>) => Promise<string>;
}

const MIME_MAP: Record<string, string> = {
  '.json': 'application/json',
  '.txt': 'text/plain',
  '.md': 'text/markdown',
  '.html': 'text/html',
  '.xml': 'application/xml',
  '.yaml': 'text/yaml',
  '.yml': 'text/yaml',
  '.csv': 'text/csv',
  '.css': 'text/css',
  '.js': 'application/javascript',
  '.ts': 'text/typescript',
  '.sql': 'text/plain',
  '.sh': 'text/plain',
  '.py': 'text/plain',
  '.rb': 'text/plain',
  '.go': 'text/plain',
  '.rs': 'text/plain',
  '.toml': 'text/plain',
  '.ini': 'text/plain',
  '.env': 'text/plain',
};

const DYNAMIC_EXTS = new Set(['.js', '.mjs']);

export class ResourceScanner {
  readonly resources = new Map<string, ResourceDefinition>();
  readonly templates = new Map<string, ResourceTemplateDefinition>();
  private dirs: string[];
  private separator: string;

  constructor(config: Config) {
    const sources = config.resources
      ? (typeof config.resources === 'string' ? [{ path: config.resources }] : config.resources.map(s => typeof s === 'string' ? { path: s } : s))
      : [];
    this.dirs = sources.map(s => s.path);
    this.separator = config.separator || '_';
  }

  async scan(): Promise<void> {
    this.resources.clear();
    this.templates.clear();

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
      const relPath = relative(baseDir, fullPath);
      const nameWithoutExt = relPath.replace(/\.[^.]+$/, '').replace(/[\\/]/g, this.separator);

      if (DYNAMIC_EXTS.has(ext)) {
        await this._loadDynamic(fullPath, nameWithoutExt);
      } else {
        this._loadStatic(fullPath, relPath, nameWithoutExt, ext);
      }
    }
  }

  private async _loadDynamic(filePath: string, name: string): Promise<void> {
    try {
      const url = pathToFileURL(filePath).href + `?t=${Date.now()}`;
      const mod = await import(url);
      const def = mod.default || mod;

      if (def.uriTemplate) {
        this.templates.set(name, {
          uriTemplate: def.uriTemplate,
          name,
          description: def.description,
          mimeType: def.mimeType || 'text/plain',
          read: def.read,
        });
      } else {
        const uri = def.uri || `resource:///${name}`;
        this.resources.set(name, {
          uri,
          name,
          description: def.description,
          mimeType: def.mimeType || 'application/json',
          read: def.read,
        });
      }
    } catch (err) {
      console.error(`[zeromcp] Failed to load resource ${filePath}: ${(err as Error).message}`);
    }
  }

  private _loadStatic(filePath: string, relPath: string, name: string, ext: string): void {
    const uri = `resource:///${relPath.replace(/\\/g, '/')}`;
    const mimeType = MIME_MAP[ext] || 'application/octet-stream';

    this.resources.set(name, {
      uri,
      name,
      description: `Static resource: ${relPath}`,
      mimeType,
      read: () => readFile(filePath, 'utf8'),
    });
  }
}
