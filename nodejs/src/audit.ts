import { readFileSync } from 'fs';
import { readdir } from 'fs/promises';
import { join, extname, relative, resolve } from 'path';
import type { ToolSource } from './config.js';
import { resolveToolSources } from './config.js';

interface AuditViolation {
  file: string;
  line: number;
  pattern: string;
  message: string;
}

const FORBIDDEN_PATTERNS = [
  { regex: /(?<!\bctx\.)fetch\s*\(/, pattern: 'fetch(', message: 'Use ctx.fetch instead of global fetch' },
  { regex: /\bimport\b.*['"]fs['"]/, pattern: 'import fs', message: 'Filesystem access requires fs permission — use ctx.fs' },
  { regex: /\bimport\b.*['"]fs\/promises['"]/, pattern: 'import fs/promises', message: 'Filesystem access requires fs permission — use ctx.fs' },
  { regex: /\bimport\b.*['"]child_process['"]/, pattern: 'import child_process', message: 'Exec access requires exec permission — use ctx.exec' },
  { regex: /\brequire\s*\(\s*['"]fs['"]\s*\)/, pattern: 'require("fs")', message: 'Filesystem access requires fs permission — use ctx.fs' },
  { regex: /\brequire\s*\(\s*['"]child_process['"]\s*\)/, pattern: 'require("child_process")', message: 'Exec access requires exec permission — use ctx.exec' },
  { regex: /\bprocess\.env\b/, pattern: 'process.env', message: 'Use ctx.credentials for secrets — not process.env directly' },
];

function auditFile(filePath: string, content: string): AuditViolation[] {
  const violations: AuditViolation[] = [];
  const lines = content.split('\n');

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    for (const { regex, pattern, message } of FORBIDDEN_PATTERNS) {
      if (regex.test(line)) {
        violations.push({
          file: filePath,
          line: i + 1,
          pattern,
          message,
        });
      }
    }
  }

  return violations;
}

export async function auditTools(tools: string | (string | ToolSource)[]): Promise<AuditViolation[]> {
  const violations: AuditViolation[] = [];
  const sources = resolveToolSources(tools);
  for (const source of sources) {
    const dir = resolve(source.path);
    await scanDir(dir, dir, violations);
  }
  return violations;
}

async function scanDir(dir: string, rootDir: string, violations: AuditViolation[]): Promise<void> {
  const entries = await readdir(dir, { withFileTypes: true });

  for (const entry of entries) {
    const fullPath = join(dir, entry.name);

    if (entry.isDirectory()) {
      await scanDir(fullPath, rootDir, violations);
      continue;
    }

    if (!entry.isFile()) continue;
    const ext = extname(entry.name);
    if (ext !== '.js' && ext !== '.mjs') continue;

    const content = readFileSync(fullPath, 'utf8');
    const rel = relative(rootDir, fullPath);
    const fileViolations = auditFile(rel, content);
    violations.push(...fileViolations);
  }
}

export function formatAuditResults(violations: AuditViolation[]): string {
  if (violations.length === 0) {
    return '[zeromcp] Audit passed — all tools use ctx for sandboxed access';
  }

  const lines = [`[zeromcp] Audit found ${violations.length} violation(s):\n`];
  for (const v of violations) {
    lines.push(`  ✗ ${v.file}:${v.line} — ${v.pattern}`);
    lines.push(`    ${v.message}\n`);
  }
  return lines.join('\n');
}
