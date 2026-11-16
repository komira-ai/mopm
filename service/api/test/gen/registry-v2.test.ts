import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { ROUTES, matchRoute } from '../../src/gen/registry-v2';

const SPEC_DIR = join(__dirname, '../../../../spec/api');
const GENERATED = join(__dirname, '../../src/gen/registry-v2.ts');

/** The proto files in the order tools/api_gen.zig hashes them: registry.proto's imports depth-first, each file's imports before it. */
function protoOrder(): string[] {
  const seen = new Set<string>();
  const order: string[] = [];
  const visit = (rel: string): void => {
    if (seen.has(rel)) return;
    seen.add(rel);
    const text = readFileSync(join(SPEC_DIR, rel), 'utf8');
    for (const m of text.matchAll(/^import "(mopm\/[^"]+)";/gm)) {
      if (m[1]!.endsWith('/options.proto')) continue;
      visit(m[1]!);
    }
    order.push(rel);
  };
  visit('mopm/registry/v2/registry.proto');
  return order;
}

describe('matchRoute', () => {
  test.each(ROUTES.map((r) => [r.operationId, r] as const))('%s matches its own path with sample values', (_id, route) => {
    const sample = route.segments.map((s) => (s.startsWith('{') ? `v-${s.slice(1, -1)}` : s));
    const m = matchRoute(route.method, sample);
    expect(m?.route).toBe(route);
    const params: Record<string, string> = {};
    for (const p of route.pathParams) params[p] = `v-${p}`;
    expect(m?.params).toEqual(params);
  });

  test('a literal segment beats a parameter', () => {
    expect(matchRoute('GET', ['packages', 'a', 'b', 'versions'])?.route.operationId).toBe('listVersions');
    expect(matchRoute('GET', ['packages', 'a', 'b', '1.0.0'])?.route.operationId).toBe('getVersion');
    expect(matchRoute('GET', ['packages', 'a', 'b', '1.0.0'])?.params).toEqual({ namespace: 'a', name: 'b', version: '1.0.0' });
    expect(matchRoute('POST', ['namespaces', 'poll'])?.route.operationId).toBe('pollNamespace');
    expect(matchRoute('GET', ['namespaces', 'poll'])?.route.operationId).toBe('getNamespace');
    expect(matchRoute('GET', ['namespaces', 'poll'])?.params).toEqual({ namespace: 'poll' });
  });

  test('a method or a segment count no route has matches nothing', () => {
    expect(matchRoute('PATCH', ['me'])).toBeUndefined();
    expect(matchRoute('DELETE', ['me'])).toBeUndefined();
    expect(matchRoute('GET', [])).toBeUndefined();
    expect(matchRoute('GET', ['me', 'tokens', 'x', 'y'])).toBeUndefined();
    expect(matchRoute('GET', ['nope'])).toBeUndefined();
    expect(matchRoute('GET', ['packages', 'a', 'b', 'c', 'd', 'e'])).toBeUndefined();
  });
});

describe('generated file', () => {
  test('its sources-sha256 is the hash of the protos (run "zig build gen-api" after editing one)', () => {
    const hash = createHash('sha256');
    for (const rel of protoOrder()) hash.update(`${rel}\0`).update(readFileSync(join(SPEC_DIR, rel))).update('\0');
    const line = readFileSync(GENERATED, 'utf8').split('\n').find((l) => l.startsWith('// sources-sha256:'));
    expect(line).toBe(`// sources-sha256: ${hash.digest('hex')}`);
  });
});
