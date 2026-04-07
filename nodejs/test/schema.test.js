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

  it('maps boolean type', () => {
    const schema = toJsonSchema({ flag: 'boolean' });
    assert.deepEqual(schema.properties.flag, { type: 'boolean' });
    assert.deepEqual(schema.required, ['flag']);
  });

  it('maps object type', () => {
    const schema = toJsonSchema({ data: 'object' });
    assert.deepEqual(schema.properties.data, { type: 'object' });
  });

  it('maps array type', () => {
    const schema = toJsonSchema({ items: 'array' });
    assert.deepEqual(schema.properties.items, { type: 'array' });
  });

  it('maps all five simple types correctly', () => {
    const schema = toJsonSchema({
      s: 'string',
      n: 'number',
      b: 'boolean',
      o: 'object',
      a: 'array',
    });
    assert.equal(schema.properties.s.type, 'string');
    assert.equal(schema.properties.n.type, 'number');
    assert.equal(schema.properties.b.type, 'boolean');
    assert.equal(schema.properties.o.type, 'object');
    assert.equal(schema.properties.a.type, 'array');
    assert.equal(schema.required.length, 5);
  });

  it('throws on unknown simple type', () => {
    assert.throws(() => toJsonSchema({ x: 'int' }), /Unknown type "int"/);
  });

  it('throws on unknown extended type', () => {
    assert.throws(() => toJsonSchema({ x: { type: 'float' } }), /Unknown type "float"/);
  });

  it('extended form without description omits it', () => {
    const schema = toJsonSchema({ x: { type: 'number' } });
    assert.equal(schema.properties.x.type, 'number');
    assert.equal(schema.properties.x.description, undefined);
    assert.deepEqual(schema.required, ['x']);
  });

  it('extended form with optional: false is required', () => {
    const schema = toJsonSchema({ x: { type: 'string', optional: false } });
    assert.deepEqual(schema.required, ['x']);
  });

  it('mixes simple and extended fields', () => {
    const schema = toJsonSchema({
      name: 'string',
      age: { type: 'number', description: 'User age', optional: true },
      active: 'boolean',
    });
    assert.deepEqual(schema.required, ['name', 'active']);
    assert.equal(schema.properties.age.description, 'User age');
  });

  it('multiple optional fields yields empty required', () => {
    const schema = toJsonSchema({
      a: { type: 'string', optional: true },
      b: { type: 'number', optional: true },
    });
    assert.deepEqual(schema.required, []);
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

  it('reports multiple errors at once', () => {
    const schema = toJsonSchema({ a: 'string', b: 'number', c: 'boolean' });
    const errors = validate({}, schema);
    assert.equal(errors.length, 3);
  });

  it('catches missing required plus type mismatch', () => {
    const schema = toJsonSchema({ a: 'string', b: 'number' });
    const errors = validate({ b: 'wrong' }, schema);
    assert.equal(errors.length, 2);
    assert.ok(errors.some(e => e.includes('Missing required field: a')));
    assert.ok(errors.some(e => e.includes('expected number, got string')));
  });

  it('skips optional missing fields', () => {
    const schema = toJsonSchema({
      required_f: 'string',
      optional_f: { type: 'number', optional: true },
    });
    const errors = validate({ required_f: 'ok' }, schema);
    assert.equal(errors.length, 0);
  });

  it('validates optional field type when present', () => {
    const schema = toJsonSchema({
      opt: { type: 'number', optional: true },
    });
    const errors = validate({ opt: 'wrong' }, schema);
    assert.equal(errors.length, 1);
    assert.match(errors[0], /expected number, got string/);
  });

  it('validates boolean type correctly', () => {
    const schema = toJsonSchema({ flag: 'boolean' });
    assert.equal(validate({ flag: true }, schema).length, 0);
    assert.equal(validate({ flag: false }, schema).length, 0);
    assert.equal(validate({ flag: 'yes' }, schema).length, 1);
  });

  it('validates array type correctly', () => {
    const schema = toJsonSchema({ items: 'array' });
    assert.equal(validate({ items: [1, 2, 3] }, schema).length, 0);
    assert.equal(validate({ items: 'not array' }, schema).length, 1);
  });

  it('validates object type correctly', () => {
    const schema = toJsonSchema({ data: 'object' });
    assert.equal(validate({ data: { a: 1 } }, schema).length, 0);
    assert.equal(validate({ data: 'string' }, schema).length, 1);
  });

  it('ignores extra fields not in schema', () => {
    const schema = toJsonSchema({ name: 'string' });
    const errors = validate({ name: 'ok', extra: 123 }, schema);
    assert.equal(errors.length, 0);
  });

  it('handles null input value as missing required', () => {
    const schema = toJsonSchema({ name: 'string' });
    const errors = validate({ name: null }, schema);
    // null triggers missing-required check
    assert.ok(errors.some(e => e.includes('Missing required field: name')));
  });
});
