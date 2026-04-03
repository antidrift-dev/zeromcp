#!/usr/bin/env node

import { resolve } from 'path';
import { existsSync, readFileSync } from 'fs';
import { serve } from '../dist/server.js';
import { auditTools, formatAuditResults } from '../dist/audit.js';

const args = process.argv.slice(2);
const command = args[0];

if (!command || !['serve', 'audit'].includes(command)) {
  console.error('Usage:');
  console.error('  zeromcp serve [tools-directory...] [stdio|http] [--config <path>]');
  console.error('  zeromcp audit [tools-directory...]');
  process.exit(1);
}

// Parse --config flag
let configPath;
const configIdx = args.indexOf('--config');
if (configIdx !== -1 && args[configIdx + 1]) {
  configPath = resolve(process.cwd(), args[configIdx + 1]);
}

// Auto-detect zeromcp.config.json
if (!configPath) {
  const autoPath = resolve(process.cwd(), 'zeromcp.config.json');
  if (existsSync(autoPath)) {
    configPath = autoPath;
  }
}

// Load config file or start empty
const config = configPath ? JSON.parse(readFileSync(configPath, 'utf8')) : {};

// Collect positional args (not flags, not transport keywords)
const reserved = new Set(['stdio', 'http', '--config']);
const positional = args.slice(1).filter(a => {
  if (reserved.has(a)) return false;
  if (a.startsWith('--')) return false;
  if (args[args.indexOf(a) - 1] === '--config') return false;
  return true;
});

// CLI tool directories override config
if (positional.length > 0) {
  config.tools = positional.map(d => resolve(process.cwd(), d));
}

if (command === 'audit') {
  const violations = await auditTools(config.tools || './tools');
  console.error(formatAuditResults(violations));
  process.exit(violations.length > 0 ? 1 : 0);
}

if (command === 'serve') {
  // CLI transport args
  const cliTransports = args.slice(1).filter(a => a === 'stdio' || a === 'http');
  if (cliTransports.length > 0) {
    config.transport = cliTransports.map(t => {
      if (t === 'http') return { type: 'http', port: 4242 };
      return { type: t };
    });
  }

  serve(config);
}
