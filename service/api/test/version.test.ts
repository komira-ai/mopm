import fc from 'fast-check';
import { RegistryError } from '../src/errors';
import { canonicalVersion, compareVersions, isValidVersion, parseVersion, versionsEquivalent } from '../src/version';

describe('version grammar', () => {
  test.each(['0', '1', '1.0', '1.0.0', '10.20.30', '1.0a1', '1.0b2', '1.0rc10', '1.0dev0', '1.0.0a0'])('accepts %s', (v) => {
    expect(isValidVersion(v)).toBe(true);
  });

  test.each(['', '1.', '.1', '01.0', '1.00', 'v1.0', '1.0-1', '1.0.post1', '1.0rc', '1.0a1b2', '1.0a', '1..0', ' 1.0', '1.0 ', '1.0+local', '1!2.0', 'a1', '1.0.0.x', '1.0A1', '1.0a01'])(
    'rejects %j',
    (v) => {
      expect(() => parseVersion(v)).toThrow(RegistryError);
      expect(() => parseVersion(v)).toThrow(expect.objectContaining({ code: 'invalid_version' }));
    },
  );

  test('rejects a version over the length limit', () => {
    expect(isValidVersion('1.' + '0.'.repeat(100) + '1')).toBe(false);
  });
});

describe('canonical form', () => {
  test.each([
    ['1.0', '1'],
    ['1.0.0', '1'],
    ['1', '1'],
    ['0', '0'],
    ['0.0.0', '0'],
    ['1.0.1', '1.0.1'],
    ['1.10', '1.10'],
    ['1.0a1', '1a1'],
    ['1.0.0a1', '1a1'],
    ['2.0.0rc3', '2rc3'],
  ])('%s -> %s', (v, c) => {
    expect(canonicalVersion(v)).toBe(c);
  });
});

describe('equivalence and ordering', () => {
  test.each([
    ['1.0', '1.0.0', 0],
    ['1', '1.0.0.0', 0],
    ['1.0a1', '1.0.0a1', 0],
    ['1.0', '1.0.1', -1],
    ['1.0.1', '1.0', 1],
    ['1.9', '1.10', -1],
    ['1.10', '1.9', 1],
    ['1.0a1', '1.0', -1],
    ['1.0', '1.0a1', 1],
    ['1.0.1a1', '1.0', 1],
    ['1.0dev0', '1.0a0', -1],
    ['1.0a9', '1.0b0', -1],
    ['1.0b9', '1.0rc0', -1],
    ['1.0rc9', '1.0', -1],
    ['1.0a2', '1.0a10', -1],
    ['99999999999999999999.0', '99999999999999999998.0', 1],
  ])('compare(%s, %s) = %i', (a, b, want) => {
    expect(compareVersions(a, b)).toBe(want);
    expect(compareVersions(b, a)).toBe(want === 0 ? 0 : -want);
    expect(versionsEquivalent(a, b)).toBe(want === 0);
  });
});

const versionArb = fc
  .tuple(
    fc.array(fc.nat(30), { minLength: 1, maxLength: 5 }),
    fc.option(fc.tuple(fc.constantFrom('dev', 'a', 'b', 'rc'), fc.nat(20)), { nil: undefined }),
  )
  .map(([rel, pre]) => rel.join('.') + (pre ? `${pre[0]}${pre[1]}` : ''));

describe('version properties', () => {
  test('canonical is idempotent', () => {
    fc.assert(fc.property(versionArb, (v) => canonicalVersion(canonicalVersion(v)) === canonicalVersion(v)));
  });

  test('padding with zero segments never changes the version', () => {
    fc.assert(
      fc.property(versionArb, fc.nat(3), (v, k) => {
        const m = /^([0-9.]+)(.*)$/.exec(v)!;
        return versionsEquivalent(v, m[1] + '.0'.repeat(k) + m[2]);
      }),
    );
  });

  test('ordering is antisymmetric, transitive, and equal exactly when canonical forms are', () => {
    fc.assert(
      fc.property(versionArb, versionArb, versionArb, (a, b, c) => {
        const ab = compareVersions(a, b);
        const ba = compareVersions(b, a);
        if (ab === 0 ? ba !== 0 : ba !== -ab) return false;
        if (ab <= 0 && compareVersions(b, c) <= 0 && compareVersions(a, c) > 0) return false;
        return (ab === 0) === (canonicalVersion(a) === canonicalVersion(b));
      }),
    );
  });
});

describe('why equivalence needs the canonical key', () => {
  // Can-fail proof for the 1.0 vs 1.0.0 rule: keyed on the spelling, both would be accepted.
  test('a key made from the spelling accepts 1.0 and 1.0.0; the canonical key does not', () => {
    const bySpelling = new Set<string>();
    const byCanonical = new Set<string>();
    const accept = (set: Set<string>, key: string) => (set.has(key) ? false : (set.add(key), true));
    expect(['1.0', '1.0.0'].map((v) => accept(bySpelling, v))).toEqual([true, true]);
    expect(['1.0', '1.0.0'].map((v) => accept(byCanonical, canonicalVersion(v)))).toEqual([true, false]);
  });
});
