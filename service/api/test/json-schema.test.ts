import { validate } from './json-schema';

describe('the schema checker keywords the checked-in specs use', () => {
  test('uniqueItems: a repeated item is refused, distinct items and objects with equal text are judged by value', () => {
    const schema = { type: 'array', uniqueItems: true };
    expect(validate(schema, [1, 2, 3])).toEqual([]);
    expect(validate(schema, [{ a: 1 }, { a: 2 }])).toEqual([]);
    expect(validate(schema, [1, 2, 1])).toEqual(['$: items are not unique']);
    expect(validate(schema, [{ a: 1 }, { a: 1 }])).toEqual(['$: items are not unique']);
    expect(validate({ uniqueItems: false }, [1, 1])).toEqual([]);
  });

  test('$ref to $defs: the target is applied, at any depth, and a failing target is reported at the path', () => {
    const schema = {
      $defs: { Name: { type: 'string', pattern: '^[a-z]+$' } },
      type: 'object',
      properties: { name: { $ref: '#/$defs/Name' }, deps: { type: 'array', items: { type: 'object', properties: { name: { $ref: '#/$defs/Name' } } } } },
      allOf: [{ if: { required: ['deps'] }, then: { properties: { name: { $ref: '#/$defs/Name' } } } }],
    };
    expect(validate(schema, { name: 'ab', deps: [{ name: 'cd' }] })).toEqual([]);
    expect(validate(schema, { name: 'AB' }).length).toBe(1);
    expect(validate(schema, { name: 'ab', deps: [{ name: 'C' }] })).toEqual(["$.deps[0].name: 'C' does not match ^[a-z]+$"]);
    expect(validate(schema, { name: 'AB', deps: [] }).length).toBe(2);
  });

  test('a $ref that is not a local $defs entry throws rather than passing', () => {
    expect(() => validate({ $ref: '#/$defs/Missing' }, 1)).toThrow(/unresolvable \$ref/);
    expect(() => validate({ $ref: 'other.json#/x' }, 1)).toThrow(/unresolvable \$ref/);
  });

  test('a keyword it does not implement throws', () => {
    expect(() => validate({ multipleOf: 2 }, 4)).toThrow(/unsupported keyword multipleOf/);
  });
});
