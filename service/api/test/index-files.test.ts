import fc from 'fast-check';
import { readFileSync } from 'fs';
import { join } from 'path';
import { buildIndexConfig, buildPackageIndex, buildTakedowns, indexKey, type IndexStage } from '../src/index-files';
import { buildRepodataJson } from '../src/repodata';
import { applyEvent } from '../src/state';
import { SUBDIRS_V1, type VersionRecord } from '../src/types';
import { ALL_FIXTURE_ROWS, CHANNEL, FIXTURE_PACKAGES, rows } from './fixtures/index-registry';
import { hex, rec } from './helpers';
import { validate } from './json-schema';

const spec = (f: string) => JSON.parse(readFileSync(join(__dirname, '../../../spec', f), 'utf8'));
const RECORD = spec('index-record.schema.json');
const CONFIG = spec('index-config.schema.json');
const TAKEDOWNS = spec('takedowns.schema.json');

const lines = (text: string | undefined): any[] => (text ?? '').split('\n').slice(0, -1).map((l) => JSON.parse(l));
const build = (name: string, rs: readonly VersionRecord[] = FIXTURE_PACKAGES[name]!) => buildPackageIndex(name, rs)!;
const only = (name: string, version: string) => FIXTURE_PACKAGES[name]!.find((r) => r.version === version)!;
const replaced = (name: string, next: VersionRecord) => FIXTURE_PACKAGES[name]!.map((r) => (r.version === next.version ? next : r));

describe('the schema checker used below', () => {
  // These show that a failing schema check is possible, so the passing checks mean something.
  const good = lines(build('http_client'))[1];
  test('accepts a good record', () => expect(validate(RECORD, good)).toEqual([]));
  test.each([
    ['a yank without a reason', { ...good, state: 'yanked' }],
    ['a tombstone without its object', { ...good, state: 'tombstoned' }],
    ['a published file without a url', { ...good, files: [{ ...good.files[0], url: undefined }] }],
    ['a sha256 in upper case', { ...good, files: [{ ...good.files[0], sha256: 'A'.repeat(64) }] }],
    ['a zero size', { ...good, files: [{ ...good.files[0], size: 0 }] }],
    ['no files', { ...good, files: [] }],
    ['an unknown subdir', { ...good, files: [{ ...good.files[0], subdir: 'win-64' }] }],
    ['v 2', { ...good, v: 2 }],
    ['a pre-release version', { ...good, version: '1.0.0-rc1' }],
  ])('refuses %s', (_, bad) => expect(validate(RECORD, JSON.parse(JSON.stringify(bad))).length).toBeGreaterThan(0));
});

describe('package file against spec/index-record.schema.json', () => {
  test.each(Object.keys(FIXTURE_PACKAGES))('every line of %s is a valid record', (name) => {
    const recs = lines(build(name));
    expect(recs.length).toBeGreaterThan(0);
    for (const r of recs) expect(validate(RECORD, r)).toEqual([]);
  });

  test('a record with every optional part (yank reason, oidc provenance, native, dep without range) is valid', () => {
    const r = rec({
      name: 'full',
      version: '1.0.0',
      state: 'yanked',
      yank_reason: 'no',
      native: [{ id: 'openssl', soname: 'libssl.so.3' }],
      deps: [{ name: 'a_dep' }, { name: 'b_dep', range: '>=1' }],
      provenance: { kind: 'oidc', repository: 'owner/repo', workflow_ref: 'owner/repo/.github/workflows/r.yml@refs/heads/main' },
    });
    const [line] = lines(buildPackageIndex('full', [r]));
    expect(validate(RECORD, line)).toEqual([]);
    expect(line.provenance).toEqual(r.provenance);
    expect(line.deps).toEqual([{ name: 'a_dep' }, { name: 'b_dep', range: '>=1' }]);
  });

  test('the record fields come from the row: requires_mojo, build, deps ranges, manifest digest, filename', () => {
    const l = lines(build('http_client'));
    const v041 = l.find((x) => x.version === '0.4.1');
    expect(v041.requires_mojo).toBe('==1.1.0');
    expect(v041.build).toBe('mojo1.1.0_0');
    expect(v041.deps).toEqual([
      { name: 'http_core', range: '>=1.2,<2' },
      { name: 'crypto', range: '2' },
    ]);
    expect(v041.files[0].filename).toBe('mojo-http_client-0.4.1-mojo1.1.0_0.conda');
    expect(v041.manifest_sha256).toBe(only('http_client', '0.4.1').manifest_sha256);
  });

  test('a row without provenance is served as kind none', () => {
    expect(lines(build('tls'))[1].provenance).toEqual({ kind: 'none' });
  });
});

describe('takedowns against spec/takedowns.schema.json', () => {
  test('the fixture registry log is valid and lists both tombstoned tls versions', () => {
    const doc = JSON.parse(buildTakedowns(ALL_FIXTURE_ROWS));
    expect(validate(TAKEDOWNS, doc)).toEqual([]);
    expect(doc.takedowns.map((t: any) => `${t.name} ${t.version}`)).toEqual(['tls 1.0.0', 'tls 1.2.0']);
    expect(doc.takedowns[0].sha256).toEqual([only('tls', '1.0.0').files[0]!.sha256]);
  });
  test('the empty log is valid', () => expect(validate(TAKEDOWNS, JSON.parse(buildTakedowns([])))).toEqual([]));
});

describe('config against spec/index-config.schema.json', () => {
  const cases: [IndexStage, string, string][] = [
    ['beta', 'api.beta.mopm.dev', 'conda.beta.mopm.dev'],
    ['gamma', 'api.gamma.mopm.dev', 'conda.gamma.mopm.dev'],
    ['prod', 'api.mopm.dev', 'conda.mopm.dev'],
  ];
  test.each(cases)('%s config is valid', (stage, apiDomain, channelDomain) => {
    for (const readOnly of [false, true]) {
      expect(validate(CONFIG, JSON.parse(buildIndexConfig({ stage, apiDomain, channelDomain, readOnly })))).toEqual([]);
    }
  });
  test.each([
    ['an api_url without /api/v1', { api_url: 'https://api.mopm.dev' }],
    ['a channel_url without the trailing slash', { channel_url: 'https://conda.mopm.dev' }],
    ['plain http on a real host', { api_url: 'http://api.mopm.dev/api/v1' }],
    ['an unknown stage', { stage: 'dev' }],
    ['a non-boolean read_only', { read_only: 'no' }],
  ])('the checker refuses %s', (_, patch) => {
    const good = JSON.parse(buildIndexConfig({ stage: 'prod', apiDomain: 'api.mopm.dev', channelDomain: 'conda.mopm.dev', readOnly: false }));
    expect(validate(CONFIG, { ...good, ...patch }).length).toBeGreaterThan(0);
  });
});

describe('config values', () => {
  test('exact bytes for a stage', () => {
    expect(buildIndexConfig({ stage: 'beta', apiDomain: 'api.beta.mopm.dev', channelDomain: 'conda.beta.mopm.dev', readOnly: false })).toBe(
      '{"api_url":"https://api.beta.mopm.dev/api/v1","channel_url":"https://conda.beta.mopm.dev/","index_version":1,"min_cli_version":"0.0.1","read_only":false,"stage":"beta"}\n',
    );
  });
  test('read_only follows the input', () => {
    const c = (readOnly: boolean) => JSON.parse(buildIndexConfig({ stage: 'prod', apiDomain: 'api.mopm.dev', channelDomain: 'conda.mopm.dev', readOnly }));
    expect(c(true).read_only).toBe(true);
    expect(c(false).read_only).toBe(false);
  });
  test('refuses an unknown stage', () => {
    expect(() => buildIndexConfig({ stage: 'dev' as IndexStage, apiDomain: 'api.mopm.dev', channelDomain: 'conda.mopm.dev', readOnly: false })).toThrow(/unknown stage/);
  });
  test.each(['https://api.mopm.dev', 'api.mopm.dev/', 'API.mopm.dev', 'api.mopm.dev:443', '', 'localhost', 'a b.dev'])('refuses the host %j', (h) => {
    expect(() => buildIndexConfig({ stage: 'prod', apiDomain: h, channelDomain: 'conda.mopm.dev', readOnly: false })).toThrow(/bare host/);
  });
});

describe('channel host of the config', () => {
  test.each(['mopm.dev', 'api.mopm.dev', 'channel.mopm.dev'])('refuses the channel host %j without the conda. prefix', (h) => {
    expect(() => buildIndexConfig({ stage: 'prod', apiDomain: 'api.mopm.dev', channelDomain: h, readOnly: false })).toThrow(/must start with 'conda\.'/);
  });
});

describe('path of a package', () => {
  test.each([
    ['http_client', 'index/ht/tp/http_client'],
    ['tls', 'index/tl/s_/tls'],
    ['ab', 'index/ab/__/ab'],
    ['abcd', 'index/ab/cd/abcd'],
    ['a1_', 'index/a1/__/a1_'],
  ])('%s is stored at %s', (name, key) => expect(indexKey(name)).toBe(key));
  test.each(['', 'a', 'Tls', '../x', 'a/b', 'tls/', '1abc', 'a'.repeat(65), 'tl%2e'])('refuses the name %j', (n) => {
    expect(() => indexKey(n)).toThrow(/not a package name/);
  });
});

describe('versions and states on the right line', () => {
  test('lines are oldest first by numeric version, not text order', () => {
    const rs = rows('numeric', [{ ver: '1.10.0' }, { ver: '1.9.0' }, { ver: '1.2.0' }, { ver: '0.20.1' }]);
    expect(lines(buildPackageIndex('numeric', rs)).map((l) => l.version)).toEqual(['0.20.1', '1.2.0', '1.9.0', '1.10.0']);
  });

  test('a yank changes only the yanked version line, and adds its reason', () => {
    const before = build('http_core').split('\n');
    const yanked = applyEvent(only('http_core', '1.4.0'), { type: 'yank', reason: 'bad release' });
    const after = build('http_core', replaced('http_core', yanked)).split('\n');
    const changed = before.map((l, i) => (l === after[i] ? -1 : i)).filter((i) => i >= 0);
    expect(changed).toEqual([3]);
    const line = JSON.parse(after[3]!);
    expect(line.version).toBe('1.4.0');
    expect(line.state).toBe('yanked');
    expect(line.yank_reason).toBe('bad release');
    expect(validate(RECORD, line)).toEqual([]);
  });

  test('an unyank restores the exact bytes, with no yank_reason left behind', () => {
    const original = build('http_core');
    const yanked = applyEvent(only('http_core', '1.4.0'), { type: 'yank', reason: 'bad release' });
    const back = applyEvent(yanked, { type: 'unyank' });
    const text = build('http_core', replaced('http_core', back));
    expect(text).toBe(original);
    expect(text).not.toContain('bad release');
  });

  test('a tombstone of a published version shows as tombstoned, keeps the sha256 and drops the url', () => {
    const before = only('http_core', '1.4.0');
    const gone = applyEvent(before, { type: 'tombstone', reason_code: 'malware', date: '2026-10-14' });
    const text = build('http_core', replaced('http_core', gone));
    const l = lines(text);
    expect(l).toHaveLength(5);
    expect(l[3].state).toBe('tombstoned');
    expect(l[3].tombstone).toEqual({ reason_code: 'malware', date: '2026-10-14' });
    expect(l[3].files[0].sha256).toBe(before.files[0]!.sha256);
    expect('url' in l[3].files[0]).toBe(false);
    expect(validate(RECORD, l[3])).toEqual([]);
    expect(text.split('\n').filter((_, i) => i !== 3)).toEqual(build('http_core').split('\n').filter((_, i) => i !== 3));
  });

  test('a tombstone whose row still carries a url is written without it', () => {
    const r = rec({ name: 'tomb', version: '1.0.0', state: 'tombstoned', tombstone: { reason_code: 'legal', date: '2026-10-15' } });
    expect('url' in lines(buildPackageIndex('tomb', [r]))[0].files[0]).toBe(false);
  });

  test('pending versions and rejected publishes (tombstoned, no files) have no line', () => {
    const rejected = applyEvent(rec({ name: 'pk', version: '2.0.0', state: 'pending', files: [] }), {
      type: 'tombstone',
      reason_code: 'rejected',
      date: '2026-10-14',
      unpublished: true,
    });
    const rs = [...rows('pk', [{ ver: '1.0.0' }]), rec({ name: 'pk', version: '1.5.0', state: 'pending', files: [] }), rejected];
    expect(rejected.files).toEqual([]);
    expect(lines(buildPackageIndex('pk', rs)).map((l) => l.version)).toEqual(['1.0.0']);
  });

  test('a package with no visible version has no file at all', () => {
    expect(buildPackageIndex('pk', [])).toBeUndefined();
    expect(buildPackageIndex('pk', [rec({ name: 'pk', version: '1.0.0', state: 'pending', files: [] })])).toBeUndefined();
  });

  test('a version with files in two subdirs is one line with both files, ordered by subdir', () => {
    const l = lines(build('crypto'));
    expect(l).toHaveLength(1);
    expect(l[0].files.map((f: any) => f.subdir)).toEqual(['linux-64', 'osx-arm64']);
    expect(l[0].native).toEqual([{ id: 'crypto', soname: 'libcrypto_native.a' }]);
  });
});

describe('agreement with the repodata built from the same rows', () => {
  const repodata = (rs: VersionRecord[]) => Object.fromEntries(SUBDIRS_V1.map((s) => [s, JSON.parse(buildRepodataJson(s, rs))]));

  test.each(Object.keys(FIXTURE_PACKAGES))('%s: sha256 and size equal the repodata entry, url is channel/subdir/filename', (name) => {
    const rd = repodata(FIXTURE_PACKAGES[name]!);
    let checked = 0;
    for (const l of lines(build(name))) {
      for (const f of l.files) {
        if (l.state === 'published') {
          const e = rd[f.subdir]['packages.conda'][f.filename];
          expect(e.sha256).toBe(f.sha256);
          expect(e.size).toBe(f.size);
          expect(e.version).toBe(l.version);
          expect(e.build).toBe(l.build);
          checked++;
        }
        if (l.state !== 'tombstoned') expect(f.url).toBe(`${CHANNEL}/${f.subdir}/${f.filename}`);
      }
    }
    expect(checked).toBeGreaterThan(0);
  });

  test('yanked and tombstoned lines are exactly the files repodata lists under removed', () => {
    const rd = repodata(ALL_FIXTURE_ROWS);
    for (const name of Object.keys(FIXTURE_PACKAGES)) {
      for (const l of lines(build(name))) {
        for (const f of l.files) {
          const removed = rd[f.subdir].removed.includes(f.filename);
          expect(removed).toBe(l.state !== 'published');
        }
      }
    }
    expect(lines(build('tls')).map((l) => l.state)).toEqual(['tombstoned', 'published', 'tombstoned']);
  });
});

describe('exact bytes and determinism', () => {
  const ab = () =>
    rec({
      name: 'ab',
      version: '1.0.0',
      files: [
        {
          subdir: 'noarch',
          filename: 'mojo-ab-1.0.0-mojo1.0.0_0.conda',
          sha256: hex('a'),
          size: 1000,
          url: 'https://conda.example.invalid/noarch/mojo-ab-1.0.0-mojo1.0.0_0.conda',
        },
      ],
    });

  test('one record is written as this exact line', () => {
    expect(buildPackageIndex('ab', [ab()])).toBe(
      `{"build":"mojo1.0.0_0","deps":[],"files":[{"filename":"mojo-ab-1.0.0-mojo1.0.0_0.conda","sha256":"${hex('a')}","size":1000,"subdir":"noarch","url":"https://conda.example.invalid/noarch/mojo-ab-1.0.0-mojo1.0.0_0.conda"}],"manifest_sha256":"${hex('f')}","name":"ab","native":[],"provenance":{"kind":"none"},"published_at":"2026-10-13T12:00:00Z","requires_mojo":"==1.0.0","state":"published","v":1,"version":"1.0.0"}\n`,
    );
  });

  test('the empty takedown log is this exact line', () => expect(buildTakedowns([])).toBe('{"index_version":1,"takedowns":[]}\n'));

  test('the file ends in one newline, has no blank line, and every line has sorted keys', () => {
    for (const name of Object.keys(FIXTURE_PACKAGES)) {
      const text = build(name);
      expect(text.endsWith('\n')).toBe(true);
      expect(text.endsWith('\n\n')).toBe(false);
      for (const raw of text.split('\n').slice(0, -1)) {
        expect(raw).not.toBe('');
        const keys = Object.keys(JSON.parse(raw));
        expect(keys).toEqual([...keys].sort());
      }
    }
  });

  test('the input order of the rows does not change a byte', () => {
    for (const name of Object.keys(FIXTURE_PACKAGES)) {
      const rs = FIXTURE_PACKAGES[name]!;
      expect(buildPackageIndex(name, [...rs].reverse())).toBe(build(name));
    }
  });

  test('any permutation of the rows gives the same bytes (property)', () => {
    const rs = FIXTURE_PACKAGES.http_core!;
    const expected = build('http_core');
    fc.assert(
      fc.property(fc.shuffledSubarray(rs, { minLength: rs.length, maxLength: rs.length }), (p) => buildPackageIndex('http_core', p) === expected),
      { numRuns: 50 },
    );
  });

  test('the same rows twice give the same bytes, and the takedown log ignores row order', () => {
    expect(build('tls')).toBe(build('tls'));
    expect(buildTakedowns([...ALL_FIXTURE_ROWS].reverse())).toBe(buildTakedowns(ALL_FIXTURE_ROWS));
  });
});

describe('a stale writer cannot regress a file', () => {
  // The file is a whole rewrite from the rows, so what a writer produced earlier has no say: the bytes of the
  // newest rows are the bytes, whichever writer ran last on them. (Ordering of the jobs themselves is the queue's.)
  const v1 = FIXTURE_PACKAGES.http_core!;
  const v2 = replaced('http_core', applyEvent(only('http_core', '1.4.0'), { type: 'yank', reason: 'late' }));
  test('building from old rows after new rows, then from new rows again, ends at the new bytes', () => {
    const newest = build('http_core', v2);
    build('http_core', v1);
    expect(build('http_core', v2)).toBe(newest);
    expect(newest).not.toBe(build('http_core', v1));
  });
  test('the bytes do not depend on the rows revision counter', () => {
    const bumped = v1.map((r) => ({ ...r, rev: r.rev + 7 }));
    expect(build('http_core', bumped)).toBe(build('http_core', v1));
  });
});

describe('takedown log content', () => {
  const t = (name: string, version: string, date: string, shas = [hex('1')]) =>
    rec({
      name,
      version,
      state: 'tombstoned',
      tombstone: { reason_code: 'abuse', date },
      files: shas.map((s, i) => ({ subdir: i ? 'osx-arm64' : 'linux-64', filename: `mojo-${name}-${version}-mojo1.0.0_0.conda`, sha256: s, size: 5 })),
    });

  test('sorted by date, then name, then numeric version', () => {
    const rs = [t('zz', '1.0.0', '2026-10-01'), t('bb', '1.10.0', '2026-10-02'), t('bb', '1.9.0', '2026-10-02'), t('aa', '3.0.0', '2026-10-02'), t('cc', '1.0.0', '2026-09-30')];
    const got = JSON.parse(buildTakedowns(rs)).takedowns.map((x: any) => `${x.date} ${x.name} ${x.version}`);
    expect(got).toEqual(['2026-09-30 cc 1.0.0', '2026-10-01 zz 1.0.0', '2026-10-02 aa 3.0.0', '2026-10-02 bb 1.9.0', '2026-10-02 bb 1.10.0']);
  });

  test('lists the sha256 of every file of the version', () => {
    const doc = JSON.parse(buildTakedowns([t('multi', '1.0.0', '2026-10-02', [hex('2'), hex('1')])]));
    expect(doc.takedowns[0].sha256).toEqual([hex('2'), hex('1')]);
    expect(validate(TAKEDOWNS, doc)).toEqual([]);
  });

  test('leaves out published, yanked, pending and rejected (no files) versions', () => {
    const rejected = { ...t('rej', '1.0.0', '2026-10-02'), files: [] };
    const rs = [...ALL_FIXTURE_ROWS.filter((r) => r.state !== 'tombstoned'), rejected, rec({ name: 'pen', version: '1.0.0', state: 'pending', files: [] })];
    expect(JSON.parse(buildTakedowns(rs)).takedowns).toEqual([]);
  });
});

describe('rows the builder refuses', () => {
  test('a row of another package', () => {
    expect(() => buildPackageIndex('tls', [rec({ name: 'other', version: '1.0.0' })])).toThrow(/does not belong/);
  });
  test('the same version twice', () => {
    expect(() => buildPackageIndex('pk', [rec({ name: 'pk', version: '1.0.0' }), rec({ name: 'pk', version: '1.0.0' })])).toThrow(/twice/);
  });
  test('a published file with no url', () => {
    const r = rec({ name: 'pk', version: '1.0.0' });
    expect(() => buildPackageIndex('pk', [{ ...r, files: [{ ...r.files[0]!, url: undefined }] }])).toThrow(/no url/);
  });
  test('a yank without a reason, and a tombstone without its object', () => {
    expect(() => buildPackageIndex('pk', [rec({ name: 'pk', version: '1.0.0', state: 'yanked' })])).toThrow(/without a reason/);
    expect(() => buildPackageIndex('pk', [rec({ name: 'pk', version: '1.0.0', state: 'tombstoned' })])).toThrow(/without a tombstone/);
    expect(() => buildTakedowns([rec({ name: 'pk', version: '1.0.0', state: 'tombstoned' })])).toThrow(/without a tombstone/);
  });
  test('a package name that is not a name', () => {
    expect(() => buildPackageIndex('../x', [])).toThrow(/not a package name/);
  });
});
