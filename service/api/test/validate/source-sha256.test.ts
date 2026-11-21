import { checkMopm } from '../../src/validate/metadata';
import { ValidationFailure } from '../../src/validate/codes';
import { validatePackage } from '../../src/validate';
import { buildConda } from './builder';

const DIGEST = 'ab'.repeat(32);
const base = { schema: 2, name: 'komira-ai/json', version: '1.0.0', deps: [], native: [] };

describe('source_sha256 in <name>.mopm.json', () => {
  test('64 lowercase hex digits is accepted and kept as sourceSha256', () => {
    expect(checkMopm({ ...base, source_sha256: DIGEST }, 2).sourceSha256).toBe(DIGEST);
    expect(checkMopm({ schema: 1, name: 'json', source_sha256: DIGEST }, 1).sourceSha256).toBe(DIGEST);
  });

  test('metadata without it has no sourceSha256 key at all, so a recorded verdict does not change', () => {
    const m = checkMopm(base, 2);
    expect(m).not.toHaveProperty('sourceSha256');
    expect(m).toEqual({ name: 'komira-ai/json', version: '1.0.0', deps: [], native: [] });
  });

  test.each([
    ['63 digits', 'a'.repeat(63)],
    ['65 digits', 'a'.repeat(65)],
    ['upper case', 'A'.repeat(64)],
    ['not hex', 'g'.repeat(64)],
    ['empty', ''],
    ['a number', 12],
    ['null', null],
    ['an array', [DIGEST]],
  ])('%s is manifest_schema with the exact message', (_n, value) => {
    let failure: unknown;
    try {
      checkMopm({ ...base, source_sha256: value }, 2);
    } catch (e) {
      failure = e;
    }
    expect(failure).toBeInstanceOf(ValidationFailure);
    expect(failure).toMatchObject({ rule: 'manifest_schema', message: "<name>.mopm.json: 'source_sha256' must be 64 lowercase hex digits" });
  });

  test('through a whole archive: the digest reaches the facts, and an invalid one rejects the archive as manifest_schema', () => {
    const ok = buildConda({ name: 'komira-ai/json', mopm: { source_sha256: DIGEST } });
    const verdict = validatePackage(ok.bytes, ok.req);
    expect(verdict.ok && verdict.facts.metadata.sourceSha256).toBe(DIGEST);

    const bad = buildConda({ name: 'komira-ai/json', mopm: { source_sha256: 'nope' } });
    expect(validatePackage(bad.bytes, bad.req)).toMatchObject({ ok: false, rule: 'manifest_schema', message: "<name>.mopm.json: 'source_sha256' must be 64 lowercase hex digits" });
  });
});
