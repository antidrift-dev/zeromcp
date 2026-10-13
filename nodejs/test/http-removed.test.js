import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { serve } from '../dist/server.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const BIN = resolve(__dirname, '../bin/mcp.js');
const TOOLS = resolve(__dirname, '../examples/tools');

describe('built-in HTTP transport removed', () => {
  it('serve() rejects an http transport and names createRegistry', async () => {
    await assert.rejects(
      serve({ tools: TOOLS, transport: { type: 'http' } }),
      (err) => {
        assert.match(err.message, /built-in HTTP transport was removed/);
        assert.match(err.message, /createRegistry/);
        assert.match(err.message, /createHandler/);
        return true;
      },
    );
  });

  it('serve() rejects when http appears in a transport array', async () => {
    await assert.rejects(
      serve({ tools: TOOLS, transport: [{ type: 'stdio' }, { type: 'http' }] }),
      /createRegistry/,
    );
  });

  it('`zeromcp serve http` exits 1 with the message on stderr', async () => {
    const proc = spawn('node', [BIN, 'serve', TOOLS, 'http'], {
      stdio: ['pipe', 'pipe', 'pipe'],
    });
    let stderr = '';
    proc.stderr.on('data', (d) => { stderr += d.toString(); });
    const code = await new Promise((res, rej) => {
      const t = setTimeout(() => { proc.kill(); rej(new Error('Timeout')); }, 5000);
      proc.on('exit', (c) => { clearTimeout(t); res(c); });
    });
    assert.equal(code, 1);
    assert.match(stderr, /\[zeromcp\] The built-in HTTP transport was removed/);
    assert.match(stderr, /createRegistry/);
    assert.doesNotMatch(stderr, /tool\(s\)/, 'should fail before scanning tools');
  });
});
