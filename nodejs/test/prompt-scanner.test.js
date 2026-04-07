import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { PromptScanner } from '../dist/prompt-scanner.js';

const __dirname = dirname(fileURLToPath(import.meta.url));
const FIXTURES = resolve(__dirname, 'fixtures/prompts');

describe('PromptScanner', () => {
  describe('loading prompts', () => {
    it('discovers prompt files', async () => {
      const scanner = new PromptScanner({ prompts: FIXTURES });
      await scanner.scan();
      assert.ok(scanner.prompts.size >= 2, `expected at least 2, got ${scanner.prompts.size}`);
    });

    it('loads greeting prompt with description', async () => {
      const scanner = new PromptScanner({ prompts: FIXTURES });
      await scanner.scan();
      const p = scanner.prompts.get('greeting');
      assert.ok(p, 'greeting prompt should exist');
      assert.equal(p.description, 'Greet someone');
    });

    it('loads review prompt with arguments', async () => {
      const scanner = new PromptScanner({ prompts: FIXTURES });
      await scanner.scan();
      const p = scanner.prompts.get('review');
      assert.ok(p, 'review prompt should exist');
      assert.ok(p.arguments);
      assert.equal(p.arguments.length, 2);
    });
  });

  describe('arguments parsing', () => {
    it('simple string argument is required', async () => {
      const scanner = new PromptScanner({ prompts: FIXTURES });
      await scanner.scan();
      const p = scanner.prompts.get('greeting');
      const nameArg = p.arguments.find(a => a.name === 'name');
      assert.ok(nameArg);
      assert.equal(nameArg.required, true);
    });

    it('extended optional argument has required=false', async () => {
      const scanner = new PromptScanner({ prompts: FIXTURES });
      await scanner.scan();
      const p = scanner.prompts.get('review');
      const langArg = p.arguments.find(a => a.name === 'language');
      assert.ok(langArg);
      assert.equal(langArg.required, false);
      assert.equal(langArg.description, 'Programming language');
    });

    it('extended required argument has required=true', async () => {
      const scanner = new PromptScanner({ prompts: FIXTURES });
      await scanner.scan();
      const p = scanner.prompts.get('review');
      const codeArg = p.arguments.find(a => a.name === 'code');
      assert.ok(codeArg);
      assert.equal(codeArg.required, true);
    });
  });

  describe('rendering', () => {
    it('renders greeting with args', async () => {
      const scanner = new PromptScanner({ prompts: FIXTURES });
      await scanner.scan();
      const p = scanner.prompts.get('greeting');
      const messages = await p.render({ name: 'Alice' });
      assert.equal(messages.length, 1);
      assert.equal(messages[0].role, 'user');
      assert.match(messages[0].content.text, /Hello, Alice!/);
    });

    it('renders review with code arg', async () => {
      const scanner = new PromptScanner({ prompts: FIXTURES });
      await scanner.scan();
      const p = scanner.prompts.get('review');
      const messages = await p.render({ code: 'x = 1', language: 'python' });
      assert.equal(messages.length, 1);
      assert.match(messages[0].content.text, /python/);
      assert.match(messages[0].content.text, /x = 1/);
    });
  });

  describe('config variations', () => {
    it('handles array of string paths', async () => {
      const scanner = new PromptScanner({ prompts: [FIXTURES] });
      await scanner.scan();
      assert.ok(scanner.prompts.size >= 2);
    });

    it('handles array of ToolSource objects', async () => {
      const scanner = new PromptScanner({ prompts: [{ path: FIXTURES }] });
      await scanner.scan();
      assert.ok(scanner.prompts.size >= 2);
    });

    it('no prompts config yields empty', async () => {
      const scanner = new PromptScanner({});
      await scanner.scan();
      assert.equal(scanner.prompts.size, 0);
    });

    it('nonexistent directory yields empty', async () => {
      const scanner = new PromptScanner({ prompts: '/tmp/zeromcp_nonexistent_prompts' });
      await scanner.scan();
      assert.equal(scanner.prompts.size, 0);
    });
  });
});
