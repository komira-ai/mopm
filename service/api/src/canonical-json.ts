/**
 * Deterministic JSON: object keys sorted by UTF-16 code unit at every depth, compact separators, no
 * undefined members. Numbers must be safe integers: the index never carries a float, and refusing one
 * is what makes number formatting stable.
 */
export function canonicalJson(value: unknown): string {
  return JSON.stringify(sortDeep(value));
}

function sortDeep(v: unknown): unknown {
  if (v === null || typeof v === 'string' || typeof v === 'boolean') return v;
  if (typeof v === 'number') {
    if (!Number.isSafeInteger(v)) throw new Error(`canonicalJson: ${v} is not a safe integer`);
    return v;
  }
  if (Array.isArray(v)) return v.map(sortDeep);
  if (typeof v === 'object') {
    const o = v as Record<string, unknown>;
    const out: Record<string, unknown> = {};
    for (const k of Object.keys(o).sort()) {
      if (o[k] !== undefined) out[k] = sortDeep(o[k]);
    }
    return out;
  }
  throw new Error(`canonicalJson: unsupported ${typeof v}`);
}
