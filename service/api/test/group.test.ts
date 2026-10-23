import { API_VIEW, GroupInvariantError, INDEX_VIEW, TAKEDOWNS_VIEW, headerKey, membersKey, parseHeader, parseMembers, project, repodataView, type View } from '../src/group';
import { allRecords } from '../src/publish/indexer';
import { consoleSink, emf, Metrics, METRICS_NAMESPACE } from '../src/metrics';
import type { VersionRecord } from '../src/types';
import { audit, rec } from './helpers';
import { COMMITTED_AT, flipped, header, memberList, RIGS, reserved, seedGroup, staged, type Rig } from './group-rig';

const states = (rows: VersionRecord[]) => rows.map((r) => r.state);
const stateMap = (m: Map<string, VersionRecord[]>) => Object.fromEntries([...m].map(([k, v]) => [k, states(v)]));
const open = { status: 'validating', attempt: 1 };

describe('project: what one row shows', () => {
  const committed = parseHeader(header());

  test('a row with no group is returned as it is', () => {
    const r = rec({ name: 'p', version: '1.0.0' });
    expect(project(r, committed)).toBe(r);
    const pending = rec({ name: 'p', version: '1.0.0', state: 'pending' });
    expect(project(pending, committed)).toBe(pending);
  });

  test.each(['published', 'yanked', 'tombstoned'] as const)('a %s row ignores its group, whatever the header says', (state) => {
    const r = rec({ name: 'p', version: '1.0.0', state, group_id: 'g1', staged_attempt: 9, ...(state === 'yanked' ? { yank_reason: 'x' } : {}) });
    expect(project(r, undefined)).toBe(r);
    expect(project(r, parseHeader(open))).toBe(r);
    expect(project(r, committed)).toBe(r);
  });

  test('a pending member stays pending without a header, without committed_at, and with another attempt than the header\'s', () => {
    const r = staged('p', 'g1', 1);
    expect(project(r, undefined)).toBe(r);
    expect(project(r, parseHeader(open))).toBe(r);
    expect(project(r, parseHeader(header({ attempt: 2 })))).toBe(r);
    const unstamped = reserved('p', 'g1');
    expect(project(unstamped, committed)).toBe(unstamped);
  });

  test('a pending member of a committed group at its attempt is published at the commit time, rev unchanged, fields kept, input untouched', () => {
    const r = staged('p', 'g1', 1, { rev: 4 });
    const before = structuredClone(r);
    const shown = project(r, committed);
    expect(shown).toEqual({ ...before, state: 'published', published_at: COMMITTED_AT });
    expect(shown.rev).toBe(4);
    expect(r).toEqual(before);
  });

  test('the build view of repodata waits for the subdir to be released', () => {
    const r = staged('p', 'g1');
    const h = parseHeader(header({ repodata_released: ['noarch'] }));
    expect(project(r, h, repodataView('linux-64'))).toBe(r);
    expect(project(r, h, repodataView('noarch')).state).toBe('published');
    expect(project(r, parseHeader(header()), repodataView('noarch'))).toBe(r);
  });

  test('the build view of the package index waits for the member\'s position in write_order to be released', () => {
    const members = parseMembers(memberList('a', 'b', 'c'));
    const h = parseHeader(header({ write_order: [2, 0, 1], index_released: [1] }));
    // write_order[1] is member 0, which is `a`.
    expect(project(staged('a', 'g1'), h, INDEX_VIEW, members).state).toBe('published');
    expect(project(staged('b', 'g1'), h, INDEX_VIEW, members).state).toBe('pending');
    expect(project(staged('c', 'g1'), h, INDEX_VIEW, members).state).toBe('pending');
    // Not a member, no member list, or a header without an order or gates: not released.
    expect(project(staged('z', 'g1'), h, INDEX_VIEW, members).state).toBe('pending');
    expect(project(staged('a', 'g1'), h, INDEX_VIEW).state).toBe('pending');
    expect(project(staged('a', 'g1'), parseHeader(header()), INDEX_VIEW, members).state).toBe('pending');
    expect(project(staged('a', 'g1'), parseHeader(header({ write_order: [0] })), INDEX_VIEW, members).state).toBe('pending');
  });

  test('the takedown build never releases a member', () => {
    const r = staged('p', 'g1');
    expect(project(r, parseHeader(header({ repodata_released: ['noarch'], write_order: [0], index_released: [0] })), TAKEDOWNS_VIEW, parseMembers(memberList('p')))).toBe(r);
  });
});

describe('the group items, as read', () => {
  test('keys', () => {
    expect(headerKey('abc')).toBe('grp#abc');
    expect(membersKey('abc')).toBe('grpm#abc');
  });

  test('a header keeps what it holds and nothing is invented', () => {
    expect(parseHeader({ status: 'committed', attempt: 2, committed_at: COMMITTED_AT, write_order: [1, 0], repodata_released: ['noarch'], index_released: [0], rev: 9, extra: 'x' })).toEqual({
      status: 'committed',
      attempt: 2,
      committed_at: COMMITTED_AT,
      write_order: [1, 0],
      repodata_released: ['noarch'],
      index_released: [0],
    });
    expect(parseHeader({ status: 'open', attempt: 1 })).toEqual({ status: 'open', attempt: 1 });
  });

  test('an item that is not understood shows nothing: no marker, no attempt that a row carries', () => {
    expect(parseHeader({})).toEqual({ status: '', attempt: -1 });
    expect(parseHeader({ status: 5, attempt: '1', committed_at: '' })).toEqual({ status: '', attempt: -1 });
    expect(parseHeader({ committed_at: 12 })).toEqual({ status: '', attempt: -1 });
    expect(parseHeader({ write_order: [1, 'x', 2], repodata_released: ['a', 3], index_released: 'no' })).toEqual({
      status: '',
      attempt: -1,
      write_order: [1, 2],
      repodata_released: ['a'],
    });
  });

  test('a member list keeps well-formed members and drops the rest', () => {
    expect(parseMembers({ members: [{ name: 'a', version: '1.0', canonical: '1.0.0', subdirs: ['noarch', 3] }, { name: 'b', canonical: '2.0.0' }, { name: 5 }, null, 'x'] })).toEqual({
      members: [
        { name: 'a', version: '1.0', canonical: '1.0.0', subdirs: ['noarch'] },
        { name: 'b', version: '2.0.0', canonical: '2.0.0', subdirs: [] },
      ],
    });
    expect(parseMembers({})).toEqual({ members: [] });
  });
});

describe.each(RIGS)('the funnel over the %s adapter', (_label, makeRig) => {
  let r: Rig;
  beforeEach(() => {
    r = makeRig();
  });

  describe('rows without a group', () => {
    test('no group item is read, no metric emitted and nothing logged, in every call and view', async () => {
      for (const n of ['p', 'q']) r.writeRow(rec({ name: n, version: '1.0.0' }));
      r.writeRow(rec({ name: 'p', version: '1.1.0', state: 'pending' }));
      await r.claim('p');
      expect(states(await r.store.listVersions('p'))).toEqual(['published', 'pending']);
      expect((await r.store.getVersion('p', '1.1.0'))!.state).toBe('pending');
      expect(await r.store.getVersion('p', '9.9.9')).toBeUndefined();
      for (const view of [API_VIEW, repodataView('linux-64'), INDEX_VIEW, TAKEDOWNS_VIEW]) {
        expect(stateMap(await r.store.versionsOf(['p', 'q', 'none'], view))).toEqual({ p: ['published', 'pending'], q: ['published'], none: [] });
      }
      expect((await allRecords(r.store, repodataView('linux-64'))).map((x) => x.name)).toEqual(['p', 'p']);
      expect(r.groupReads()).toEqual([]);
      expect(r.lines).toEqual([]);
      expect(r.logs).toEqual([]);
    });

    test('a package listed twice is read once and answered once', async () => {
      r.writeRow(rec({ name: 'p', version: '1.0.0' }));
      expect([...(await r.store.versionsOf(['p', 'p'], API_VIEW)).keys()]).toEqual(['p']);
    });
  });

  describe('a member of a group that has not committed', () => {
    beforeEach(() => seedGroup(r, 'g1', open, ['a', 'b'], [staged('a', 'g1'), staged('b', 'g1')]));

    test('is pending for every call', async () => {
      expect((await r.store.getVersion('a', '1.0.0'))!.state).toBe('pending');
      expect(states(await r.store.listVersions('a'))).toEqual(['pending']);
      expect(stateMap(await r.store.versionsOf(['a', 'b'], API_VIEW))).toEqual({ a: ['pending'], b: ['pending'] });
      expect(r.groupReads().every((k) => k === 'grp#g1')).toBe(true);
    });

    test('reads the header and no member list', async () => {
      await r.store.versionsOf(['a', 'b'], API_VIEW);
      expect(r.groupReads()).toEqual(['grp#g1']);
    });
  });

  describe('a member of a committed group', () => {
    beforeEach(() => seedGroup(r, 'g1', header(), ['a', 'b', 'c'], ['a', 'b', 'c'].map((n) => staged(n, 'g1', 1, { rev: 4 }))));

    test('is published at the commit time with its stored rev, for getVersion and listVersions', async () => {
      const one = (await r.store.getVersion('a', '1.0.0'))!;
      expect(one).toMatchObject({ state: 'published', published_at: COMMITTED_AT, rev: 4, group_id: 'g1', staged_attempt: 1 });
      expect(await r.store.listVersions('a')).toEqual([one]);
    });

    test('is shown whole by one call over all its packages, which reads the header and the member list once', async () => {
      expect(stateMap(await r.store.versionsOf(['a', 'b', 'c'], API_VIEW))).toEqual({ a: ['published'], b: ['published'], c: ['published'] });
      expect(r.groupReads()).toEqual(['grp#g1', 'grpm#g1']);
    });

    test('has its header read again by the next call, and its member list not (the list never changes)', async () => {
      await r.store.versionsOf(['a'], API_VIEW);
      await r.store.versionsOf(['b'], API_VIEW);
      expect(r.groupReads()).toEqual(['grp#g1', 'grpm#g1', 'grp#g1']);
      expect(r.metricTotal('group_member_list_reads')).toBe(1);
      expect(r.metricTotal('group_header_reads')).toBe(2);
    });

    test('is not published in a build view until its gate is set', async () => {
      expect(stateMap(await r.store.versionsOf(['a', 'b', 'c'], repodataView('linux-64')))).toEqual({ a: ['pending'], b: ['pending'], c: ['pending'] });
      expect(stateMap(await r.store.versionsOf(['a'], INDEX_VIEW))).toEqual({ a: ['pending'] });
    });

    test('a package that was not asked for is not read: widening is for the repodata builders only', async () => {
      expect([...(await r.store.versionsOf(['a'], API_VIEW)).keys()]).toEqual(['a']);
      expect([...(await r.store.versionsOf(['a'], INDEX_VIEW)).keys()]).toEqual(['a']);
      expect([...(await r.store.versionsOf(['a'], TAKEDOWNS_VIEW)).keys()]).toEqual(['a']);
      expect([...(await r.store.versionsOf(['a'], repodataView('linux-64'))).keys()].sort()).toEqual(['a', 'b', 'c']);
    });
  });

  describe('a settled group (header visible)', () => {
    beforeEach(() => seedGroup(r, 'g1', header({ status: 'visible' }), ['a'], [flipped('a', 'g1')]));

    test('is read as stored, and its header is read once per container', async () => {
      expect(stateMap(await r.store.versionsOf(['a'], API_VIEW))).toEqual({ a: ['published'] });
      expect(stateMap(await r.store.versionsOf(['a'], API_VIEW))).toEqual({ a: ['published'] });
      expect(await r.store.listVersions('a')).toHaveLength(1);
      expect(r.groupReads()).toEqual(['grp#g1']);
      expect(r.metricTotal('group_header_cache_hits')).toBe(2);
    });

    test('a pending row of a settled group (which cannot arise) is read as stored: hidden', async () => {
      r.writeRow(staged('z', 'g1'));
      await r.store.versionsOf(['a'], API_VIEW); // learns that g1 is settled
      expect(stateMap(await r.store.versionsOf(['z'], API_VIEW))).toEqual({ z: ['pending'] });
      expect((await r.store.getVersion('z', '1.0.0'))!.state).toBe('pending');
      expect(r.groupReads()).toEqual(['grp#g1']);
    });
  });

  test('getVersion of a flipped member reads no header: the row ignores its group', async () => {
    seedGroup(r, 'g1', header({ status: 'committed' }), ['a'], [flipped('a', 'g1')]);
    expect((await r.store.getVersion('a', '1.0.0'))!.state).toBe('published');
    expect(r.groupReads()).toEqual([]);
  });

  describe('a row that names a group with no header', () => {
    beforeEach(() => seedGroup(r, 'g9', null, ['a'], [staged('a', 'g9')]));

    test('stays hidden for getVersion, listVersions and versionsOf, and each says so', async () => {
      expect((await r.store.getVersion('a', '1.0.0'))!.state).toBe('pending');
      expect(states(await r.store.listVersions('a'))).toEqual(['pending']);
      expect(stateMap(await r.store.versionsOf(['a'], repodataView('linux-64')))).toEqual({ a: ['pending'] });
      expect(r.metricTotal('group_header_missing')).toBe(3);
      expect(r.logs).toHaveLength(3);
      expect(r.logs[0]).toMatchObject({ level: 'error', group_id: 'g9' });
    });
  });

  describe('a reader paused after reading the rows', () => {
    const stageAndCommit = (names: string[], gid = 'g1') => {
      for (const n of names) r.writeRow(staged(n, gid));
      r.putGroupItem(headerKey(gid), header());
    };
    const once = (fn: () => void) => {
      let done = false;
      r.beforeGroupRead((key) => {
        if (done || !key.startsWith('grp#')) return;
        done = true;
        fn();
      });
    };

    test('while its member is staged and committed: it never serves the reserved row, and shows the member', async () => {
      seedGroup(r, 'g1', open, ['a', 'b'], [reserved('a', 'g1'), reserved('b', 'g1')]);
      once(() => stageAndCommit(['a', 'b']));
      expect(stateMap(await r.store.versionsOf(['a', 'b'], API_VIEW))).toEqual({ a: ['published'], b: ['published'] });
      expect(r.metricTotal('group_pass2b')).toBe(2);
      expect(r.metricTotal('group_invariant')).toBe(0);
    });

    test('while its member is staged and not committed: the member stays hidden', async () => {
      seedGroup(r, 'g1', open, ['a', 'b'], [reserved('a', 'g1'), reserved('b', 'g1')]);
      once(() => {
        r.writeRow(staged('a', 'g1'));
        r.writeRow(staged('b', 'g1'));
      });
      expect(stateMap(await r.store.versionsOf(['a', 'b'], API_VIEW))).toEqual({ a: ['pending'], b: ['pending'] });
    });

    test('before a member was reserved at all: the commit shows every member, found by the completeness pass', async () => {
      seedGroup(r, 'g1', open, ['a', 'b'], [reserved('a', 'g1')]);
      once(() => stageAndCommit(['a', 'b']));
      expect(stateMap(await r.store.versionsOf(['a', 'b'], API_VIEW))).toEqual({ a: ['published'], b: ['published'] });
      expect(r.metricTotal('group_pass2')).toBe(1);
    });

    test('getVersion: the row read before it was stamped is read again once the commit is seen', async () => {
      seedGroup(r, 'g1', open, ['a'], [reserved('a', 'g1')]);
      once(() => stageAndCommit(['a']));
      expect(await r.store.getVersion('a', '1.0.0')).toMatchObject({ state: 'published', published_at: COMMITTED_AT, staged_attempt: 1 });
      expect(r.metricTotal('group_pass2b')).toBe(1);
    });

    test('getVersion: staged but not committed stays hidden', async () => {
      seedGroup(r, 'g1', open, ['a'], [reserved('a', 'g1')]);
      once(() => r.writeRow(staged('a', 'g1')));
      expect((await r.store.getVersion('a', '1.0.0'))!.state).toBe('pending');
    });

    test('getVersion: a row that is still not this attempt after the second read is hidden and reported', async () => {
      seedGroup(r, 'g1', open, ['a'], [staged('a', 'g1', 1)]);
      once(() => r.putGroupItem(headerKey('g1'), header({ attempt: 2 })));
      expect((await r.store.getVersion('a', '1.0.0'))!.state).toBe('pending');
      expect(r.metricTotal('group_invariant')).toBe(1);
      expect(r.logs).toHaveLength(1);
      expect(r.logs[0]).toMatchObject({ group_id: 'g1' });
    });

    test('getVersion: a row flipped between the two reads is returned as flipped', async () => {
      seedGroup(r, 'g1', open, ['a'], [reserved('a', 'g1')]);
      once(() => {
        r.writeRow(flipped('a', 'g1'));
        r.putGroupItem(headerKey('g1'), header());
      });
      expect(await r.store.getVersion('a', '1.0.0')).toMatchObject({ state: 'published', rev: 2 });
    });

    test('a package whose second read brings in another committed group has that group\'s header read too', async () => {
      seedGroup(r, 'g1', open, ['p'], [reserved('p', 'g1')]);
      once(() => {
        stageAndCommit(['p']);
        seedGroup(r, 'g2', header(), [['p', '2.0.0']], [staged('p', 'g2', 1, { version: '2.0.0', canonical: '2.0.0' })]);
      });
      const rows = (await r.store.versionsOf(['p'], API_VIEW)).get('p')!;
      expect(rows.map((x) => `${x.version} ${x.state}`)).toEqual(['1.0.0 published', '2.0.0 published']);
      expect(r.groupReads()).toEqual(['grp#g1', 'grpm#g1', 'grp#g2', 'grpm#g2']);
    });
  });

  describe('a build that lists the packages, then reads them', () => {
    /** Claim packages and commit a group of a, b, c after the list was made: the builder must see 0 or all of the group. */
    async function buildWithGroupClaimedAfterTheList(commit: 'committed' | 'not committed' | 'committed, not released') {
      await r.claim('a');
      seedGroup(r, 'g1', open, ['a', 'b', 'c'], [reserved('a', 'g1')]);
      const list = r.store.listPackageNames.bind(r.store);
      r.store.listPackageNames = async () => {
        const names = await list(); // only a is claimed
        await r.claim('b');
        await r.claim('c');
        for (const n of ['a', 'b', 'c']) r.writeRow(staged(n, 'g1'));
        if (commit !== 'not committed') r.putGroupItem(headerKey('g1'), header({ ...(commit === 'committed' ? { repodata_released: ['linux-64'] } : {}) }));
        return names;
      };
      return allRecords(r.store, repodataView('linux-64'));
    }

    test('commit seen: all three members are in the build, though two were claimed after the list', async () => {
      const rows = await buildWithGroupClaimedAfterTheList('committed');
      expect(rows.map((x) => `${x.name} ${x.state}`).sort()).toEqual(['a published', 'b published', 'c published']);
    });

    test('no commit: none is in the build', async () => {
      const rows = await buildWithGroupClaimedAfterTheList('not committed');
      expect(states(rows).filter((s) => s !== 'pending')).toEqual([]);
    });

    test('commit seen but the subdir not released: none is in the build, and the late packages are still read', async () => {
      const rows = await buildWithGroupClaimedAfterTheList('committed, not released');
      expect(rows.map((x) => x.name).sort()).toEqual(['a', 'b', 'c']);
      expect(states(rows).filter((s) => s !== 'pending')).toEqual([]);
    });
  });

  describe('a committed group that cannot be accounted for', () => {
    test('API: a member whose row is missing hides the whole group for that call, is logged and counted, and does not fail', async () => {
      seedGroup(r, 'g1', header(), ['a', 'b'], [staged('a', 'g1')]); // b was never written
      expect(stateMap(await r.store.versionsOf(['a', 'b'], API_VIEW))).toEqual({ a: ['pending'], b: [] });
      expect(r.metricTotal('group_invariant')).toBe(1);
      expect(r.logs[0]).toMatchObject({ level: 'error', group_id: 'g1' });
    });

    test('API: only the packages asked for are checked', async () => {
      seedGroup(r, 'g1', header(), ['a', 'b'], [staged('a', 'g1')]);
      expect(stateMap(await r.store.versionsOf(['a'], API_VIEW))).toEqual({ a: ['published'] });
      expect(r.metricTotal('group_invariant')).toBe(0);
    });

    test('API: a member still of another attempt after the second read hides the group', async () => {
      seedGroup(r, 'g1', header({ attempt: 2 }), ['a', 'b'], [staged('a', 'g1', 2), staged('b', 'g1', 1)]);
      expect(stateMap(await r.store.versionsOf(['a', 'b'], API_VIEW))).toEqual({ a: ['pending'], b: ['pending'] });
      expect(r.metricTotal('group_invariant')).toBe(1);
    });

    test('API: a committed group without a member list is hidden', async () => {
      r.putGroupItem(headerKey('g1'), header());
      r.writeRow(staged('a', 'g1'));
      expect(stateMap(await r.store.versionsOf(['a'], API_VIEW))).toEqual({ a: ['pending'] });
      expect(r.metricTotal('group_invariant')).toBe(1);
    });

    test('API: a row that names the group but is another version than the member is not the member', async () => {
      seedGroup(r, 'g1', header(), ['a'], [staged('a', 'g1', 1, { version: '2.0.0', canonical: '2.0.0' })]);
      expect(stateMap(await r.store.versionsOf(['a'], API_VIEW))).toEqual({ a: ['pending'] });
      expect(r.metricTotal('group_invariant')).toBe(1);
    });

    test.each<[string, View]>([
      ['repodata', repodataView('linux-64')],
      ['package index', INDEX_VIEW],
    ])('%s builder: fails, so the hop retries and then dead-letters', async (_n, view) => {
      // The member's row carries an older attempt than the header's.
      seedGroup(r, 'g1', header({ repodata_released: ['linux-64'], write_order: [0], index_released: [0] }), ['a'], [staged('a', 'g1', 0)]);
      await expect(r.store.versionsOf(['a'], view)).rejects.toThrow(GroupInvariantError);
      expect(r.metricTotal('group_invariant')).toBe(1);
    });
  });

  describe('an answer that cannot be had is never read as "hidden"', () => {
    beforeEach(() => seedGroup(r, 'g1', header(), ['a'], [staged('a', 'g1')]));

    test('a header read that fails fails the call with unavailable (503), for single and multi-package reads', async () => {
      r.failGroupReads(new Error('network down'));
      await expect(r.store.getVersion('a', '1.0.0')).rejects.toMatchObject({ code: 'unavailable', status: 503 });
      await expect(r.store.listVersions('a')).rejects.toMatchObject({ code: 'unavailable', status: 503 });
      await expect(r.store.versionsOf(['a'], API_VIEW)).rejects.toMatchObject({ code: 'unavailable', status: 503 });
      expect(r.metricTotal('header_throttle')).toBe(0);
      expect(r.logs.map((l) => l.msg)).toEqual(['group header unreadable', 'group header unreadable', 'group header unreadable']);
    });

    test.each(['ProvisionedThroughputExceededException', 'ThrottlingException', 'RequestLimitExceeded'])('a %s is counted as a throttle', async (name) => {
      r.failGroupReads(Object.assign(new Error('slow down'), { name }));
      await expect(r.store.versionsOf(['a'], API_VIEW)).rejects.toMatchObject({ code: 'unavailable' });
      expect(r.metricTotal('header_throttle')).toBe(1);
    });

    test('a member list read that fails fails the call too', async () => {
      r.beforeGroupRead((key) => {
        if (key.startsWith('grpm#')) throw new Error('boom');
      });
      await expect(r.store.versionsOf(['a'], API_VIEW)).rejects.toMatchObject({ code: 'unavailable' });
      expect(r.logs.map((l) => l.msg)).toEqual(['group member list unreadable']);
    });
  });

  describe('the container\'s caches are bounded', () => {
    test('settled groups: the oldest is forgotten past the bound, and read again', async () => {
      const small = makeRig({ settledCacheSize: 1 });
      seedGroup(small, 'g1', header({ status: 'visible' }), ['a'], [flipped('a', 'g1')]);
      seedGroup(small, 'g2', header({ status: 'visible' }), ['b'], [flipped('b', 'g2')]);
      for (const n of ['a', 'b', 'a']) await small.store.versionsOf([n], API_VIEW);
      expect(small.groupReads()).toEqual(['grp#g1', 'grp#g2', 'grp#g1']);
    });

    test('settled groups: within the bound nothing is read twice', async () => {
      seedGroup(r, 'g1', header({ status: 'visible' }), ['a'], [flipped('a', 'g1')]);
      seedGroup(r, 'g2', header({ status: 'visible' }), ['b'], [flipped('b', 'g2')]);
      for (const n of ['a', 'b', 'a']) await r.store.versionsOf([n], API_VIEW);
      expect(r.groupReads()).toEqual(['grp#g1', 'grp#g2']);
    });

    test('member lists: the least recently used is forgotten past the bound', async () => {
      const small = makeRig({ membersCacheSize: 1 });
      seedGroup(small, 'g1', header(), ['a'], [staged('a', 'g1')]);
      seedGroup(small, 'g2', header(), ['b'], [staged('b', 'g2')]);
      for (const n of ['a', 'b', 'a']) await small.store.versionsOf([n], API_VIEW);
      expect(small.groupReads().filter((k) => k.startsWith('grpm#'))).toEqual(['grpm#g1', 'grpm#g2', 'grpm#g1']);
    });

    test('member lists: a recently used one is kept', async () => {
      const small = makeRig({ membersCacheSize: 2 });
      seedGroup(small, 'g1', header(), ['a'], [staged('a', 'g1')]);
      seedGroup(small, 'g2', header(), ['b'], [staged('b', 'g2')]);
      seedGroup(small, 'g3', header(), ['c'], [staged('c', 'g3')]);
      for (const n of ['a', 'b', 'a', 'c', 'a']) await small.store.versionsOf([n], API_VIEW);
      expect(small.groupReads().filter((k) => k.startsWith('grpm#'))).toEqual(['grpm#g1', 'grpm#g2', 'grpm#g3']);
    });
  });

  describe('updateVersion starts from the row as a reader sees it', () => {
    test('a member of a group that has not committed cannot be yanked, published or tombstoned through the store', async () => {
      seedGroup(r, 'g1', open, ['a'], [staged('a', 'g1')]);
      for (const ev of [{ type: 'yank', reason: 'x' }, { type: 'unyank' }, { type: 'publish' }, { type: 'tombstone', reason_code: 'malware', date: '2026-10-14' }] as const) {
        await expect(r.store.updateVersion('a', '1.0.0', ev, audit('a', ev.type))).rejects.toMatchObject({ code: 'invalid_transition' });
      }
      expect(await r.store.raw.rawGet('a', '1.0.0')).toMatchObject({ state: 'pending', rev: 1 });
      expect(await r.store.listAudit('a')).toEqual([]);
    });

    test('a committed member that is not yet flipped can be yanked: the stored row becomes a full yanked row with its group fields', async () => {
      seedGroup(r, 'g1', header(), ['a'], [staged('a', 'g1', 1, { rev: 1 })]);
      const out = await r.store.updateVersion('a', '1.0.0', { type: 'yank', reason: 'bad' }, audit('a', 'yank', '1.0.0'));
      expect(out).toMatchObject({ state: 'yanked', yank_reason: 'bad', rev: 2, group_id: 'g1', staged_attempt: 1, published_at: COMMITTED_AT });
      expect(await r.store.raw.rawGet('a', '1.0.0')).toEqual(out);
      expect(await r.store.getVersion('a', '1.0.0')).toEqual(out);
      expect(await r.store.listAudit('a')).toHaveLength(1);
    });

    test('and then unyanked, as any published row', async () => {
      seedGroup(r, 'g1', header(), ['a'], [staged('a', 'g1', 1, { rev: 1 })]);
      await r.store.updateVersion('a', '1.0.0', { type: 'yank', reason: 'bad' }, audit('a', 'yank'));
      expect(await r.store.updateVersion('a', '1.0.0', { type: 'unyank' }, audit('a', 'unyank'))).toMatchObject({ state: 'published', rev: 3, group_id: 'g1' });
    });

    test('publishing a committed member again changes nothing and writes nothing', async () => {
      seedGroup(r, 'g1', header(), ['a'], [staged('a', 'g1', 1, { rev: 1 })]);
      expect(await r.store.updateVersion('a', '1.0.0', { type: 'publish' }, audit('a', 'publish'))).toMatchObject({ state: 'published', rev: 1 });
      expect(await r.store.raw.rawGet('a', '1.0.0')).toMatchObject({ state: 'pending', rev: 1 });
      expect(await r.store.listAudit('a')).toEqual([]);
    });

    test('a row that keeps changing under the update ends in internal_error, not a lost write', async () => {
      r.writeRow(rec({ name: 'a', version: '1.0.0' }));
      const rawGet = r.store.raw.rawGet.bind(r.store.raw);
      r.store.raw.rawGet = async (n, v) => {
        const row = await rawGet(n, v);
        if (row) r.writeRow({ ...row, rev: row.rev + 1 });
        return row;
      };
      await expect(r.store.updateVersion('a', '1.0.0', { type: 'yank', reason: 'x' }, audit('a', 'yank'))).rejects.toMatchObject({ code: 'internal_error' });
      expect(await r.store.listAudit('a')).toEqual([]);
    });

    test('a version that is not there is version_not_found', async () => {
      await expect(r.store.updateVersion('a', '1.0.0', { type: 'yank', reason: 'x' }, audit('a', 'yank'))).rejects.toMatchObject({ code: 'version_not_found' });
    });
  });

  test('a header whose attempt is not a number never matches a row', async () => {
    r.putGroupItem(headerKey('g1'), { status: 'committed', attempt: '1', committed_at: COMMITTED_AT });
    r.putGroupItem(membersKey('g1'), memberList('a'));
    r.writeRow(staged('a', 'g1'));
    expect((await r.store.getVersion('a', '1.0.0'))!.state).toBe('pending');
    expect(stateMap(await r.store.versionsOf(['a'], API_VIEW))).toEqual({ a: ['pending'] });
  });
});

describe('embedded metric lines', () => {
  const at = new Date('2026-10-14T10:00:00Z');

  test('the line is the CloudWatch format: values at the top, the declaration under _aws, dimensions and properties beside them', () => {
    expect(emf([{ name: 'group_invariant', value: 2 }, { name: 'hop_ms', value: 15, unit: 'Milliseconds' }], { dimensions: { Stage: 'beta' }, props: { group_id: 'g1' }, now: at })).toEqual({
      group_id: 'g1',
      Stage: 'beta',
      group_invariant: 2,
      hop_ms: 15,
      _aws: {
        Timestamp: at.getTime(),
        CloudWatchMetrics: [{ Namespace: METRICS_NAMESPACE, Dimensions: [['Stage']], Metrics: [{ Name: 'group_invariant', Unit: 'Count' }, { Name: 'hop_ms', Unit: 'Milliseconds' }] }],
      },
    });
  });

  test('with no dimension the dimension set is empty, and the time defaults to now', () => {
    const line = emf([{ name: 'm', value: 1 }]) as { _aws: { Timestamp: number; CloudWatchMetrics: Array<{ Dimensions: string[][] }> } };
    expect(line._aws.CloudWatchMetrics[0]!.Dimensions).toEqual([[]]);
    expect(Math.abs(line._aws.Timestamp - Date.now())).toBeLessThan(5000);
  });

  test.each([
    ['no metric', [] as Array<{ name: string; value: number }>],
    ['a metric twice', [{ name: 'm', value: 1 }, { name: 'm', value: 2 }]],
    ['a value that is not finite', [{ name: 'm', value: Number.NaN }]],
  ])('refuses %s', (_n, metrics) => {
    expect(() => emf(metrics)).toThrow();
  });

  test('Metrics sends lines to its sink with its dimensions, count adds one, and an empty emit sends nothing', () => {
    const lines: Array<Record<string, unknown>> = [];
    const m = new Metrics((l) => lines.push(l), { Stage: 'gamma' }, () => at);
    m.count('a');
    m.count('b', 3, { group_id: 'g' });
    m.emit([]);
    expect(lines).toHaveLength(2);
    expect(lines[0]).toMatchObject({ Stage: 'gamma', a: 1 });
    expect(lines[1]).toMatchObject({ b: 3, group_id: 'g' });
  });

  test('a sink that throws, or a value that is refused, never fails the caller', () => {
    const m = new Metrics(() => {
      throw new Error('sink');
    });
    expect(() => m.count('a')).not.toThrow();
    expect(() => new Metrics((l) => l).emit([{ name: 'a', value: Number.POSITIVE_INFINITY }])).not.toThrow();
  });

  test('the default sink writes one JSON line to the log', () => {
    const spy = jest.spyOn(console, 'log').mockImplementation(() => undefined);
    try {
      new Metrics().count('x');
      consoleSink({ a: 1 });
      expect(spy).toHaveBeenCalledTimes(2);
      expect(JSON.parse(spy.mock.calls[0]![0] as string)).toMatchObject({ x: 1 });
      expect(spy.mock.calls[1]![0]).toBe('{"a":1}');
    } finally {
      spy.mockRestore();
    }
  });
});
