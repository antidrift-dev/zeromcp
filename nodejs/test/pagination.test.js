import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { paginate } from '../dist/pagination.js';

// Helper: manually encode/decode cursors for testing
function encodeCursor(offset) {
  return Buffer.from(String(offset)).toString('base64');
}

function decodeCursor(cursor) {
  return parseInt(Buffer.from(cursor, 'base64').toString('utf8'), 10);
}

describe('cursor encode/decode roundtrip', () => {
  it('roundtrips offset 0', () => {
    const cursor = encodeCursor(0);
    assert.equal(decodeCursor(cursor), 0);
  });

  it('roundtrips positive offset', () => {
    const cursor = encodeCursor(10);
    assert.equal(decodeCursor(cursor), 10);
  });

  it('roundtrips large offset', () => {
    const cursor = encodeCursor(9999);
    assert.equal(decodeCursor(cursor), 9999);
  });
});

describe('paginate', () => {
  it('returns all items when pageSize is 0', () => {
    const items = [1, 2, 3, 4, 5];
    const result = paginate(items, undefined, 0);
    assert.deepEqual(result.items, items);
    assert.equal(result.nextCursor, undefined);
  });

  it('returns all items when pageSize is negative', () => {
    const items = [1, 2, 3];
    const result = paginate(items, undefined, -1);
    assert.deepEqual(result.items, items);
    assert.equal(result.nextCursor, undefined);
  });

  it('returns all items when no pageSize given', () => {
    const items = [1, 2, 3];
    const result = paginate(items);
    assert.deepEqual(result.items, items);
    assert.equal(result.nextCursor, undefined);
  });

  it('returns first page with nextCursor', () => {
    const items = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9];
    const result = paginate(items, undefined, 3);
    assert.deepEqual(result.items, [0, 1, 2]);
    assert.ok(result.nextCursor);
  });

  it('returns second page from cursor', () => {
    const items = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9];
    const first = paginate(items, undefined, 3);
    const second = paginate(items, first.nextCursor, 3);
    assert.deepEqual(second.items, [3, 4, 5]);
    assert.ok(second.nextCursor);
  });

  it('returns last page without nextCursor', () => {
    const items = [0, 1, 2, 3, 4];
    const first = paginate(items, undefined, 3);
    const second = paginate(items, first.nextCursor, 3);
    assert.deepEqual(second.items, [3, 4]);
    assert.equal(second.nextCursor, undefined);
  });

  it('handles exact page boundary', () => {
    const items = [0, 1, 2, 3, 4, 5];
    const first = paginate(items, undefined, 3);
    const second = paginate(items, first.nextCursor, 3);
    assert.deepEqual(second.items, [3, 4, 5]);
    assert.equal(second.nextCursor, undefined);
  });

  it('returns empty array for empty list', () => {
    const result = paginate([], undefined, 5);
    assert.deepEqual(result.items, []);
    assert.equal(result.nextCursor, undefined);
  });

  it('returns all when pageSize larger than list', () => {
    const items = [1, 2];
    const result = paginate(items, undefined, 100);
    assert.deepEqual(result.items, [1, 2]);
    assert.equal(result.nextCursor, undefined);
  });

  it('returns empty when cursor past end', () => {
    const items = [1, 2, 3];
    const cursor = encodeCursor(100);
    const result = paginate(items, cursor, 2);
    assert.deepEqual(result.items, []);
    assert.equal(result.nextCursor, undefined);
  });

  it('handles single-item pages', () => {
    const items = ['a', 'b', 'c'];
    const p1 = paginate(items, undefined, 1);
    assert.deepEqual(p1.items, ['a']);
    const p2 = paginate(items, p1.nextCursor, 1);
    assert.deepEqual(p2.items, ['b']);
    const p3 = paginate(items, p2.nextCursor, 1);
    assert.deepEqual(p3.items, ['c']);
    assert.equal(p3.nextCursor, undefined);
  });

  it('full traversal collects all items', () => {
    const items = [0, 1, 2, 3, 4, 5, 6];
    const collected = [];
    let cursor;
    for (let i = 0; i < 20; i++) {
      const result = paginate(items, cursor, 3);
      collected.push(...result.items);
      cursor = result.nextCursor;
      if (!cursor) break;
    }
    assert.deepEqual(collected, items);
  });

  it('handles invalid cursor gracefully (falls back to start)', () => {
    const items = [1, 2, 3];
    const result = paginate(items, '!!!invalid!!!', 2);
    assert.deepEqual(result.items, [1, 2]);
    assert.ok(result.nextCursor);
  });

  it('handles non-numeric base64 cursor gracefully', () => {
    const cursor = Buffer.from('abc').toString('base64');
    const items = [1, 2, 3];
    const result = paginate(items, cursor, 2);
    assert.deepEqual(result.items, [1, 2]);
  });
});
