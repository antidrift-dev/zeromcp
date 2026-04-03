#!/usr/bin/env node

/**
 * ZeroMCP Cross-Language Conformance Test Runner
 *
 * Spawns any zeromcp implementation, sends standardized MCP requests,
 * verifies responses match expected output. If Go returns a different
 * JSON shape than Node.js, it fails.
 *
 * Usage:
 *   node runner.js <command> [args...]
 *
 * Examples:
 *   node runner.js node ../../nodejs/bin/mcp.js serve ../../nodejs/examples/tools
 *   node runner.js python -m zeromcp serve ../../python/examples/tools
 *   node runner.js ../../go/zeromcp serve ../../go/examples/tools
 */

import { spawn } from 'child_process';
import { readFileSync } from 'fs';
import { dirname, join } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const fixtures = JSON.parse(readFileSync(join(__dirname, 'fixtures.json'), 'utf8'));

const args = process.argv.slice(2);
if (args.length === 0) {
  console.error('Usage: node runner.js <command> [args...]');
  console.error('Example: node runner.js node ../../nodejs/bin/mcp.js serve ../../nodejs/examples/tools');
  process.exit(1);
}

const command = args[0];
const commandArgs = args.slice(1);

function sendRequest(proc, request) {
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => reject(new Error(`Timeout waiting for response to ${request.method}`)), 10000);
    proc.stdout.once('data', (data) => {
      clearTimeout(timeout);
      const line = data.toString().trim();
      if (!line) { resolve(null); return; }
      try { resolve(JSON.parse(line)); }
      catch { reject(new Error(`Invalid JSON response: ${line.slice(0, 200)}`)); }
    });
    proc.stdin.write(JSON.stringify(request) + '\n');
  });
}

function deepPartialMatch(actual, expected, path = '') {
  const errors = [];
  if (Array.isArray(expected)) {
    if (!Array.isArray(actual)) {
      errors.push(`Expected array at ${path}, got ${typeof actual}`);
      return errors;
    }
    // Compare string arrays as sets (e.g. "required" — order doesn't matter)
    if (expected.every(v => typeof v === 'string') && actual.every(v => typeof v === 'string')) {
      const missing = expected.filter(v => !actual.includes(v));
      const extra = actual.filter(v => !expected.includes(v));
      if (missing.length) errors.push(`Missing values at ${path}: ${missing.join(', ')}`);
      if (extra.length) errors.push(`Unexpected values at ${path}: ${extra.join(', ')}`);
      return errors;
    }
    for (let i = 0; i < expected.length; i++) {
      const itemPath = `${path}[${i}]`;
      if (i >= actual.length) {
        errors.push(`Missing item at ${itemPath}`);
        continue;
      }
      errors.push(...deepPartialMatch(actual[i], expected[i], itemPath));
    }
    return errors;
  }
  if (typeof expected === 'object' && expected !== null) {
    if (typeof actual !== 'object' || actual === null) {
      errors.push(`Expected object at ${path}, got ${typeof actual}`);
      return errors;
    }
    for (const [key, val] of Object.entries(expected)) {
      const fullPath = path ? `${path}.${key}` : key;
      if (!(key in actual)) {
        errors.push(`Missing key: ${fullPath}`);
        continue;
      }
      errors.push(...deepPartialMatch(actual[key], val, fullPath));
    }
    return errors;
  }
  if (actual !== expected) {
    errors.push(`Mismatch at ${path}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
  return errors;
}

function matchTools(actual, expectedTools) {
  const errors = [];
  const tools = actual?.result?.tools;
  if (!Array.isArray(tools)) {
    return ['result.tools is not an array'];
  }

  for (const expected of expectedTools) {
    const found = tools.find(t => t.name === expected.name);
    if (!found) {
      errors.push(`Missing tool: ${expected.name}`);
      continue;
    }
    if (found.description !== expected.description) {
      errors.push(`Tool ${expected.name} description: expected "${expected.description}", got "${found.description}"`);
    }
    const schemaErrors = deepPartialMatch(found.inputSchema, expected.inputSchema, `${expected.name}.inputSchema`);
    errors.push(...schemaErrors);
  }
  return errors;
}

function matchContentJson(actual, expectedJson) {
  const text = actual?.result?.content?.[0]?.text;
  if (!text) return ['No content text in response'];
  try {
    const parsed = JSON.parse(text);
    const errors = deepPartialMatch(parsed, expectedJson, 'content');
    return errors;
  } catch {
    return [`Content is not valid JSON: ${text.slice(0, 100)}`];
  }
}

async function run() {
  console.log(`\n  ZeroMCP Conformance Tests`);
  console.log(`  Command: ${command} ${commandArgs.join(' ')}\n`);

  const proc = spawn(command, commandArgs, { stdio: ['pipe', 'pipe', 'pipe'] });

  let stderr = '';
  proc.stderr.on('data', d => stderr += d.toString());

  // Wait for server to start
  await new Promise(r => setTimeout(r, 2000));

  let passed = 0;
  let failed = 0;
  const failures = [];

  for (const test of fixtures.tests) {
    try {
      if (test.match === 'silent') {
        // Notification — send and don't expect a response
        proc.stdin.write(JSON.stringify(test.request) + '\n');
        await new Promise(r => setTimeout(r, 100));
        console.log(`  ✓ ${test.name}`);
        passed++;
        continue;
      }

      const response = await sendRequest(proc, test.request);

      let errors = [];

      if (test.match === 'exact') {
        errors = deepPartialMatch(response, test.expect);
        for (const key of Object.keys(response)) {
          if (!(key in test.expect)) errors.push(`Unexpected key: ${key}`);
        }
      } else if (test.match === 'partial') {
        errors = deepPartialMatch(response, test.expect);
      } else if (test.match === 'tools') {
        errors = matchTools(response, test.expect_tools);
      } else if (test.match === 'tool_count') {
        const tools = response?.result?.tools;
        if (!Array.isArray(tools)) errors = ['tools not array'];
        else if (tools.length < test.expect_min_tools) errors = [`Expected at least ${test.expect_min_tools} tools, got ${tools.length}`];
      } else if (test.match === 'tool_structure') {
        const tools = response?.result?.tools;
        if (!Array.isArray(tools)) errors = ['tools not array'];
        else {
          for (const t of tools) {
            if (!t.name) errors.push('Tool missing name');
            if (!t.description && t.description !== '') errors.push(`Tool ${t.name} missing description`);
            if (!t.inputSchema) errors.push(`Tool ${t.name} missing inputSchema`);
            else if (t.inputSchema.type !== 'object') errors.push(`Tool ${t.name} inputSchema.type not object`);
          }
        }
      } else if (test.match === 'content_json') {
        errors = matchContentJson(response, test.expect_content_json);
      } else if (test.match === 'content_contains') {
        const text = response?.result?.content?.[0]?.text || '';
        if (!text.includes(test.expect_content_contains)) errors = [`Content does not contain "${test.expect_content_contains}"`];
      } else if (test.match === 'no_error') {
        if (response?.result?.isError) errors = ['Expected no error but got isError'];
      } else if (test.match === 'content_is_array') {
        if (!Array.isArray(response?.result?.content)) errors = ['result.content is not an array'];
      } else if (test.match === 'content_shape') {
        const item = response?.result?.content?.[0];
        if (!item) errors = ['No content item'];
        else {
          if (!item.type) errors.push('Content item missing type');
          if (item.text === undefined) errors.push('Content item missing text');
        }
      }

      if (errors.length === 0) {
        console.log(`  ✓ ${test.name}`);
        passed++;
      } else {
        console.log(`  ✗ ${test.name}`);
        errors.forEach(e => console.log(`    ${e}`));
        failures.push({ test: test.name, errors });
        failed++;
      }
    } catch (err) {
      console.log(`  ✗ ${test.name} — ${err.message}`);
      failures.push({ test: test.name, errors: [err.message] });
      failed++;
    }
  }

  proc.kill();

  console.log(`\n  ${passed} passed, ${failed} failed\n`);

  if (failed > 0) {
    process.exit(1);
  }
}

run().catch(err => {
  console.error('Runner error:', err.message);
  process.exit(1);
});
