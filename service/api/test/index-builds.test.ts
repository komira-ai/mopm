import { readFileSync } from 'fs';
import { join } from 'path';
import { foldBuilds } from '../src/builds';
import { buildPackageIndex, buildTakedowns } from '../src/index-files';
import type { VersionRecord } from '../src/types';
import { buildFile, buildRow, hex, rec } from './helpers';
import { validate } from './json-schema';

const RECORD = JSON.parse(readFileSync(join(__dirname, '../../../spec/index-record.schema.json'), 'utf8'));
const lines = (text: string | undefined): any[] => (text ?? '').split('\n').slice(0, -1).map((l) => JSON.parse(l));

const FULL = 'komira-ai/json';
const FLAT = 'json';

/** A published version of `name` with the build `build` (one file per listed subdir), and the build rows added to it later. */
function version(name: string, over: Partial<VersionRecord> = {}, build = 'mojo1.0.0_0', subdirs: string[] = ['linux-64']): VersionRecord {
  return rec({
    name,
    version: '1.0.0',
    build,
    requires_mojo: `==${build.slice(4, -2)}`,
    files: subdirs.map((s) => buildFile(name, '1.0.0', build, s, 'a')),
    rev: 1,
    ...over,
  });
}

const lineOf = (name: string, rows: VersionRecord[]) => lines(buildPackageIndex(name, foldBuilds(rows)))[0];

describe('a version with one build, in a package of a full name', () => {
  const line = lineOf(FULL, [version(FULL)]);

  test('lists that build in builds, and builds[0] is the top-level trio', () => {
    expect(line.builds).toEqual([{ build: 'mojo1.0.0_0', requires_mojo: '==1.0.0', files: line.files }]);
    expect(line).toMatchObject({ v: 2, build: 'mojo1.0.0_0', requires_mojo: '==1.0.0' });
  });

  test('is a valid record', () => expect(validate(RECORD, line)).toEqual([]));
});

describe('a version with several builds, in a package of a full name', () => {
  const rows = () => [
    version(FULL, { rev: 2 }, 'mojo1.10.0_0', ['linux-64', 'osx-arm64']),
    buildRow(FULL, '1.0.0', 'mojo1.2.0_0', { files: [buildFile(FULL, '1.0.0', 'mojo1.2.0_0', 'osx-arm64', 'c'), buildFile(FULL, '1.0.0', 'mojo1.2.0_0', 'linux-64', 'd')] }),
  ];
  const line = lineOf(FULL, rows());

  test('lists every build sorted by compiler (1.2.0 before 1.10.0), each with its own files sorted by platform', () => {
    expect(line.builds.map((b: any) => [b.build, b.requires_mojo, b.files.map((f: any) => `${f.subdir}:${f.filename}`)])).toEqual([
      ['mojo1.2.0_0', '==1.2.0', ['linux-64:mojo-komira-ai.json-1.0.0-mojo1.2.0_0.conda', 'osx-arm64:mojo-komira-ai.json-1.0.0-mojo1.2.0_0.conda']],
      ['mojo1.10.0_0', '==1.10.0', ['linux-64:mojo-komira-ai.json-1.0.0-mojo1.10.0_0.conda', 'osx-arm64:mojo-komira-ai.json-1.0.0-mojo1.10.0_0.conda']],
    ]);
  });

  test('the top-level build, requires_mojo and files are the primary build\'s: what a reader that predates builds sees is exactly that build', () => {
    expect(line.build).toBe('mojo1.2.0_0');
    expect(line.requires_mojo).toBe('==1.2.0');
    expect(line.files).toEqual(line.builds[0].files);
    expect(line.files.map((f: any) => f.sha256)).toEqual([hex('d'), hex('c')]);
  });

  test('what the builds share is the version\'s: dependencies, manifest, state, time and provenance appear once', () => {
    expect(line).toMatchObject({ version: '1.0.0', state: 'published', manifest_sha256: hex('f'), deps: [], native: [], provenance: { kind: 'none' } });
    expect(Object.keys(line.builds[0]).sort()).toEqual(['build', 'files', 'requires_mojo']);
  });

  test('is a valid record, and the same whatever the order of the rows', () => {
    expect(validate(RECORD, line)).toEqual([]);
    expect(lineOf(FULL, rows().reverse())).toEqual(line);
  });

  test('the file is byte-identical whatever the order of the rows', () => {
    expect(buildPackageIndex(FULL, foldBuilds(rows().reverse()))).toBe(buildPackageIndex(FULL, foldBuilds(rows())));
  });
});

describe('a build added with a lower compiler than the version\'s own', () => {
  test('is the primary build of the line: build, requires_mojo and files switch to it, and builds still list both', () => {
    const line = lineOf(FULL, [version(FULL, {}, 'mojo1.2.0_0'), buildRow(FULL, '1.0.0', 'mojo1.0.0_0')]);
    expect(line.build).toBe('mojo1.0.0_0');
    expect(line.requires_mojo).toBe('==1.0.0');
    expect(line.files.map((f: any) => f.filename)).toEqual(['mojo-komira-ai.json-1.0.0-mojo1.0.0_0.conda']);
    expect(line.builds.map((b: any) => b.build)).toEqual(['mojo1.0.0_0', 'mojo1.2.0_0']);
  });
});

describe('a package of a flat name (index version 1)', () => {
  test('a line has no builds, whatever the builds of the version: it shows the primary build only', () => {
    const line = lineOf(FLAT, [version(FLAT, {}, 'mojo1.2.0_0'), buildRow(FLAT, '1.0.0', 'mojo1.0.0_0')]);
    expect(line).not.toHaveProperty('builds');
    expect(line).toMatchObject({ v: 1, build: 'mojo1.0.0_0', requires_mojo: '==1.0.0' });
    expect(line.files.map((f: any) => f.filename)).toEqual(['mojo-json-1.0.0-mojo1.0.0_0.conda']);
  });

  test('a line of a version with one build is the keys it always had', () => {
    expect(Object.keys(lineOf(FLAT, [version(FLAT)])).sort()).toEqual(['build', 'deps', 'files', 'manifest_sha256', 'name', 'native', 'provenance', 'published_at', 'requires_mojo', 'state', 'v', 'version']);
  });
});

describe('a taken-down version with several builds', () => {
  const tombstone = { reason_code: 'malware', date: '2026-11-12' };
  const rows = () => [
    version(FULL, { state: 'tombstoned', tombstone, rev: 2 }),
    buildRow(FULL, '1.0.0', 'mojo1.1.0_0', { files: [buildFile(FULL, '1.0.0', 'mojo1.1.0_0', 'linux-64', 'c'), buildFile(FULL, '1.0.0', 'mojo1.1.0_0', 'osx-arm64', 'd')] }),
  ];

  test('no file of any build has a url, and the line is a valid record', () => {
    const line = lineOf(FULL, rows());
    expect(line.state).toBe('tombstoned');
    expect(line.builds.flatMap((b: any) => b.files).every((f: any) => !('url' in f))).toBe(true);
    expect(line.files.every((f: any) => !('url' in f))).toBe(true);
    expect(validate(RECORD, line)).toEqual([]);
  });

  test('the takedown log lists the sha256 of every file of every build', () => {
    const log = JSON.parse(buildTakedowns(foldBuilds(rows()), 2));
    expect(log.takedowns).toHaveLength(1);
    expect(log.takedowns[0]).toMatchObject({ name: FULL, version: '1.0.0', reason_code: 'malware', date: '2026-11-12' });
    expect([...log.takedowns[0].sha256].sort()).toEqual([hex('a'), hex('c'), hex('d')].sort());
  });
});

describe('the schema of builds', () => {
  const good = () => JSON.parse(JSON.stringify(lineOf(FULL, [version(FULL), buildRow(FULL, '1.0.0', 'mojo1.1.0_0')])));

  test('accepts a record with two builds, and one without builds', () => {
    expect(validate(RECORD, good())).toEqual([]);
    const { builds: _b, ...without } = good();
    expect(validate(RECORD, without)).toEqual([]);
  });

  test.each([
    ['no builds in the array', (r: any) => void (r.builds = [])],
    ['a build without files', (r: any) => void delete r.builds[1].files],
    ['a build with no file', (r: any) => void (r.builds[1].files = [])],
    ['a build without requires_mojo', (r: any) => void delete r.builds[1].requires_mojo],
    ['an empty requires_mojo', (r: any) => void (r.builds[1].requires_mojo = '')],
    ['a build string that is not mojo<compiler>_0', (r: any) => void (r.builds[1].build = 'mojo1.1.0')],
    ['a build file without sha256', (r: any) => void delete r.builds[1].files[0].sha256],
    ['a build file of another namespace\'s conda name', (r: any) => void (r.builds[1].files[0].filename = 'mojo-json-1.0.0-mojo1.1.0_0.conda')],
    ['a published build file without a url', (r: any) => void delete r.builds[1].files[0].url],
  ])('refuses %s', (_name, damage) => {
    const r = good();
    damage(r);
    expect(validate(RECORD, r).length).toBeGreaterThan(0);
  });
});
