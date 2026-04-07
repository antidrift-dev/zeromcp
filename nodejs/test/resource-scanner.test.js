import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { ResourceScanner } from '../dist/resource-scanner.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURES = resolve(__dirname, 'fixtures/resources');
const EMPTY_DIR = resolve(__dirname, 'fixtures/empty');

describe('ResourceScanner', () => {
  describe('static files', () => {
    it('discovers .json files with correct MIME type', async () => {
      const scanner = new ResourceScanner({ resources: FIXTURES });
      await scanner.scan();
      const r = scanner.resources.get('config');
      assert.ok(r, 'config resource should exist');
      assert.equal(r.mimeType, 'application/json');
      assert.match(r.uri, /config\.json$/);
    });

    it('discovers .md files with correct MIME type', async () => {
      const scanner = new ResourceScanner({ resources: FIXTURES });
      await scanner.scan();
      const r = scanner.resources.get('readme');
      assert.ok(r, 'readme resource should exist');
      assert.equal(r.mimeType, 'text/markdown');
    });

    it('discovers .txt files with correct MIME type', async () => {
      const scanner = new ResourceScanner({ resources: FIXTURES });
      await scanner.scan();
      const r = scanner.resources.get('notes');
      assert.ok(r, 'notes resource should exist');
      assert.equal(r.mimeType, 'text/plain');
    });

    it('can read static file content', async () => {
      const scanner = new ResourceScanner({ resources: FIXTURES });
      await scanner.scan();
      const r = scanner.resources.get('config');
      const content = await r.read();
      const parsed = JSON.parse(content);
      assert.equal(parsed.name, 'test-config');
    });

    it('static resource has description', async () => {
      const scanner = new ResourceScanner({ resources: FIXTURES });
      await scanner.scan();
      const r = scanner.resources.get('config');
      assert.ok(r.description);
      assert.match(r.description, /Static resource/);
    });
  });

  describe('dynamic resources', () => {
    it('discovers .mjs dynamic resources', async () => {
      const scanner = new ResourceScanner({ resources: FIXTURES });
      await scanner.scan();
      const r = scanner.resources.get('dynamic');
      assert.ok(r, 'dynamic resource should exist');
      assert.equal(r.mimeType, 'application/json');
      assert.equal(r.description, 'A dynamic resource');
    });

    it('can read dynamic resource content', async () => {
      const scanner = new ResourceScanner({ resources: FIXTURES });
      await scanner.scan();
      const r = scanner.resources.get('dynamic');
      const content = await r.read();
      const parsed = JSON.parse(content);
      assert.equal(parsed.dynamic, true);
    });
  });

  describe('templates', () => {
    it('discovers template resources', async () => {
      const scanner = new ResourceScanner({ resources: FIXTURES });
      await scanner.scan();
      const t = scanner.templates.get('user-template');
      assert.ok(t, 'user-template should exist');
      assert.equal(t.uriTemplate, 'resource:///users/{id}');
      assert.equal(t.mimeType, 'application/json');
    });

    it('can read template with params', async () => {
      const scanner = new ResourceScanner({ resources: FIXTURES });
      await scanner.scan();
      const t = scanner.templates.get('user-template');
      const content = await t.read({ id: '42' });
      const parsed = JSON.parse(content);
      assert.equal(parsed.userId, '42');
    });
  });

  describe('empty directory', () => {
    it('returns no resources for empty dir', async () => {
      const scanner = new ResourceScanner({ resources: EMPTY_DIR });
      await scanner.scan();
      assert.equal(scanner.resources.size, 0);
      assert.equal(scanner.templates.size, 0);
    });
  });

  describe('nonexistent directory', () => {
    it('handles missing directory gracefully', async () => {
      const scanner = new ResourceScanner({ resources: '/tmp/zeromcp_nonexistent_dir_test' });
      await scanner.scan();
      assert.equal(scanner.resources.size, 0);
    });
  });

  describe('config variations', () => {
    it('handles array of string paths', async () => {
      const scanner = new ResourceScanner({ resources: [FIXTURES] });
      await scanner.scan();
      assert.ok(scanner.resources.size > 0);
    });

    it('handles array of ToolSource objects', async () => {
      const scanner = new ResourceScanner({ resources: [{ path: FIXTURES }] });
      await scanner.scan();
      assert.ok(scanner.resources.size > 0);
    });

    it('no resources config yields empty', async () => {
      const scanner = new ResourceScanner({});
      await scanner.scan();
      assert.equal(scanner.resources.size, 0);
    });
  });
});
