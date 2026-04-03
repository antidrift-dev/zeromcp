import { describe, it } from 'node:test';
import assert from 'node:assert/strict';
import { toJsonSchema, validate } from '../dist/schema.js';

describe('toJsonSchema', () => {
  it('converts simple string types', () => {
    const schema = toJsonSchema({ name: 'string', age: 'number' });
    assert.deepEqual(schema, {
      type: 'object',
      properties: {
        name: { type: 'string' },
        age: { type: 'number' },
      },
      required: ['name', 'age'],
    });
  });

  it('handles extended form with optional fields', () => {
    const schema = toJsonSchema({
      id: 'string',
      note: { type: 'string', description: 'Optional note', optional: true },
    });
    assert.equal(schema.required.length, 1);
    assert.equal(schema.required[0], 'id');
    assert.equal(schema.properties.note.description, 'Optional note');
  });

  it('returns empty schema for no input', () => {
    const schema = toJsonSchema({});
    assert.deepEqual(schema, { type: 'object', properties: {}, required: [] });
  });
});

describe('validate', () => {
  it('catches missing required fields', () => {
    const schema = toJsonSchema({ name: 'string' });
    const errors = validate({}, schema);
    assert.equal(errors.length, 1);
    assert.match(errors[0], /Missing required field: name/);
  });

  it('catches type mismatches', () => {
    const schema = toJsonSchema({ amount: 'number' });
    const errors = validate({ amount: 'not a number' }, schema);
    assert.equal(errors.length, 1);
    assert.match(errors[0], /expected number, got string/);
  });

  it('passes valid input', () => {
    const schema = toJsonSchema({ name: 'string', count: 'number' });
    const errors = validate({ name: 'test', count: 42 }, schema);
    assert.equal(errors.length, 0);
  });
});
