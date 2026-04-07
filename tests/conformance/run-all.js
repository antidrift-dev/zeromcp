#!/usr/bin/env node

/**
 * ZeroMCP Cross-Language Conformance Suite
 * Runs multiple test suites against all implementations.
 */

import { spawn, fork } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';

const __dirname = dirname(fileURLToPath(import.meta.url));
const root = join(__dirname, '..', '..');

// ---------------------------------------------------------------------------
// Suite definitions
// ---------------------------------------------------------------------------

const protocolImplementations = [
  {
    name: 'Node.js',
    command: 'node',
    args: [join(root, 'nodejs/bin/mcp.js'), 'serve', join(root, 'nodejs/examples/tools')],
  },
  {
    name: 'Python',
    command: 'python3',
    args: ['-m', 'zeromcp', 'serve', join(root, 'python/examples/tools')],
    env: { PYTHONPATH: join(root, 'python') },
  },
  {
    name: 'Go',
    command: 'zeromcp-go',
    args: [],
  },
  {
    name: 'Ruby',
    command: 'ruby',
    args: ['-I', join(root, 'ruby/lib'), join(root, 'ruby/bin/zeromcp'), 'serve', join(root, 'ruby/tools')],
  },
  {
    name: 'Swift',
    command: existsSync('/usr/local/bin/zeromcp-swift') ? '/usr/local/bin/zeromcp-swift' : join(root, 'swift/.build/debug/zeromcp-example'),
    args: [],
    optional: true,
  },
  {
    name: 'Rust',
    command: join(root, 'rust/target/release/examples/hello'),
    args: [],
    optional: true,
  },
  {
    name: 'PHP',
    command: 'php',
    args: [join(root, 'php/zeromcp.php'), 'serve', join(root, 'php/tools')],
    optional: true,
  },
  {
    name: 'Kotlin',
    command: join(root, 'kotlin/example/build/install/example/bin/example'),
    args: [],
    env: { JAVA_TOOL_OPTIONS: '-Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8' },
    optional: true,
  },
  {
    name: 'Java',
    command: 'java',
    args: ['-Dfile.encoding=UTF-8', '-cp', join(root, 'java/target/zeromcp-0.1.1.jar') + ':' + join(root, 'java/target/deps/*') + ':/tmp/java-out', 'Main'],
    optional: true,
  },
  {
    name: 'C#',
    command: existsSync('/tmp/csharp-out/Example') ? '/tmp/csharp-out/Example' : 'dotnet',
    args: existsSync('/tmp/csharp-out/Example') ? [] : ['run', '--project', join(root, 'csharp/Example'), '--no-build'],
    optional: true,
  },
];

const sandboxToolsDir = join(__dirname, 'sandbox-tools');

const sandboxImplementations = [
  {
    name: 'Node.js',
    command: 'node',
    args: [join(root, 'nodejs/bin/mcp.js'), 'serve', sandboxToolsDir],
  },
  {
    name: 'Python',
    command: 'python3',
    args: ['-m', 'zeromcp', 'serve', sandboxToolsDir],
    env: { PYTHONPATH: join(root, 'python') },
  },
  {
    name: 'Go',
    command: existsSync('/usr/local/bin/zeromcp-go-sandbox') ? 'zeromcp-go-sandbox' : join(root, 'go/examples/sandbox-test/zeromcp-go-sandbox'),
    args: [],
    optional: true,
  },
  {
    name: 'Rust',
    command: join(root, 'rust/target/release/examples/sandbox_test'),
    args: [],
    optional: true,
  },
  {
    name: 'Java',
    command: 'java',
    args: ['-Dfile.encoding=UTF-8', '-cp', join(root, 'java/target/zeromcp-0.1.1.jar') + ':' + join(root, 'java/target/deps/*') + ':/tmp/java-out', 'SandboxTest'],
    optional: true,
  },
  {
    name: 'Kotlin',
    command: join(root, 'kotlin/example/build/install/example/bin/example'),
    args: [],
    env: { JAVA_TOOL_OPTIONS: '-Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8', ZEROMCP_SANDBOX_TEST: 'true' },
    optional: true,
  },
  {
    name: 'Ruby',
    command: 'ruby',
    args: ['-I', join(root, 'ruby/lib'), join(root, 'ruby/bin/zeromcp'), 'serve', sandboxToolsDir],
  },
  {
    name: 'PHP',
    command: 'php',
    args: [join(root, 'php/zeromcp.php'), 'serve', sandboxToolsDir],
    optional: true,
  },
  {
    name: 'Swift',
    command: existsSync('/usr/local/bin/zeromcp-swift-sandbox') ? '/usr/local/bin/zeromcp-swift-sandbox' : join(root, 'swift/.build/debug/zeromcp-sandbox-test'),
    args: [],
    optional: true,
  },
  {
    name: 'C#',
    command: existsSync('/tmp/csharp-sandbox-out/SandboxTest') ? '/tmp/csharp-sandbox-out/SandboxTest' : 'dotnet',
    args: existsSync('/tmp/csharp-sandbox-out/SandboxTest') ? [] : ['run', '--project', join(root, 'csharp/SandboxTest'), '--no-build'],
    optional: true,
  },
];

const credentialConfigPath = join(__dirname, 'credential-config.json');
const credentialToolsDir = join(__dirname, 'credential-tools');

const credentialImplementations = [
  {
    name: 'Node.js',
    command: 'node',
    args: [join(root, 'nodejs/bin/mcp.js'), 'serve', '--config', credentialConfigPath],
    env: { TEST_CRM_KEY: 'test-secret-123' },
  },
  {
    name: 'Python',
    command: 'python3',
    args: ['-m', 'zeromcp', 'serve', '--config', credentialConfigPath],
    env: { PYTHONPATH: join(root, 'python'), TEST_CRM_KEY: 'test-secret-123' },
  },
  {
    name: 'Go',
    command: existsSync('/usr/local/bin/zeromcp-go-creds') ? 'zeromcp-go-creds' : join(root, 'go/examples/credential-test/zeromcp-go-creds'),
    args: [],
    env: { ZEROMCP_CONFIG: credentialConfigPath, TEST_CRM_KEY: 'test-secret-123' },
    optional: true,
  },
  {
    name: 'Rust',
    command: join(root, 'rust/target/release/examples/credential_test'),
    args: [],
    env: { ZEROMCP_CONFIG: credentialConfigPath, TEST_CRM_KEY: 'test-secret-123' },
    optional: true,
  },
  {
    name: 'Java',
    command: 'java',
    args: ['-Dfile.encoding=UTF-8', '-cp', join(root, 'java/target/zeromcp-0.1.1.jar') + ':' + join(root, 'java/target/deps/*') + ':/tmp/java-out', 'CredentialTest'],
    env: { TEST_CRM_KEY: 'test-secret-123' },
    optional: true,
  },
  {
    name: 'Kotlin',
    command: join(root, 'kotlin/example/build/install/example/bin/example'),
    args: [],
    env: { JAVA_TOOL_OPTIONS: '-Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8', ZEROMCP_CREDENTIAL_TEST: 'true', TEST_CRM_KEY: 'test-secret-123' },
    optional: true,
  },
  {
    name: 'Swift',
    command: existsSync('/usr/local/bin/zeromcp-swift-creds') ? '/usr/local/bin/zeromcp-swift-creds' : join(root, 'swift/.build/debug/zeromcp-credential-test'),
    args: [],
    env: { TEST_CRM_KEY: 'test-secret-123' },
    optional: true,
  },
  {
    name: 'C#',
    command: existsSync('/tmp/csharp-creds-out/CredentialTest') ? '/tmp/csharp-creds-out/CredentialTest' : 'dotnet',
    args: existsSync('/tmp/csharp-creds-out/CredentialTest') ? [] : ['run', '--project', join(root, 'csharp/CredentialTest'), '--no-build'],
    env: { TEST_CRM_KEY: 'test-secret-123' },
    optional: true,
  },
  // Ruby and PHP don't support --config flag yet
];

const namespaceToolsDir = join(__dirname, 'namespace-tools');

const namespaceImplementations = [
  {
    name: 'Node.js',
    command: 'node',
    args: [join(root, 'nodejs/bin/mcp.js'), 'serve', namespaceToolsDir],
  },
  {
    name: 'Python',
    command: 'python3',
    args: ['-m', 'zeromcp', 'serve', namespaceToolsDir],
    env: { PYTHONPATH: join(root, 'python') },
  },
  {
    name: 'Ruby',
    command: 'ruby',
    args: ['-I', join(root, 'ruby/lib'), join(root, 'ruby/bin/zeromcp'), 'serve', namespaceToolsDir],
    optional: true,
  },
  {
    name: 'PHP',
    command: 'php',
    args: [join(root, 'php/zeromcp.php'), 'serve', namespaceToolsDir],
    optional: true,
  },
];

const resourceImplementations = [
  {
    name: 'Node.js',
    command: 'node',
    args: [join(root, 'nodejs/bin/mcp.js'), 'serve', '--config', join(__dirname, 'resource-config.json')],
  },
  {
    name: 'Python',
    command: 'python3',
    args: ['-m', 'zeromcp', 'serve', '--config', join(__dirname, 'resource-config-python.json')],
    env: { PYTHONPATH: join(root, 'python') },
  },
  {
    name: 'Ruby',
    command: 'ruby',
    args: ['-I', join(root, 'ruby/lib'), join(root, 'ruby/bin/zeromcp'), 'serve', '--config', join(__dirname, 'resource-config-ruby.json')],
    optional: true,
  },
  {
    name: 'PHP',
    command: 'php',
    args: [join(root, 'php/zeromcp.php'), 'serve', '--config', join(__dirname, 'resource-config-php.json')],
    optional: true,
  },
  {
    name: 'Go',
    command: existsSync('/usr/local/bin/zeromcp-go-resource') ? 'zeromcp-go-resource' : join(root, 'go/examples/resource-test/resource-test'),
    args: [],
    optional: true,
  },
  {
    name: 'Rust',
    command: join(root, 'rust/target/release/examples/resource_test'),
    args: [],
    optional: true,
  },
  {
    name: 'Java',
    command: 'java',
    args: ['-Dfile.encoding=UTF-8', '-cp', join(root, 'java/target/zeromcp-0.1.1.jar') + ':' + join(root, 'java/target/deps/*') + ':/tmp/java-out', 'ResourceTest'],
    optional: true,
  },
  {
    name: 'Kotlin',
    command: join(root, 'kotlin/example/build/install/example/bin/example'),
    args: [],
    env: { JAVA_TOOL_OPTIONS: '-Dfile.encoding=UTF-8', ZEROMCP_RESOURCE_TEST: 'true' },
    optional: true,
  },
  {
    name: 'Swift',
    command: existsSync('/usr/local/bin/zeromcp-swift-resource') ? '/usr/local/bin/zeromcp-swift-resource' : join(root, 'swift/.build/debug/zeromcp-resource-test'),
    args: [],
    optional: true,
  },
  {
    name: 'C#',
    command: existsSync('/tmp/csharp-resource-out/ResourceTest') ? '/tmp/csharp-resource-out/ResourceTest' : 'dotnet',
    args: existsSync('/tmp/csharp-resource-out/ResourceTest') ? [] : ['run', '--project', join(root, 'csharp/ResourceTest'), '--no-build'],
    optional: true,
  },
];

const suites = [
  {
    name: 'Protocol Conformance',
    fixtures: 'fixtures.json',
    implementations: protocolImplementations,
  },
  {
    name: 'Resources & Prompts',
    fixtures: 'resource-fixtures.json',
    implementations: resourceImplementations,
  },
  {
    name: 'Sandbox Enforcement',
    fixtures: 'sandbox-fixtures.json',
    implementations: sandboxImplementations,
    setup: startMockServer,
    teardown: stopMockServer,
  },
  {
    name: 'Credential Injection',
    fixtures: 'credential-fixtures.json',
    implementations: credentialImplementations,
  },
  {
    name: 'Namespace Prefixes',
    fixtures: 'namespace-fixtures.json',
    implementations: namespaceImplementations,
  },
  {
    name: 'Execute Timeout',
    fixtures: 'timeout-fixtures.json',
    implementations: [
      {
        name: 'Node.js',
        command: 'node',
        args: [join(root, 'nodejs/bin/mcp.js'), 'serve', join(__dirname, 'timeout-tools')],
      },
      {
        name: 'Python',
        command: 'python3',
        args: ['-m', 'zeromcp', 'serve', join(__dirname, 'timeout-tools')],
        env: { PYTHONPATH: join(root, 'python') },
      },
      {
        name: 'Go',
        command: existsSync('/usr/local/bin/zeromcp-go-timeout') ? 'zeromcp-go-timeout' : join(root, 'go/examples/timeout-test/zeromcp-go-timeout'),
        args: [],
        optional: true,
      },
      {
        name: 'Rust',
        command: join(root, 'rust/target/release/examples/timeout_test'),
        args: [],
        optional: true,
      },
      {
        name: 'Java',
        command: 'java',
        args: ['-Dfile.encoding=UTF-8', '-cp', join(root, 'java/target/zeromcp-0.1.1.jar') + ':' + join(root, 'java/target/deps/*') + ':/tmp/java-out', 'TimeoutTest'],
        optional: true,
      },
      {
        name: 'Kotlin',
        command: join(root, 'kotlin/example/build/install/example/bin/example'),
        args: [],
        env: { JAVA_TOOL_OPTIONS: '-Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8', ZEROMCP_TIMEOUT_TEST: 'true' },
        optional: true,
      },
      {
        name: 'Swift',
        command: existsSync('/usr/local/bin/zeromcp-swift-timeout') ? '/usr/local/bin/zeromcp-swift-timeout' : join(root, 'swift/.build/debug/zeromcp-timeout-test'),
        args: [],
        optional: true,
      },
      {
        name: 'C#',
        command: existsSync('/tmp/csharp-timeout-out/TimeoutTest') ? '/tmp/csharp-timeout-out/TimeoutTest' : 'dotnet',
        args: existsSync('/tmp/csharp-timeout-out/TimeoutTest') ? [] : ['run', '--project', join(root, 'csharp/TimeoutTest'), '--no-build'],
        optional: true,
      },
      {
        name: 'Ruby',
        command: 'ruby',
        args: ['-I', join(root, 'ruby/lib'), join(root, 'ruby/bin/zeromcp'), 'serve', join(__dirname, 'timeout-tools')],
        optional: true,
      },
      {
        name: 'PHP',
        command: 'php',
        args: [join(root, 'php/zeromcp.php'), 'serve', join(__dirname, 'timeout-tools')],
        optional: true,
      },
    ],
  },
  {
    name: 'Bypass Permissions',
    fixtures: 'bypass-fixtures.json',
    implementations: [
      {
        name: 'Node.js',
        command: 'node',
        args: [join(root, 'nodejs/bin/mcp.js'), 'serve', '--config', join(__dirname, 'bypass-config.json')],
      },
      {
        name: 'Python',
        command: 'python3',
        args: ['-m', 'zeromcp', 'serve', '--config', join(__dirname, 'bypass-config.json')],
        env: { PYTHONPATH: join(root, 'python') },
      },
      {
        name: 'Go',
        command: existsSync('/usr/local/bin/zeromcp-go-bypass') ? 'zeromcp-go-bypass' : join(root, 'go/examples/bypass-test/zeromcp-go-bypass'),
        args: [],
        env: { ZEROMCP_CONFIG: join(__dirname, 'bypass-config.json') },
        optional: true,
      },
      {
        name: 'Rust',
        command: join(root, 'rust/target/release/examples/bypass_test'),
        args: [],
        env: { ZEROMCP_CONFIG: join(__dirname, 'bypass-config.json') },
        optional: true,
      },
      {
        name: 'Java',
        command: 'java',
        args: ['-Dfile.encoding=UTF-8', '-cp', join(root, 'java/target/zeromcp-0.1.1.jar') + ':' + join(root, 'java/target/deps/*') + ':/tmp/java-out', 'BypassTest'],
        env: { ZEROMCP_BYPASS: 'true' },
        optional: true,
      },
      {
        name: 'Kotlin',
        command: join(root, 'kotlin/example/build/install/example/bin/example'),
        args: [],
        env: { JAVA_TOOL_OPTIONS: '-Dfile.encoding=UTF-8 -Dstdout.encoding=UTF-8', ZEROMCP_BYPASS_TEST: 'true', ZEROMCP_BYPASS: 'true' },
        optional: true,
      },
      {
        name: 'Swift',
        command: existsSync('/usr/local/bin/zeromcp-swift-bypass') ? '/usr/local/bin/zeromcp-swift-bypass' : join(root, 'swift/.build/debug/zeromcp-bypass-test'),
        args: [],
        env: { ZEROMCP_BYPASS: 'true' },
        optional: true,
      },
      {
        name: 'C#',
        command: existsSync('/tmp/csharp-bypass-out/BypassTest') ? '/tmp/csharp-bypass-out/BypassTest' : 'dotnet',
        args: existsSync('/tmp/csharp-bypass-out/BypassTest') ? [] : ['run', '--project', join(root, 'csharp/BypassTest'), '--no-build'],
        env: { ZEROMCP_BYPASS: 'true' },
        optional: true,
      },
      {
        name: 'Ruby',
        command: 'ruby',
        args: ['-I', join(root, 'ruby/lib'), join(root, 'ruby/bin/zeromcp'), 'serve', '--config', join(__dirname, 'bypass-config.json')],
        optional: true,
      },
      {
        name: 'PHP',
        command: 'php',
        args: [join(root, 'php/zeromcp.php'), 'serve', '--config', join(__dirname, 'bypass-config.json')],
        optional: true,
      },
    ],
    setup: startMockServer,
    teardown: stopMockServer,
  },
  {
    name: 'Credential File',
    fixtures: 'credential-file-fixtures.json',
    implementations: [
      {
        name: 'Node.js',
        command: 'node',
        args: [join(root, 'nodejs/bin/mcp.js'), 'serve', '--config', join(__dirname, 'credential-file-config.json')],
      },
      {
        name: 'Python',
        command: 'python3',
        args: ['-m', 'zeromcp', 'serve', '--config', join(__dirname, 'credential-file-config.json')],
        env: { PYTHONPATH: join(root, 'python') },
      },
      {
        name: 'Ruby',
        command: 'ruby',
        args: ['-I', join(root, 'ruby/lib'), join(root, 'ruby/bin/zeromcp'), 'serve', '--config', join(__dirname, 'credential-file-config.json')],
        optional: true,
      },
      {
        name: 'PHP',
        command: 'php',
        args: [join(root, 'php/zeromcp.php'), 'serve', '--config', join(__dirname, 'credential-file-config.json')],
        optional: true,
      },
    ],
  },
  {
    name: 'Custom Separator',
    fixtures: 'separator-fixtures.json',
    implementations: [
      {
        name: 'Node.js',
        command: 'node',
        args: [join(root, 'nodejs/bin/mcp.js'), 'serve', '--config', join(__dirname, 'separator-config.json')],
      },
      {
        name: 'Python',
        command: 'python3',
        args: ['-m', 'zeromcp', 'serve', '--config', join(__dirname, 'separator-config.json')],
        env: { PYTHONPATH: join(root, 'python') },
      },
      {
        name: 'Ruby',
        command: 'ruby',
        args: ['-I', join(root, 'ruby/lib'), join(root, 'ruby/bin/zeromcp'), 'serve', '--config', join(__dirname, 'separator-config.json')],
        optional: true,
      },
      {
        name: 'PHP',
        command: 'php',
        args: [join(root, 'php/zeromcp.php'), 'serve', '--config', join(__dirname, 'separator-config.json')],
        optional: true,
      },
    ],
  },
  {
    name: 'Multiple Tool Directories',
    fixtures: 'multi-dir-fixtures.json',
    implementations: [
      {
        name: 'Node.js',
        command: 'node',
        args: [join(root, 'nodejs/bin/mcp.js'), 'serve', '--config', join(__dirname, 'multi-dir-config.json')],
      },
      {
        name: 'Python',
        command: 'python3',
        args: ['-m', 'zeromcp', 'serve', '--config', join(__dirname, 'multi-dir-config.json')],
        env: { PYTHONPATH: join(root, 'python') },
      },
      {
        name: 'Ruby',
        command: 'ruby',
        args: ['-I', join(root, 'ruby/lib'), join(root, 'ruby/bin/zeromcp'), 'serve', '--config', join(__dirname, 'multi-dir-config.json')],
        optional: true,
      },
      {
        name: 'PHP',
        command: 'php',
        args: [join(root, 'php/zeromcp.php'), 'serve', '--config', join(__dirname, 'multi-dir-config.json')],
        optional: true,
      },
    ],
  },
];

// ---------------------------------------------------------------------------
// Mock HTTP server for sandbox tests
// ---------------------------------------------------------------------------

import { createServer } from 'node:http';

let mockServer;

async function startMockServer() {
  return new Promise((resolve) => {
    mockServer = createServer((req, res) => {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ mock: true, path: req.url }));
    });
    mockServer.listen(18923, () => resolve());
  });
}

function stopMockServer() {
  return new Promise((resolve) => {
    if (mockServer) mockServer.close(resolve);
    else resolve();
  });
}

// ---------------------------------------------------------------------------
// Test runner infrastructure
// ---------------------------------------------------------------------------

function createRequestHandler(proc) {
  const rl = createInterface({ input: proc.stdout });
  const pending = [];

  rl.on('line', (line) => {
    const trimmed = line.trim();
    if (!trimmed || pending.length === 0) return;
    const { resolve, reject, timer } = pending.shift();
    clearTimeout(timer);
    try { resolve(JSON.parse(trimmed)); }
    catch { reject(new Error(`Invalid JSON: ${trimmed.slice(0, 200)}`)); }
  });

  return (request) => {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        const idx = pending.findIndex(p => p.timer === timer);
        if (idx !== -1) pending.splice(idx, 1);
        reject(new Error('Timeout'));
      }, 10000);
      pending.push({ resolve, reject, timer });
      proc.stdin.write(JSON.stringify(request) + '\n');
    });
  };
}

function deepPartialMatch(actual, expected, path = '') {
  const errors = [];
  if (Array.isArray(expected)) {
    if (!Array.isArray(actual)) return [`Expected array at ${path}`];
    if (expected.every(v => typeof v === 'string') && actual.every(v => typeof v === 'string')) {
      const missing = expected.filter(v => !actual.includes(v));
      const extra = actual.filter(v => !expected.includes(v));
      if (missing.length) errors.push(`Missing values at ${path}: ${missing.join(', ')}`);
      if (extra.length) errors.push(`Unexpected values at ${path}: ${extra.join(', ')}`);
      return errors;
    }
    for (let i = 0; i < expected.length; i++) {
      if (i >= actual.length) { errors.push(`Missing item at ${path}[${i}]`); continue; }
      errors.push(...deepPartialMatch(actual[i], expected[i], `${path}[${i}]`));
    }
    return errors;
  }
  if (typeof expected === 'object' && expected !== null) {
    if (typeof actual !== 'object' || actual === null) return [`Expected object at ${path}`];
    for (const [key, val] of Object.entries(expected)) {
      const fp = path ? `${path}.${key}` : key;
      if (!(key in actual)) { errors.push(`Missing: ${fp}`); continue; }
      errors.push(...deepPartialMatch(actual[key], val, fp));
    }
    return errors;
  }
  if (actual !== expected) errors.push(`${path}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  return errors;
}

async function testImplementation(impl, fixtures) {
  let proc;
  try {
    const env = { ...process.env, ...(impl.env || {}) };
    proc = spawn(impl.command, impl.args, { stdio: ['pipe', 'pipe', 'pipe'], env });
  } catch {
    if (impl.optional) return { name: impl.name, passed: 0, failed: 0, skipped: true };
    return { name: impl.name, passed: 0, failed: 1, error: 'Failed to spawn' };
  }

  const started = await new Promise((resolve) => {
    proc.on('error', () => resolve(false));
    setTimeout(() => resolve(true), 2000);
  });

  if (!started) {
    if (impl.optional) return { name: impl.name, passed: 0, failed: 0, skipped: true };
    return { name: impl.name, passed: 0, failed: 1, error: 'Process failed to start' };
  }

  const send = createRequestHandler(proc);

  let passed = 0, failed = 0;
  const failures = [];

  for (const test of fixtures.tests) {
    try {
      if (test.match === 'silent') {
        proc.stdin.write(JSON.stringify(test.request) + '\n');
        await new Promise(r => setTimeout(r, 100));
        passed++;
        continue;
      }

      const response = await send(test.request);
      let errors = [];

      if (test.match === 'exact' || test.match === 'partial') {
        errors = deepPartialMatch(response, test.expect);
      } else if (test.match === 'tools') {
        const tools = response?.result?.tools;
        if (!Array.isArray(tools)) { errors = ['tools not array']; }
        else {
          for (const exp of test.expect_tools) {
            const found = tools.find(t => t.name === exp.name);
            if (!found) { errors.push(`Missing tool: ${exp.name}`); continue; }
            errors.push(...deepPartialMatch(found, exp, exp.name));
          }
        }
      } else if (test.match === 'tool_count') {
        const tools = response?.result?.tools;
        if (!Array.isArray(tools)) errors = ['tools not array'];
        else if (tools.length < test.expect_min_tools) errors = [`Expected at least ${test.expect_min_tools} tools, got ${tools.length}`];
      } else if (test.match === 'tool_structure') {
        const tools = response?.result?.tools;
        if (!Array.isArray(tools)) { errors = ['tools not array']; }
        else {
          for (const t of tools) {
            if (!t.name) errors.push(`Tool missing name`);
            if (!t.description && t.description !== '') errors.push(`Tool ${t.name} missing description`);
            if (!t.inputSchema) errors.push(`Tool ${t.name} missing inputSchema`);
            else if (t.inputSchema.type !== 'object') errors.push(`Tool ${t.name} inputSchema.type is not 'object'`);
          }
        }
      } else if (test.match === 'content_json') {
        const text = response?.result?.content?.[0]?.text;
        try { errors = deepPartialMatch(JSON.parse(text), test.expect_content_json); }
        catch { errors = ['Content not JSON']; }
      } else if (test.match === 'content_contains') {
        const text = response?.result?.content?.[0]?.text || '';
        if (!text.includes(test.expect_content_contains)) {
          errors = [`Content "${text.slice(0, 100)}" does not contain "${test.expect_content_contains}"`];
        }
      } else if (test.match === 'no_error') {
        if (response?.result?.isError) errors = ['Expected no error but got isError: true'];
      } else if (test.match === 'content_is_array') {
        const content = response?.result?.content;
        if (!Array.isArray(content)) errors = ['result.content is not an array'];
      } else if (test.match === 'content_shape') {
        const item = response?.result?.content?.[0];
        if (!item) errors = ['No content item'];
        else {
          if (!item.type) errors.push('Content item missing type');
          if (item.text === undefined) errors.push('Content item missing text');
        }
      } else if (test.match === 'tool_names') {
        const tools = response?.result?.tools;
        if (!Array.isArray(tools)) { errors = ['tools not array']; }
        else {
          const names = tools.map(t => t.name);
          for (const expected of test.expect_tool_names) {
            if (!names.includes(expected)) {
              errors.push(`Missing tool name: ${expected} (found: ${names.join(', ')})`);
            }
          }
        }
      } else if (test.match === 'custom') {
        const result = response?.result;
        const error = response?.error;
        try {
          const ok = eval(test.validate);
          if (!ok) errors = [`Custom validation failed: ${test.validate}`];
        } catch (e) {
          errors = [`Custom validation error: ${e.message} (expr: ${test.validate})`];
        }
      }

      if (errors.length === 0) passed++;
      else { failed++; failures.push({ test: test.name, errors }); }
    } catch (err) {
      failed++;
      failures.push({ test: test.name, errors: [err.message] });
    }
  }

  proc.kill();
  return { name: impl.name, passed, failed, failures };
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  console.log('\n  ZeroMCP Cross-Language Conformance Suite\n');

  let totalPassed = 0, totalFailed = 0, totalSkipped = 0;

  // Filter by --suite and --language flags
  const suiteFilter = process.argv.find((a, i) => process.argv[i - 1] === '--suite');
  const langFilter = process.argv.find((a, i) => process.argv[i - 1] === '--language');

  for (const suite of suites) {
    if (suiteFilter && suite.name.toLowerCase() !== suiteFilter.toLowerCase()) continue;

    const fixturesPath = join(__dirname, suite.fixtures);
    if (!existsSync(fixturesPath)) {
      console.log(`  ⊘ ${suite.name} — fixture file not found: ${suite.fixtures}`);
      continue;
    }
    const fixtures = JSON.parse(readFileSync(fixturesPath, 'utf8'));

    console.log(`  ${suite.name}`);

    // Setup hook
    if (suite.setup) await suite.setup();

    for (const impl of suite.implementations) {
      if (langFilter && impl.name.toLowerCase() !== langFilter.toLowerCase()) continue;
      const result = await testImplementation(impl, fixtures);

      if (result.skipped) {
        console.log(`    ⊘ ${result.name} — skipped (binary not found)`);
        totalSkipped++;
        continue;
      }

      if (result.error) {
        console.log(`    ✗ ${result.name} — ${result.error}`);
        totalFailed++;
        continue;
      }

      const total = result.passed + result.failed;
      const status = result.failed === 0 ? '✓' : '✗';
      console.log(`    ${status} ${result.name} — ${result.passed}/${total} passed`);

      if (result.failures?.length) {
        for (const f of result.failures) {
          console.log(`      ✗ ${f.test}: ${f.errors[0]}`);
        }
      }

      totalPassed += result.failed === 0 ? 1 : 0;
      totalFailed += result.failed > 0 ? 1 : 0;
    }

    // Teardown hook
    if (suite.teardown) await suite.teardown();

    console.log();
  }

  // HTTP suite (separate runner)
  if (!suiteFilter || suiteFilter.toLowerCase() === 'http') {
    try {
      const { runHttpSuite } = await import('./run-http.js');
      console.log('  HTTP Transport + Auth');
      const results = await runHttpSuite();
      for (const r of results) {
        const total = r.passed + r.failed;
        const status = r.failed === 0 ? '✓' : '✗';
        console.log(`    ${status} ${r.name} — ${r.passed}/${total} passed`);
        if (r.failures?.length) {
          for (const f of r.failures) {
            console.log(`      ✗ ${f.test}: ${f.errors[0]}`);
          }
        }
        totalPassed += r.failed === 0 ? 1 : 0;
        totalFailed += r.failed > 0 ? 1 : 0;
      }
      console.log();
    } catch (err) {
      console.log(`  ⊘ HTTP Transport + Auth — skipped (${err.message})`);
    }
  }

  console.log(`  ${totalPassed} passed, ${totalFailed} failed, ${totalSkipped} skipped\n`);
  process.exit(totalFailed > 0 ? 1 : 0);
}

main();
