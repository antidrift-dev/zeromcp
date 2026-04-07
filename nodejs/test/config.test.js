import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { resolveToolSources, resolveIcon } from '../dist/config.js';

const __dirname = dirname(fileURLToPath(import.meta.url));

describe('resolveToolSources', () => {
  it('returns default path when undefined', () => {
    const result = resolveToolSources(undefined);
    assert.deepEqual(result, [{ path: './tools' }]);
  });

  it('returns default path when no argument', () => {
    const result = resolveToolSources();
    assert.deepEqual(result, [{ path: './tools' }]);
  });

  it('wraps a single string in array', () => {
    const result = resolveToolSources('./my-tools');
    assert.deepEqual(result, [{ path: './my-tools' }]);
  });

  it('wraps string entries in array', () => {
    const result = resolveToolSources(['./a', './b']);
    assert.deepEqual(result, [{ path: './a' }, { path: './b' }]);
  });

  it('passes through ToolSource objects', () => {
    const result = resolveToolSources([{ path: './x', prefix: 'ns' }]);
    assert.deepEqual(result, [{ path: './x', prefix: 'ns' }]);
  });

  it('mixes strings and ToolSource objects', () => {
    const result = resolveToolSources(['./a', { path: './b', prefix: 'p' }]);
    assert.equal(result.length, 2);
    assert.deepEqual(result[0], { path: './a' });
    assert.deepEqual(result[1], { path: './b', prefix: 'p' });
  });
});

describe('resolveIcon', () => {
  it('returns undefined for undefined input', async () => {
    const result = await resolveIcon(undefined);
    assert.equal(result, undefined);
  });

  it('returns undefined for empty string', async () => {
    const result = await resolveIcon('');
    assert.equal(result, undefined);
  });

  it('passes through data URI unchanged', async () => {
    const dataUri = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUg==';
    const result = await resolveIcon(dataUri);
    assert.equal(result, dataUri);
  });

  it('passes through data URI with different mime type', async () => {
    const dataUri = 'data:image/svg+xml;base64,PHN2Zy8+';
    const result = await resolveIcon(dataUri);
    assert.equal(result, dataUri);
  });

  it('reads icon from file path', async () => {
    const iconPath = resolve(__dirname, 'fixtures/icon.png');
    const result = await resolveIcon(iconPath);
    assert.ok(result);
    assert.ok(result.startsWith('data:image/png;base64,'));
  });

  it('returns undefined for nonexistent file path', async () => {
    const result = await resolveIcon('/tmp/zeromcp_nonexistent_icon.png');
    assert.equal(result, undefined);
  });

  it('returns undefined for invalid URL', async () => {
    const result = await resolveIcon('https://localhost:1/nonexistent-icon.png');
    assert.equal(result, undefined);
  });

  it('detects jpg mime type from extension', async () => {
    // We only test that the function handles the path; since the file does not exist,
    // it returns undefined. The MIME detection is internal.
    // To test MIME detection we create a fake jpg fixture.
    const { writeFile, unlink } = await import('node:fs/promises');
    const tmpPath = resolve(__dirname, 'fixtures/test-icon.jpg');
    await writeFile(tmpPath, 'FAKE JPG');
    try {
      const result = await resolveIcon(tmpPath);
      assert.ok(result);
      assert.ok(result.startsWith('data:image/jpeg;base64,'));
    } finally {
      await unlink(tmpPath);
    }
  });
});
