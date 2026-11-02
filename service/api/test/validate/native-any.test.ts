import { validatePackage, RULE_TO_REJECTION } from '../../src/validate';
import type { ValidatorOptions, Verdict } from '../../src/validate';
import { decodeMirror, encodeMirror, MIRROR_MAX_AGE_MS } from '../../src/validate/native-mirror';
import type { NativeMirror } from '../../src/validate/native-mirror';
import { gzipSync } from 'node:zlib';
import { buildConda } from './builder';

/**
 * Any conda-forge package may be named in `depends` (docs/design/any-conda-forge-native.md, section 1): a malformed name or spec is
 * the only refusal; a name the conda-forge mirror does not list, an old mirror and a missing mirror each warn.
 */
const NOW = new Date('2026-11-01T12:00:00Z');
const HOUR = 3_600_000;

const mirrorOf = (names: string[], ageMs = HOUR): NativeMirror => ({ names: new Set(names), generatedAt: new Date(NOW.getTime() - ageMs) });
const LISTED = mirrorOf(['lz4-c', 'zstd', 'liblzma', 'xz', 'openssl', 'libsqlite']);

function verdictFor(depends: string[], mirror: NativeMirror | null = LISTED): Verdict {
  const b = buildConda({ index: { depends: ['mojo-compiler ==1.0.0', ...depends] } });
  const options: ValidatorOptions = { now: () => NOW, ...(mirror ? { nativeMirror: mirror } : {}) };
  return validatePackage(b.bytes, b.req, options);
}
const warningsOf = (v: Verdict): string[] | undefined => (v.ok ? v.facts.warnings : undefined);

describe('a name the mirror lists', () => {
  test.each(['lz4-c', 'zstd >=1.5,<2', 'openssl 3.*', 'liblzma >=5.4 h5eee18b_0'])('%s is accepted with no warning', (dep) => {
    const v = verdictFor([dep]);
    expect(v.ok).toBe(true);
    expect(warningsOf(v)).toBeUndefined();
  });

  test('xz, the name earlier packs wrote for lzma, and liblzma both pass with no warning', () => {
    for (const dep of ['xz >=5.4', 'liblzma >=5.4']) {
      const v = verdictFor([dep]);
      expect(v.ok).toBe(true);
      expect(warningsOf(v)).toBeUndefined();
    }
  });

  test('a package with no native dependency has nothing to warn about, whatever the mirror is', () => {
    for (const m of [null, mirrorOf([], 30 * 24 * HOUR)]) {
      const v = verdictFor([], m);
      expect(v.ok).toBe(true);
      expect(warningsOf(v)).toBeUndefined();
    }
  });

  test('the facts still list the loaded libraries of depends, sorted, with white space collapsed', () => {
    const v = verdictFor(['zstd  >=1', 'lz4-c']);
    expect(v.ok && v.facts.nativeDepends).toEqual(['lz4-c', 'zstd >=1']);
  });
});

describe('a name the mirror does not list', () => {
  test('is accepted, and the warning names it', () => {
    const v = verdictFor(['libpgn >=1']);
    expect(v.ok).toBe(true);
    const w = warningsOf(v) ?? [];
    expect(w).toHaveLength(1);
    expect(w[0]).toContain("'libpgn'");
  });

  test('each unknown name gets its own warning, in the order of depends, and a known one gets none', () => {
    const w = warningsOf(verdictFor(['zlibx', 'zstd', 'libfoo'])) ?? [];
    expect(w).toHaveLength(2);
    expect(w[0]).toContain("'zlibx'");
    expect(w[1]).toContain("'libfoo'");
  });

  test('names that earlier versions of the registry refused are accepted now', () => {
    for (const dep of ['python >=3', 'lz4 >=1', 'xz-tools', 'liblzma-devel', 'zlib', 'aws-lc']) {
      expect(verdictFor([dep]).ok).toBe(true);
    }
  });
});

describe('a mirror that is old', () => {
  test('at a day it is not stale; past a day it warns, naming when it was made, and the publish is accepted', () => {
    const edge = verdictFor(['zstd'], mirrorOf(['zstd'], MIRROR_MAX_AGE_MS));
    expect(edge.ok).toBe(true);
    expect(warningsOf(edge)).toBeUndefined();
    const stale = verdictFor(['zstd'], mirrorOf(['zstd'], MIRROR_MAX_AGE_MS + 1000));
    expect(stale.ok).toBe(true);
    const w = warningsOf(stale) ?? [];
    expect(w).toHaveLength(1);
    expect(w[0]).toContain('more than a day old');
    expect(w[0]).toContain('2026-10-31T11:59:59.000Z');
  });

  test('an unknown name is still reported against an old mirror, after the warning about the mirror', () => {
    const w = warningsOf(verdictFor(['libpgn'], mirrorOf(['zstd'], 2 * 24 * HOUR))) ?? [];
    expect(w).toHaveLength(2);
    expect(w[0]).toContain('more than a day old');
    expect(w[1]).toContain("'libpgn'");
  });
});

describe('a mirror that is missing', () => {
  test('is accepted with one warning that the names were not checked, however many there are', () => {
    const v = verdictFor(['zstd', 'libpgn'], null);
    expect(v.ok).toBe(true);
    const w = warningsOf(v) ?? [];
    expect(w).toHaveLength(1);
    expect(w[0]).toContain('could not be read');
  });

  test('the library default is no mirror: it accepts and warns, and no longer refuses', () => {
    const b = buildConda({ index: { depends: ['mojo-compiler ==1.0.0', 'lz4-c >=1.9.3,<2'] } });
    const v = validatePackage(b.bytes, b.req);
    expect(v.ok).toBe(true);
    expect((v.ok && v.facts.warnings) || []).toHaveLength(1);
  });
});

describe('what is still refused: malformed text', () => {
  test.each([
    ['an upper-case name', 'LZ4-C'],
    ['a name with a character outside [a-z0-9._-]', 'lz4_c!'],
    ['a name that starts with a dash', '-zstd'],
    ['a name run into its version', 'zstd>=1'],
    ['a name with a slash', 'conda-forge/zstd'],
    ['a name of 129 characters', 'a'.repeat(129)],
    ['a spec with four parts', 'zstd >=1 h123 extra'],
    ['a version with a semicolon', 'zstd >=1;x'],
    ['a version with a quote', "zstd '>=1'"],
    ['a build string with a slash', 'zstd >=1 h/123'],
    ['a spec of over 256 characters', `zstd >=${'1'.repeat(300)}`],
    ['a spec with leading space', ' zstd'],
  ])('%s is refused with dependency_not_allowed', (_what, dep) => {
    const v = verdictFor([dep]);
    expect(v.ok).toBe(false);
    if (v.ok) return;
    expect(v.rule).toBe('dependency_not_allowed');
    expect(v.rejection_code).toBe(RULE_TO_REJECTION.dependency_not_allowed);
  });

  test('the bare mojo- prefix is not a package: refused, with or without a mirror', () => {
    for (const m of [LISTED, null]) {
      const v = verdictFor(['mojo-'], m);
      expect(v.ok).toBe(false);
      if (!v.ok) expect(v.rule).toBe('dependency_not_allowed');
    }
  });

  test('a mojo- name is a Mojo package and never passes as a native one: undeclared in the metadata deps, it is refused', () => {
    for (const dep of ['mojo-json', 'mojo-Json', 'mojo-js!on']) {
      const v = verdictFor([dep], mirrorOf([dep]));
      expect(v.ok).toBe(false);
      if (!v.ok) expect(v.rule).toBe('deps_mismatch');
    }
  });

  test('a malformed name is refused even when the mirror is missing or old', () => {
    expect(verdictFor(['BAD'], null).ok).toBe(false);
    expect(verdictFor(['BAD'], mirrorOf([], 30 * 24 * HOUR)).ok).toBe(false);
  });

  test('the id of a native library the package ships, when it is not a conda name, is refused as a dependency', () => {
    const b = buildConda({
      mopm: { native: [{ id: 'komira_libc_posix', soname: 'libkomira_libc_posix.a', kind: 'static', mode: 'link', static_file: '../libkomira_libc_posix.a' }] },
      pkgExtra: [{ path: 'lib/libkomira_libc_posix.a', data: '!<arch>\n' }],
      index: { depends: ['mojo-compiler ==1.0.0', 'Komira_Libc_Posix'] },
    });
    const v = validatePackage(b.bytes, b.req, { now: () => NOW, nativeMirror: LISTED });
    expect(v.ok).toBe(false);
  });
});

describe('the mirror object', () => {
  test('is written and read back: the names, and the time it was made', () => {
    const at = new Date('2026-11-01T03:00:00Z');
    const m = decodeMirror(encodeMirror(['zstd', 'lz4-c', 'zstd'], at));
    expect([...m.names].sort()).toEqual(['lz4-c', 'zstd']);
    expect(m.generatedAt.toISOString()).toBe(at.toISOString());
  });

  test('the same names and time are the same bytes, whatever the order they came in', () => {
    const at = new Date('2026-11-01T03:00:00Z');
    expect(encodeMirror(['b', 'a'], at).equals(encodeMirror(['a', 'b'], at))).toBe(true);
  });

  test('a name that is not a conda name is left out', () => {
    expect([...decodeMirror(encodeMirror(['ok', 'No', 'a b', ''], new Date())).names]).toEqual(['ok']);
  });

  test('an object that is not a mirror is an error for the reader: not gzip, no header, no time', () => {
    expect(() => decodeMirror(Buffer.from('not gzip'))).toThrow();
    expect(() => decodeMirror(gzipSync('zstd\nlz4-c\n'))).toThrow('header');
    expect(() => decodeMirror(gzipSync('# mopm native-name mirror v1 generated=yesterday\nzstd\n'))).toThrow('time');
  });
});
