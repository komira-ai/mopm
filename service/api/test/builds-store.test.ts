import { buildsOf, primaryBuild } from '../src/builds';
import { API_ROWS_VIEW, API_VIEW, INDEX_VIEW, repodataView } from '../src/group';
import type { VersionRecord } from '../src/types';
import { audit, buildFile, buildRow, rec } from './helpers';
import { COMMITTED_AT, header, RIGS, seedGroup, type Rig } from './group-rig';

/**
 * A build added to a published version is a row of its own, keyed `<version>+<build>`. These tests run on both store
 * adapters (memory, and the DynamoDB adapter over its fake client) and assert what a reader of the store sees.
 */
describe.each(RIGS)('builds as rows: %s', (_label, make) => {
  let r: Rig;
  let s: Rig['store'];
  beforeEach(() => {
    r = make();
    s = r.store;
  });

  const version = (over: Partial<VersionRecord> = {}) => rec({ name: 'p', version: '1.0.0', rev: 2, ...over });
  const create = (row: VersionRecord) => s.createVersion(row, audit('p', 'publish', row.version));
  const filenames = (v: VersionRecord) => v.files.map((f) => f.filename);

  test('a build row is created under its own key, and read back by that key as the one stored row, not folded', async () => {
    await create(version());
    await create(buildRow('p', '1.0.0', 'mojo1.1.0_0'));
    const row = (await s.getVersion('p', '1.0.0+mojo1.1.0_0'))!;
    expect(row).toMatchObject({ canonical: '1.0.0+mojo1.1.0_0', version: '1.0.0', build: 'mojo1.1.0_0', requires_mojo: '==1.1.0', rev: 1 });
    expect(filenames(row)).toEqual(['mojo-p-1.0.0-mojo1.1.0_0.conda']);
    // The version's own row, by its own key, still holds only what it was published with.
    const own = (await s.getVersion('p', '1.0.0'))!;
    expect(own).toMatchObject({ canonical: '1.0.0', build: 'mojo1.0.0_0', rev: 2 });
    expect(filenames(own)).toEqual(['mojo-p-1.0.0-mojo1.0.0_0.conda']);
    expect(await s.getVersion('p', '1.0.0+mojo1.2.0_0')).toBeUndefined();
  });

  test('listVersions folds the added build into its version: one record, the files of both builds, the revisions summed', async () => {
    await create(version());
    await create(buildRow('p', '1.0.0', 'mojo1.1.0_0'));
    const listed = await s.listVersions('p');
    expect(listed).toHaveLength(1);
    expect(listed[0]).toMatchObject({ canonical: '1.0.0', build: 'mojo1.0.0_0', requires_mojo: '==1.0.0', state: 'published', rev: 3 });
    expect(buildsOf(listed[0]!).map((b) => b.build)).toEqual(['mojo1.0.0_0', 'mojo1.1.0_0']);
  });

  test('versionsOf folds for the api, build and index views, and shows the stored rows for the rows view', async () => {
    await create(version());
    await create(buildRow('p', '1.0.0', 'mojo1.1.0_0'));
    for (const view of [API_VIEW, INDEX_VIEW, repodataView('linux-64')]) {
      const got = (await s.versionsOf(['p'], view)).get('p')!;
      expect(got.map((x) => [x.canonical, x.files.length])).toEqual([['1.0.0', 2]]);
    }
    const rows = (await s.versionsOf(['p'], API_ROWS_VIEW)).get('p')!;
    expect(rows.map((x) => [x.canonical, x.build, x.files.length]).sort((a, b) => (a[0]! < b[0]! ? -1 : 1))).toEqual([
      ['1.0.0', 'mojo1.0.0_0', 1],
      ['1.0.0+mojo1.1.0_0', 'mojo1.1.0_0', 1],
    ]);
  });

  test('a second create of the same build row is version_exists, names the build and the first file\'s sha256, and writes nothing', async () => {
    await create(version());
    await create(buildRow('p', '1.0.0', 'mojo1.1.0_0'));
    await expect(create(buildRow('p', '1.0.0', 'mojo1.1.0_0', { files: [buildFile('p', '1.0.0', 'mojo1.1.0_0', 'osx-arm64', 'c')] }))).rejects.toMatchObject({
      code: 'version_exists',
      status: 409,
      message: `'p' 1.0.0 (build mojo1.1.0_0) already exists (sha256 ${'b'.repeat(64)}); versions are immutable.`,
      detail: { name: 'p', version: '1.0.0 (build mojo1.1.0_0)', sha256: 'b'.repeat(64) },
    });
    expect(await r.store.listAudit('p')).toHaveLength(2);
    expect(filenames((await s.getVersion('p', '1.0.0+mojo1.1.0_0'))!)).toEqual(['mojo-p-1.0.0-mojo1.1.0_0.conda']);
    // Another build of the version is a different row and is created.
    await create(buildRow('p', '1.0.0', 'mojo1.2.0_0'));
    expect(buildsOf((await s.listVersions('p'))[0]!).map((b) => b.build)).toEqual(['mojo1.0.0_0', 'mojo1.1.0_0', 'mojo1.2.0_0']);
  });

  test('two concurrent creates of one build of a version: exactly one wins', async () => {
    await create(version());
    const results = await Promise.allSettled([create(buildRow('p', '1.0.0', 'mojo1.1.0_0')), create(buildRow('p', '1.0.0', 'mojo1.1.0_0', { files: [buildFile('p', '1.0.0', 'mojo1.1.0_0', 'osx-arm64', 'c')] }))]);
    expect(results.filter((x) => x.status === 'fulfilled')).toHaveLength(1);
    expect(results.filter((x) => x.status === 'rejected')).toHaveLength(1);
  });

  test('a key that is not a version or a build row\'s key is invalid_version, on every way in', async () => {
    for (const bad of ['1.0.0+nope', '1.0.0+', '1.0+mojo1.1.0_0', '+mojo1.1.0_0']) {
      await expect(s.getVersion('p', bad)).rejects.toMatchObject({ code: 'invalid_version' });
      await expect(s.updateVersion('p', bad, { type: 'publish' }, audit('p', 'x'))).rejects.toMatchObject({ code: 'invalid_version' });
      await expect(r.store.raw.rawGet('p', bad)).rejects.toMatchObject({ code: 'invalid_version' });
    }
    await expect(create(buildRow('p', '1.0.0', 'mojo1.1.0_0', { canonical: '1.0.0+nope' }))).rejects.toMatchObject({ code: 'invalid_version' });
    await expect(create(buildRow('p', '1.0.0', 'mojo1.1.0_0', { canonical: '1.0.1+mojo1.1.0_0' }))).rejects.toMatchObject({ code: 'invalid_version' });
    expect(await s.listVersions('p')).toEqual([]);
    expect(await s.listAudit('p')).toEqual([]);
  });

  test('a build row can be adopted like a reservation: created where there is none, taken over when free, left when not', async () => {
    const pending = (over: Partial<VersionRecord> = {}) => buildRow('p', '1.0.0', 'mojo1.1.0_0', { state: 'pending', files: [], rev: 0, ...over });
    const a = () => audit('p', 'publish_adopt', '1.0.0');
    expect((await s.adoptSingle(pending(), a(), () => true)).outcome).toBe('created');
    expect(await r.store.raw.rawGet('p', '1.0.0+mojo1.1.0_0')).toMatchObject({ canonical: '1.0.0+mojo1.1.0_0', state: 'pending', rev: 0 });
    expect(await r.store.raw.rawGet('p', '1.0.0')).toBeUndefined();

    expect((await s.adoptSingle(pending({ published_by: 'octocat' }), a(), () => false)).outcome).toBe('taken');
    const adopted = await s.adoptSingle(pending({ published_by: 'octocat' }), a(), () => true);
    expect(adopted).toMatchObject({ outcome: 'adopted', record: { canonical: '1.0.0+mojo1.1.0_0', rev: 1, published_by: 'octocat' } });
    // Adoption is of a build row only: the version's own row is not touched.
    expect(await r.store.raw.rawGet('p', '1.0.0')).toBeUndefined();
  });

  test('a build row follows the state machine by its own key, and shows in its version once it is published', async () => {
    await create(version());
    await create(buildRow('p', '1.0.0', 'mojo1.1.0_0', { state: 'pending', files: [], rev: 0 }));
    expect((await s.listVersions('p'))[0]!.files).toHaveLength(1);
    const next = await s.updateVersion('p', '1.0.0+mojo1.1.0_0', { type: 'publish', fill: { version: '1.0.0', build: 'mojo1.1.0_0', requires_mojo: '==1.1.0', files: [buildFile('p', '1.0.0', 'mojo1.1.0_0')] } as never }, audit('p', 'publish'));
    expect(next).toMatchObject({ canonical: '1.0.0+mojo1.1.0_0', state: 'published', rev: 1 });
    const [folded] = await s.listVersions('p');
    expect(folded!.files).toHaveLength(2);
    expect(folded!.rev).toBe(3);
    await expect(s.updateVersion('p', '1.0.0+mojo1.2.0_0', { type: 'publish' }, audit('p', 'publish'))).rejects.toMatchObject({ code: 'version_not_found' });
  });

  test('a build row burned by a rejected add (tombstoned) is not folded, and its version is untouched', async () => {
    await create(version());
    await create(buildRow('p', '1.0.0', 'mojo1.1.0_0', { state: 'tombstoned', files: [], tombstone: { reason_code: 'rejected', date: '2026-11-12' } }));
    const [v] = await s.listVersions('p');
    expect(v).toMatchObject({ canonical: '1.0.0', rev: 2 });
    expect(v!.files).toHaveLength(1);
    await expect(create(buildRow('p', '1.0.0', 'mojo1.1.0_0'))).rejects.toMatchObject({ code: 'version_exists' });
  });

  test('yanking and taking down the version act on the whole version: the added build goes with it, and loses its url when taken down', async () => {
    await create(version());
    await create(buildRow('p', '1.0.0', 'mojo1.1.0_0'));
    await s.updateVersion('p', '1.0.0', { type: 'yank', reason: 'broken' }, audit('p', 'yank', '1.0.0'));
    const [yanked] = await s.listVersions('p');
    expect(yanked).toMatchObject({ state: 'yanked', yank_reason: 'broken' });
    expect(yanked!.files.map((f) => f.url !== undefined)).toEqual([true, true]);
    // The added build row itself is untouched: a version's state is the version row's.
    expect(await s.getVersion('p', '1.0.0+mojo1.1.0_0')).toMatchObject({ state: 'published', rev: 1 });

    await s.updateVersion('p', '1.0.0', { type: 'tombstone', reason_code: 'malware', date: '2026-11-12' }, audit('p', 'takedown', '1.0.0'));
    const [gone] = await s.listVersions('p');
    expect(gone).toMatchObject({ state: 'tombstoned' });
    expect(gone!.files.map((f) => f.filename)).toEqual(['mojo-p-1.0.0-mojo1.0.0_0.conda', 'mojo-p-1.0.0-mojo1.1.0_0.conda']);
    expect(gone!.files[1]).not.toHaveProperty('url');
  });

  test('a build added with a lower compiler becomes the primary build of the listed version', async () => {
    await create(version({ build: 'mojo1.2.0_0', requires_mojo: '==1.2.0', files: [buildFile('p', '1.0.0', 'mojo1.2.0_0')] }));
    await create(buildRow('p', '1.0.0', 'mojo1.0.0_0'));
    const [v] = await s.listVersions('p');
    expect(v).toMatchObject({ build: 'mojo1.0.0_0', requires_mojo: '==1.0.0' });
    expect(primaryBuild(v!)!.files.map((f) => f.filename)).toEqual(['mojo-p-1.0.0-mojo1.0.0_0.conda']);
  });

  test('a build row of a version in a group is projected first, then folded: it joins its version when its group commits', async () => {
    const own = version({ group_id: 'g1', staged_attempt: 1, state: 'pending', rev: 1 });
    const add = buildRow('p', '1.0.0', 'mojo1.1.0_0', { group_id: 'g1', staged_attempt: 1, state: 'pending', rev: 1 });
    seedGroup(r, 'g1', { status: 'validating', attempt: 1 }, [['p', '1.0.0'], ['p', '1.0.0+mojo1.1.0_0']], [own, add]);
    expect(await s.listVersions('p')).toEqual([{ ...own }]);

    seedGroup(r, 'g1', header(), [['p', '1.0.0'], ['p', '1.0.0+mojo1.1.0_0']], []);
    const [v] = await s.listVersions('p');
    expect(v).toMatchObject({ state: 'published', published_at: COMMITTED_AT, rev: 2 });
    expect(buildsOf(v!).map((b) => b.build)).toEqual(['mojo1.0.0_0', 'mojo1.1.0_0']);
  });

  test('deleting the rows of a name by key removes a build row without touching its version', async () => {
    await create(version());
    await create(buildRow('p', '1.0.0', 'mojo1.1.0_0'));
    await s.deleteVersionRow('p', '1.0.0+mojo1.1.0_0');
    expect(await s.getVersion('p', '1.0.0+mojo1.1.0_0')).toBeUndefined();
    expect((await s.listVersions('p'))[0]!.files).toHaveLength(1);
  });
});
