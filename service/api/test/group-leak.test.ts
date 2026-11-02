import { GroupInvariantError, INDEX_VIEW, repodataView } from '../src/group';
import { RIGS } from './group-rig';
import { allRecords } from '../src/publish/indexer';
import { API_SURFACES, API_VISIBLE, BUILD_SURFACES, differences, RAW_SURFACES, seedLeakFixture, STALE_MEMBER, takedownsOf } from './group-surfaces';

/**
 * The table-driven leak test. One fixture holds a group in every state a reader can meet (group-surfaces.ts says which),
 * and every way to read version rows is a row of the table. What each proves:
 *
 * - API surfaces: a member of a group that has not committed (staged, reserved only, no header, stale stamp) is
 *   shown by no reader, and a member of a committed group is shown by all of them, flipped or not. A reader that
 *   forgot the rule would hide a committed member (it cannot show an uncommitted one), and this table is what
 *   catches that.
 * - Build surfaces: the repodata and the index files list a committed member only when the group's gate for that
 *   file is set.
 * - The raw port is not a reader: the same table run over it reports the committed members as missing. That is what
 *   shows the table can fail.
 *
 * Each row runs over both store adapters, on a fixture of its own.
 */

describe.each(RIGS)('leak table over the %s adapter', (_label, makeRig) => {
  describe.each(Object.entries(API_SURFACES))('API surface: %s', (_name, surface) => {
    test('shows every committed member and plain row, and no member of a group that has not committed', async () => {
      const r = makeRig();
      const names = await seedLeakFixture(r);
      expect(differences(await surface(r, names), API_VISIBLE, names)).toEqual([]);
    });

    test('a committed group whose row carries another attempt than its header is shown by nobody', async () => {
      const r = makeRig();
      const names = await seedLeakFixture(r, { stale: true });
      const got = await surface(r, names);
      expect(got.has(STALE_MEMBER)).toBe(false);
      expect(differences(got, API_VISIBLE, names)).toEqual([]);
    });
  });

  describe.each(Object.entries(BUILD_SURFACES))('build surface: %s', (_name, { expect: want, surface }) => {
    test('lists a committed member only where its gate is set, and nothing of a group that has not committed', async () => {
      const r = makeRig();
      const names = await seedLeakFixture(r);
      expect(differences(await surface(r, names), want, names)).toEqual([]);
    });
  });

  test('the takedown log holds no group member (a group row is never a tombstone with files)', async () => {
    const r = makeRig();
    await seedLeakFixture(r);
    expect(await takedownsOf(r)).toEqual({ index_version: 1, takedowns: [] });
  });

  test('a build over a committed group with a stale row fails, where an API read hides the group', async () => {
    const r = makeRig();
    const names = await seedLeakFixture(r, { stale: true });
    await expect(allRecords(r.store, repodataView('linux-64'))).rejects.toBeInstanceOf(GroupInvariantError);
    await expect(r.store.versionsOf([STALE_MEMBER], INDEX_VIEW)).rejects.toBeInstanceOf(GroupInvariantError);
    expect((await r.store.versionsOf(names, { kind: 'api' })).get(STALE_MEMBER)![0]!.state).toBe('pending');
  });

  describe.each(Object.entries(RAW_SURFACES))('the raw port, %s', (_name, surface) => {
    test('is not a reader: the table reports the committed members as missing', async () => {
      const r = makeRig();
      const names = await seedLeakFixture(r);
      expect(differences(await surface(r, names), API_VISIBLE, names)).toEqual(['c1 is hidden and must be shown', 'c2 is hidden and must be shown']);
    });
  });
});
