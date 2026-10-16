import fc from 'fast-check';
import { RegistryError } from '../src/errors';
import { canonicalVersion, compareVersions, isValidVersion, parseVersion, versionsEquivalent } from '../src/version';

describe('version grammar: MAJOR.MINOR.PATCH only', () => {
  test.each(['0.0.0', '1.0.0', '0.4.0', '10.20.30', '1.10.100', '99999999999999999999.0.1'])('accepts %s', (v) => {
    expect(isValidVersion(v)).toBe(true);
  });

  test.each([
    // not three parts
    '',
    '0',
    '1',
    '1.0',
    '1.2.3.4',
    '1.0.0.0',
    '1.',
    '.1',
    '1..0',
    '1.0.',
    // letters: pre-release, post-release, dev and local spellings
    '1.0rc1',
    '1.0.0rc1',
    '1.0.0-rc.1',
    '1.0.0-rc1',
    '1.0a1',
    '1.0.0a1',
    '1.0.0b2',
    '1.0.0dev',
    '1.0.0.dev1',
    '1.0.0.post1',
    '1.0.0+local',
    '1!2.0.0',
    'dev',
    'v1.0.0',
    '1.0.x',
    '1.0.0A1',
    // leading zeros, whitespace
    '01.0.0',
    '1.00.0',
    '1.0.00',
    ' 1.0.0',
    '1.0.0 ',
    '1.0.0\n',
    // digits that are not ASCII digits
    '1.0.٣',
  ])('rejects %j with invalid_version', (v) => {
    expect(isValidVersion(v)).toBe(false);
    expect(() => parseVersion(v)).toThrow(RegistryError);
    expect(() => parseVersion(v)).toThrow(expect.objectContaining({ code: 'invalid_version' }));
  });

  test('rejects a version over the length limit', () => {
    expect(isValidVersion('1.0.' + '9'.repeat(200))).toBe(false);
  });

  test('a version has one spelling: the canonical form is the version', () => {
    expect(canonicalVersion('1.2.3')).toBe('1.2.3');
    expect(() => canonicalVersion('1.2')).toThrow(expect.objectContaining({ code: 'invalid_version' }));
  });
});

describe('ordering', () => {
  test.each([
    ['1.0.0', '1.0.0', 0],
    ['1.0.0', '1.0.1', -1],
    ['1.9.0', '1.10.0', -1],
    ['1.0.9', '1.0.10', -1],
    ['2.0.0', '1.99.99', 1],
    ['99999999999999999999.0.0', '99999999999999999998.0.0', 1],
  ])('compare(%s, %s) = %i', (a, b, want) => {
    expect(compareVersions(a, b)).toBe(want);
    expect(compareVersions(b, a)).toBe(want === 0 ? 0 : -want);
    expect(versionsEquivalent(a, b)).toBe(want === 0);
  });
});

const versionArb = fc.tuple(fc.nat(30), fc.nat(30), fc.nat(30)).map((t) => t.join('.'));

describe('version properties', () => {
  test('ordering is antisymmetric, transitive, and equal exactly when the strings are', () => {
    fc.assert(
      fc.property(versionArb, versionArb, versionArb, (a, b, c) => {
        const ab = compareVersions(a, b);
        const ba = compareVersions(b, a);
        if (ab === 0 ? ba !== 0 : ba !== -ab) return false;
        if (ab <= 0 && compareVersions(b, c) <= 0 && compareVersions(a, c) > 0) return false;
        return (ab === 0) === (a === b);
      }),
    );
  });

  test('anything with a letter or a part count other than three is refused', () => {
    const bad = fc.oneof(
      fc.array(fc.nat(30), { minLength: 1, maxLength: 6 }).filter((p) => p.length !== 3).map((p) => p.join('.')),
      versionArb.chain((v) => fc.constantFrom('a1', 'b2', 'rc3', 'dev', '-rc.1', '.post1', '+x').map((s) => v + s)),
    );
    fc.assert(fc.property(bad, (v) => !isValidVersion(v)));
  });
});
