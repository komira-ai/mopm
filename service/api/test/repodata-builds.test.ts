import { foldBuilds } from '../src/builds';
import { buildRepodataJson } from '../src/repodata';
import type { VersionRecord } from '../src/types';
import { buildFile, buildRow, rec } from './helpers';

const entries = (subdir: string, rows: Parameters<typeof buildRepodataJson>[1]) => JSON.parse(buildRepodataJson(subdir, rows));

/** The version 1.0.0 of `p`, built with Mojo 1.2.0 for linux-64 and osx-arm64, with a build for Mojo 1.0.0 added to it later. */
const rows = (over: Partial<VersionRecord> = {}) =>
  foldBuilds([
    rec({
      name: 'p',
      version: '1.0.0',
      build: 'mojo1.2.0_0',
      requires_mojo: '==1.2.0',
      deps: [{ name: 'q', range: '>=1' }],
      native_depends: ['lz4-c >=1.9.3'],
      files: [buildFile('p', '1.0.0', 'mojo1.2.0_0', 'linux-64', 'a'), buildFile('p', '1.0.0', 'mojo1.2.0_0', 'osx-arm64', 'b')],
      rev: 1,
      ...over,
    }),
    buildRow('p', '1.0.0', 'mojo1.0.0_0', { files: [buildFile('p', '1.0.0', 'mojo1.0.0_0', 'linux-64', 'c')] }),
  ]);

describe('repodata of a version with several builds', () => {
  test('each file is listed under its own build, and its depends pin that build\'s compiler', () => {
    const linux = entries('linux-64', rows())['packages.conda'];
    expect(Object.keys(linux)).toEqual(['mojo-p-1.0.0-mojo1.0.0_0.conda', 'mojo-p-1.0.0-mojo1.2.0_0.conda']);
    expect(linux['mojo-p-1.0.0-mojo1.0.0_0.conda']).toMatchObject({ build: 'mojo1.0.0_0', depends: ['lz4-c >=1.9.3', 'mojo-compiler ==1.0.0', 'mojo-q >=1'] });
    expect(linux['mojo-p-1.0.0-mojo1.2.0_0.conda']).toMatchObject({ build: 'mojo1.2.0_0', depends: ['lz4-c >=1.9.3', 'mojo-compiler ==1.2.0', 'mojo-q >=1'] });
    expect(entries('osx-arm64', rows())['packages.conda']['mojo-p-1.0.0-mojo1.2.0_0.conda']).toMatchObject({ build: 'mojo1.2.0_0', depends: ['lz4-c >=1.9.3', 'mojo-compiler ==1.2.0', 'mojo-q >=1'] });
  });

  test('every entry has the same name, version and keys as before', () => {
    for (const e of Object.values<Record<string, unknown>>(entries('linux-64', rows())['packages.conda'])) {
      expect(Object.keys(e)).toEqual(['build', 'build_number', 'depends', 'name', 'sha256', 'size', 'subdir', 'version']);
      expect(e).toMatchObject({ name: 'mojo-p', version: '1.0.0', build_number: 0, subdir: 'linux-64' });
    }
  });

  test('a yanked version lists the files of every build under removed', () => {
    const doc = entries('linux-64', rows({ state: 'yanked', yank_reason: 'broken' }));
    expect(doc['packages.conda']).toEqual({});
    expect(doc.removed).toEqual(['mojo-p-1.0.0-mojo1.0.0_0.conda', 'mojo-p-1.0.0-mojo1.2.0_0.conda']);
  });

  test('the output does not depend on the order of the files of the row', () => {
    const [r] = rows();
    expect(buildRepodataJson('linux-64', [{ ...r!, files: [...r!.files].reverse() }])).toBe(buildRepodataJson('linux-64', [r!]));
  });
});

describe('repodata of a version with one build', () => {
  test('a file whose name names no build is listed under the row\'s build and requires_mojo, as before', () => {
    const odd = { ...buildFile('p', '1.0.0', 'mojo1.0.0_0'), filename: 'whatever.conda' };
    const doc = entries('linux-64', [rec({ name: 'p', version: '1.0.0', build: 'mojo1.0.0_0', requires_mojo: '>=1.0,<2', files: [odd] })]);
    expect(doc['packages.conda']['whatever.conda']).toMatchObject({ build: 'mojo1.0.0_0', depends: ['mojo-compiler >=1.0,<2'] });
  });

  test('the row\'s own requires_mojo is what its build states, so a row\'s depends are what the row says', () => {
    const doc = entries('linux-64', [rec({ name: 'p', version: '1.0.0', requires_mojo: '==1.0.0' })]);
    expect(doc['packages.conda']['mojo-p-1.0.0-mojo1.0.0_0.conda'].depends).toEqual(['mojo-compiler ==1.0.0']);
  });
});
