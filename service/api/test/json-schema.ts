/**
 * A small JSON Schema (2020-12) checker for the keywords the files in spec/ use. It exists so the tests can
 * validate output against the checked-in schemas without a new dependency. A keyword it does not implement
 * throws, so a schema that grows a new rule cannot be silently ignored.
 */
type Schema = Record<string, any>;

const ANNOTATIONS = new Set(['$schema', '$id', 'title', 'description']);

const FORMATS: Record<string, (s: string) => boolean> = {
  date: (s) => {
    const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(s);
    if (!m) return false;
    const d = new Date(Date.UTC(+m[1]!, +m[2]! - 1, +m[3]!));
    return d.getUTCFullYear() === +m[1]! && d.getUTCMonth() === +m[2]! - 1 && d.getUTCDate() === +m[3]!;
  },
  'date-time': (s) => /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/.test(s) && !Number.isNaN(Date.parse(s)),
  uri: (s) => {
    try {
      return new URL(s).protocol.length > 1;
    } catch {
      return false;
    }
  },
};

const typeOk = (t: string, v: unknown): boolean => {
  switch (t) {
    case 'object':
      return typeof v === 'object' && v !== null && !Array.isArray(v);
    case 'array':
      return Array.isArray(v);
    case 'string':
      return typeof v === 'string';
    case 'boolean':
      return typeof v === 'boolean';
    case 'integer':
      return typeof v === 'number' && Number.isInteger(v);
    default:
      throw new Error(`json-schema: unsupported type ${t}`);
  }
};

const same = (a: unknown, b: unknown) => JSON.stringify(a) === JSON.stringify(b);

/** The list of violations of `schema` by `value`, each prefixed with its JSON path; empty when valid. */
export function validate(schema: Schema, value: unknown, path = '$'): string[] {
  const errs: string[] = [];
  for (const [k, s] of Object.entries(schema)) {
    if (ANNOTATIONS.has(k)) continue;
    switch (k) {
      case 'type':
        if (!typeOk(s, value)) errs.push(`${path}: not of type ${s}`);
        break;
      case 'const':
        if (!same(value, s)) errs.push(`${path}: is not ${JSON.stringify(s)}`);
        break;
      case 'enum':
        if (!(s as unknown[]).some((e) => same(e, value))) errs.push(`${path}: ${JSON.stringify(value)} is not one of ${JSON.stringify(s)}`);
        break;
      case 'required':
        if (typeOk('object', value)) for (const r of s as string[]) if (!(r in (value as object))) errs.push(`${path}: missing ${r}`);
        break;
      case 'properties':
        if (typeOk('object', value)) {
          for (const [p, sub] of Object.entries(s as Record<string, Schema>)) {
            if (p in (value as object)) errs.push(...validate(sub, (value as any)[p], `${path}.${p}`));
          }
        }
        break;
      case 'items':
        if (Array.isArray(value)) value.forEach((v, i) => errs.push(...validate(s, v, `${path}[${i}]`)));
        break;
      case 'minItems':
        if (Array.isArray(value) && value.length < s) errs.push(`${path}: fewer than ${s} items`);
        break;
      case 'minLength':
        if (typeof value === 'string' && value.length < s) errs.push(`${path}: shorter than ${s}`);
        break;
      case 'maxLength':
        if (typeof value === 'string' && value.length > s) errs.push(`${path}: longer than ${s}`);
        break;
      case 'minimum':
        if (typeof value === 'number' && value < s) errs.push(`${path}: below ${s}`);
        break;
      case 'pattern':
        if (typeof value === 'string' && !new RegExp(s).test(value)) errs.push(`${path}: '${value}' does not match ${s}`);
        break;
      case 'format':
        if (typeof value === 'string') {
          const f = FORMATS[s];
          if (!f) throw new Error(`json-schema: unsupported format ${s}`);
          if (!f(value)) errs.push(`${path}: '${value}' is not a ${s}`);
        }
        break;
      case 'allOf':
        for (const sub of s as Schema[]) errs.push(...validate(sub, value, path));
        break;
      case 'anyOf':
        if (!(s as Schema[]).some((sub) => validate(sub, value, path).length === 0)) errs.push(`${path}: matches none of anyOf`);
        break;
      case 'if':
      case 'then':
      case 'else':
        if (k === 'if') {
          const ok = validate(s, value, path).length === 0;
          const branch = ok ? schema.then : schema.else;
          if (branch) errs.push(...validate(branch, value, path));
        }
        break;
      default:
        throw new Error(`json-schema: unsupported keyword ${k}`);
    }
  }
  return errs;
}
