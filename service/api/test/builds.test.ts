import {
  BUILD_PATTERN,
  buildOfFile,
  buildRowKey,
  buildsOf,
  compareBuilds,
  compilerOf,
  foldBuilds,
  isBuildRow,
  keyOfRecord,
  primaryBuild,
  requiresMojoOf,
  rowKeyOf,
  rowLabel,
  splitRowKey,
} from '../src/builds';
import type { VersionRecord } from '../src/types';
import { buildFile, buildRow, hex, rec } from './helpers';

const base = (over: Partial<VersionRecord> = {}) => rec({ name: 'p', version: '1.0.0', ...over });

describe('the build string', () => {
  test('mojo<compiler>_0 names its compiler; anything else names none', () => {
    expect(BUILD_PATTERN.test('mojo1.0.0_0')).toBe(true);
    expect(compilerOf('mojo1.10.2_0')).toBe('1.10.2');
    expect(compilerOf('mojo26_0')).toBe('26');
    for (const bad of ['', 'mojo_0', 'mojo1.0.0', 'mojo1.0.0_1', 'mojo1..0_0', 'py39_0', 'mojo1.0.0_0 ']) expect(compilerOf(bad)).toBeUndefined();
  });

  test('requires_mojo of a build is ==<compiler>; a string that is no build is stated as it is', () => {
    expect(requiresMojoOf('mojo1.2.0_0')).toBe('==1.2.0');
    expect(requiresMojoOf('weird')).toBe('==weird');
  });
});

describe('compareBuilds', () => {
  const sorted = (xs: string[]) => [...xs].sort(compareBuilds);

  test('compilers order numerically part by part: 1.2.0 before 1.10.0, 1.9.9 before 1.10.0', () => {
    expect(compareBuilds('mojo1.2.0_0', 'mojo1.10.0_0')).toBeLessThan(0);
    expect(compareBuilds('mojo1.10.0_0', 'mojo1.2.0_0')).toBeGreaterThan(0);
    expect(sorted(['mojo1.10.0_0', 'mojo1.9.9_0', 'mojo1.2.0_0', 'mojo0.26.1_0'])).toEqual(['mojo0.26.1_0', 'mojo1.2.0_0', 'mojo1.9.9_0', 'mojo1.10.0_0']);
  });

  test('equal compilers compare equal; a compiler that is a prefix of another sorts first', () => {
    expect(compareBuilds('mojo1.0.0_0', 'mojo1.0.0_0')).toBe(0);
    expect(compareBuilds('mojo1.0_0', 'mojo1.0.0_0')).toBeLessThan(0);
    expect(compareBuilds('mojo1.0.0_0', 'mojo1.0_0')).toBeGreaterThan(0);
    // Parts are numbers of any size.
    expect(compareBuilds('mojo1.99999999999999999999_0', 'mojo1.100000000000000000000_0')).toBeLessThan(0);
  });

  test('a string that is no build sorts after every build, and two of them by text', () => {
    expect(compareBuilds('zzz', 'mojo1.0.0_0')).toBeGreaterThan(0);
    expect(compareBuilds('mojo1.0.0_0', 'zzz')).toBeLessThan(0);
    expect(compareBuilds('a', 'b')).toBeLessThan(0);
    expect(compareBuilds('b', 'a')).toBeGreaterThan(0);
    expect(compareBuilds('a', 'a')).toBe(0);
  });
});

describe('buildOfFile', () => {
  test('the build is what the file name has after <conda name>-<version>- and before .conda', () => {
    expect(buildOfFile('p', '1.0.0', 'mojo-p-1.0.0-mojo1.1.0_0.conda')).toBe('mojo1.1.0_0');
    expect(buildOfFile('komira-ai/json', '0.1.2', 'mojo-komira-ai.json-0.1.2-mojo1.0.0_0.conda')).toBe('mojo1.0.0_0');
  });

  test('a name of another package or version, another suffix, or a build that is not mojo<compiler>_0 names no build', () => {
    expect(buildOfFile('p', '1.0.0', 'mojo-q-1.0.0-mojo1.0.0_0.conda')).toBeUndefined();
    expect(buildOfFile('p', '1.0.0', 'mojo-p-1.0.1-mojo1.0.0_0.conda')).toBeUndefined();
    expect(buildOfFile('p', '1.0.0', 'mojo-p-1.0.0-mojo1.0.0_0.tar.bz2')).toBeUndefined();
    expect(buildOfFile('p', '1.0.0', 'mojo-p-1.0.0-py39_0.conda')).toBeUndefined();
  });
});

describe('row keys', () => {
  test('buildRowKey joins the version and the build with +', () => {
    expect(buildRowKey('1.0.0', 'mojo1.1.0_0')).toBe('1.0.0+mojo1.1.0_0');
  });

  test('rowKeyOf keeps a version and a build row key, and refuses every other key with invalid_version', () => {
    expect(rowKeyOf('1.0.0')).toBe('1.0.0');
    expect(rowKeyOf('1.0.0+mojo1.1.0_0')).toBe('1.0.0+mojo1.1.0_0');
    for (const bad of ['1.0', '', '1.0.0+', '1.0.0+mojo1.1.0', '1.0.0+mojo1.1.0_0+x', '+mojo1.1.0_0', '1.0+mojo1.1.0_0', '01.0.0+mojo1.1.0_0', 'v1.0.0']) {
      expect(() => rowKeyOf(bad)).toThrow(expect.objectContaining({ code: 'invalid_version' }));
    }
  });

  test('the error for a bad build row key names the whole key', () => {
    expect(() => rowKeyOf('1.0.0+nope')).toThrow(expect.objectContaining({ detail: { version: '1.0.0+nope' } }));
  });

  test('splitRowKey and isBuildRow tell a version from a build row', () => {
    expect(splitRowKey('1.0.0')).toEqual({ canonical: '1.0.0' });
    expect(splitRowKey('1.0.0+mojo1.1.0_0')).toEqual({ canonical: '1.0.0', build: 'mojo1.1.0_0' });
    expect(isBuildRow(base())).toBe(false);
    expect(isBuildRow(buildRow('p', '1.0.0', 'mojo1.1.0_0'))).toBe(true);
  });

  test('keyOfRecord: the canonical version of an ordinary row; the key of a build row of the record\'s own version; anything else is invalid_version', () => {
    expect(keyOfRecord(base())).toBe('1.0.0');
    expect(keyOfRecord(buildRow('p', '1.0.0', 'mojo1.1.0_0'))).toBe('1.0.0+mojo1.1.0_0');
    expect(() => keyOfRecord(base({ version: '1.0' }))).toThrow(expect.objectContaining({ code: 'invalid_version' }));
    expect(() => keyOfRecord(buildRow('p', '1.0.0', 'mojo1.1.0_0', { canonical: '1.0.0+nope' }))).toThrow(expect.objectContaining({ code: 'invalid_version' }));
    // A build row of another version than the record's own.
    expect(() => keyOfRecord(buildRow('p', '1.0.0', 'mojo1.1.0_0', { canonical: '1.0.1+mojo1.1.0_0' }))).toThrow(
      expect.objectContaining({ code: 'invalid_version', message: "'1.0.1+mojo1.1.0_0' is not a row of version '1.0.0'." }),
    );
  });

  test('rowLabel names the version, and for a build row its build', () => {
    expect(rowLabel(base())).toBe('1.0.0');
    expect(rowLabel(buildRow('p', '1.0.0', 'mojo1.1.0_0'))).toBe('1.0.0 (build mojo1.1.0_0)');
  });
});

describe('buildsOf and primaryBuild', () => {
  const two = () =>
    base({
      files: [buildFile('p', '1.0.0', 'mojo1.10.0_0', 'osx-arm64'), buildFile('p', '1.0.0', 'mojo1.2.0_0', 'linux-64'), buildFile('p', '1.0.0', 'mojo1.2.0_0', 'osx-arm64'), buildFile('p', '1.0.0', 'mojo1.10.0_0', 'linux-64')],
      build: 'mojo1.2.0_0',
      requires_mojo: '==1.2.0',
    });

  test('one entry per build, sorted by compiler, each with its files sorted by subdir', () => {
    expect(buildsOf(two()).map((b) => [b.build, b.requires_mojo, b.files.map((f) => f.subdir)])).toEqual([
      ['mojo1.2.0_0', '==1.2.0', ['linux-64', 'osx-arm64']],
      ['mojo1.10.0_0', '==1.10.0', ['linux-64', 'osx-arm64']],
    ]);
  });

  test('files of one subdir are ordered by file name', () => {
    const a = buildFile('p', '1.0.0', 'mojo1.0.0_0', 'linux-64');
    const b = { ...a, filename: 'mojo-p-1.0.0-mojo1.0.0_0.a.conda' };
    expect(buildsOf({ name: 'p', version: '1.0.0', build: 'mojo1.0.0_0', files: [a, b] })[0]!.files).toEqual([b, a]);
    expect(buildsOf({ name: 'p', version: '1.0.0', build: 'mojo1.0.0_0', files: [b, a] })[0]!.files).toEqual([b, a]);
    const c = { ...a, subdir: 'noarch' };
    expect(buildsOf({ name: 'p', version: '1.0.0', build: 'mojo1.0.0_0', files: [c, a] })[0]!.files).toEqual([a, c]);
    // The same file listed twice stays listed twice.
    expect(buildsOf({ name: 'p', version: '1.0.0', build: 'mojo1.0.0_0', files: [a, a] })[0]!.files).toEqual([a, a]);
  });

  test('a file whose name names no build counts as the record\'s own build, which states the record\'s own requires_mojo', () => {
    const odd = { ...buildFile('p', '1.0.0', 'mojo1.0.0_0'), filename: 'whatever.conda' };
    const r = base({ files: [odd], build: 'mojo1.0.0_0', requires_mojo: '>=1.0' });
    expect(buildsOf(r)).toEqual([{ build: 'mojo1.0.0_0', requires_mojo: '>=1.0', files: [odd] }]);
    // Without a requires_mojo to state, the build states ==<compiler>.
    expect(buildsOf({ name: 'p', version: '1.0.0', build: 'mojo1.0.0_0', files: [odd] })[0]!.requires_mojo).toBe('==1.0.0');
  });

  test('the primary build is the one with the lowest compiler, and a record with no files has none', () => {
    expect(primaryBuild(two())!.build).toBe('mojo1.2.0_0');
    expect(primaryBuild(base({ files: [] }))).toBeUndefined();
    expect(buildsOf(base({ files: [] }))).toEqual([]);
  });
});

describe('foldBuilds', () => {
  const b11 = () => buildRow('p', '1.0.0', 'mojo1.1.0_0', { rev: 3 });

  test('a version with no build row, and a build row alone, come back as given', () => {
    const rows = [base(), base({ version: '1.1.0', canonical: '1.1.0' })];
    expect(foldBuilds(rows)).toEqual(rows);
    expect(foldBuilds([])).toEqual([]);
  });

  test('a published build row adds its files to the version, and the revision is the sum of the rows\'', () => {
    const v = base({ rev: 2 });
    const [folded, ...rest] = foldBuilds([v, b11()]);
    expect(rest).toEqual([]);
    expect(folded).toMatchObject({ canonical: '1.0.0', build: 'mojo1.0.0_0', requires_mojo: '==1.0.0', state: 'published', rev: 5 });
    expect(folded!.files.map((f) => f.filename)).toEqual(['mojo-p-1.0.0-mojo1.0.0_0.conda', 'mojo-p-1.0.0-mojo1.1.0_0.conda']);
    expect(buildsOf(folded!).map((b) => b.build)).toEqual(['mojo1.0.0_0', 'mojo1.1.0_0']);
  });

  test('the order of the rows does not matter for what a version shows', () => {
    const v = base({ rev: 2 });
    expect(foldBuilds([b11(), v])).toEqual(foldBuilds([v, b11()]));
  });

  test('a build lower than the version\'s own becomes the primary build: the top-level build and requires_mojo switch to it', () => {
    const v = base({ build: 'mojo1.2.0_0', requires_mojo: '==1.2.0', files: [buildFile('p', '1.0.0', 'mojo1.2.0_0')] });
    const [folded] = foldBuilds([v, buildRow('p', '1.0.0', 'mojo1.0.0_0')]);
    expect(folded).toMatchObject({ build: 'mojo1.0.0_0', requires_mojo: '==1.0.0' });
    expect(primaryBuild(folded!)!.build).toBe('mojo1.0.0_0');
  });

  test('a build row that is not published as a reader sees it (pending, or burned by a rejected add) is left out', () => {
    for (const state of ['pending', 'tombstoned'] as const) {
      const v = base({ rev: 2 });
      expect(foldBuilds([v, buildRow('p', '1.0.0', 'mojo1.1.0_0', { state, files: state === 'pending' ? [] : buildRow('p', '1.0.0', 'mojo1.1.0_0').files })])).toEqual([v]);
    }
  });

  test('a build row without its version\'s row is left out, and one of another version is not folded into this', () => {
    const v = base();
    expect(foldBuilds([b11()])).toEqual([]);
    expect(foldBuilds([v, buildRow('p', '1.0.1', 'mojo1.1.0_0')])).toEqual([v]);
  });

  test('a version that is pending takes no build', () => {
    const v = base({ state: 'pending', files: [], build: '', requires_mojo: '' });
    expect(foldBuilds([v, b11()])).toEqual([v]);
  });

  test('a yanked version takes its added builds along, with their urls', () => {
    const v = base({ state: 'yanked', yank_reason: 'broken', rev: 2 });
    const [folded] = foldBuilds([v, b11()]);
    expect(folded).toMatchObject({ state: 'yanked', yank_reason: 'broken', rev: 5 });
    expect(folded!.files).toHaveLength(2);
    expect(folded!.files.every((f) => f.url !== undefined)).toBe(true);
  });

  test('a tombstoned version takes its added builds along, and every file of them loses its url', () => {
    const v = base({ state: 'tombstoned', tombstone: { reason_code: 'malware', date: '2026-11-12' }, rev: 2 });
    const [folded] = foldBuilds([v, b11()]);
    expect(folded).toMatchObject({ state: 'tombstoned', rev: 5 });
    expect(folded!.files.map((f) => f.filename)).toEqual(['mojo-p-1.0.0-mojo1.0.0_0.conda', 'mojo-p-1.0.0-mojo1.1.0_0.conda']);
    // The version's own file keeps what the row held (the store does not drop it); the added build's file never shows one.
    expect(folded!.files[1]).not.toHaveProperty('url');
  });

  test('several added builds are folded, each version of the list on its own', () => {
    const rows = [base({ rev: 1 }), base({ version: '1.1.0', canonical: '1.1.0', rev: 1 }), buildRow('p', '1.0.0', 'mojo1.3.0_0'), buildRow('p', '1.0.0', 'mojo1.1.0_0'), buildRow('p', '1.1.0', 'mojo1.1.0_0', { files: [buildFile('p', '1.1.0', 'mojo1.1.0_0')] })];
    const out = foldBuilds(rows);
    expect(out.map((r) => [r.version, buildsOf(r).map((b) => b.build)])).toEqual([
      ['1.0.0', ['mojo1.0.0_0', 'mojo1.1.0_0', 'mojo1.3.0_0']],
      ['1.1.0', ['mojo1.0.0_0', 'mojo1.1.0_0']],
    ]);
    expect(out.map((r) => r.rev)).toEqual([3, 2]);
  });

  test('a folded version has a build row\'s sha256 among its files, so every file of every build is accounted for', () => {
    const [folded] = foldBuilds([base(), b11()]);
    expect(folded!.files.map((f) => f.sha256)).toEqual([hex('a'), hex('b')]);
  });

  test('a published version that has no file, folded with a build row that has none, keeps its own build and requires_mojo', () => {
    const v = base({ files: [], build: 'mojo1.0.0_0', requires_mojo: '==1.0.0' });
    const [folded] = foldBuilds([v, buildRow('p', '1.0.0', 'mojo1.1.0_0', { files: [] })]);
    expect(folded).toMatchObject({ build: 'mojo1.0.0_0', requires_mojo: '==1.0.0', files: [], rev: 1 });
  });
});
