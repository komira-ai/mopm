import { createHash } from 'node:crypto';
import { marshall } from '@aws-sdk/util-dynamodb';
import { PutCommand, TransactWriteCommand } from '@aws-sdk/lib-dynamodb';
import { headerKey, repodataView } from '../src/group';
import { bitmapHas, bitmapIndexes, bitmapSet, commitToken, groupItem, memberAuditId, parseGroupRecord, type GroupRecord } from '../src/group-store';
import { applyEvent, WrongGroup, type GroupEvent, type PublishFill } from '../src/state';
import type { VersionRecord } from '../src/types';
import { audit, rec } from './helpers';
import { COMMITTED_AT, dynamoRig, flipped, header, memberList, RIGS, reserved, seedGroup, staged, type Rig } from './group-rig';

/**
 * The writers of a group, on both adapters: the header and member list, the commit, the adoption of a number, and the
 * two events only a group sends. Every test names what it proves in its title. The readers' side (what a reader
 * shows of a member) is test/group.test.ts; the last test here runs a whole group through both.
 */

const group = (over: Partial<GroupRecord> = {}): GroupRecord => ({
  group_id: 'g1',
  status: 'validating',
  attempt: 1,
  rev: 0,
  actor: 'u:1',
  member_count: 2,
  created_at: '2026-10-14T08:00:00Z',
  deadline_at: '2026-10-14T20:00:00Z',
  progress_at: '2026-10-14T08:30:00Z',
  reserved: '',
  validated: '',
  staged: '',
  copied: '',
  flipped: '',
  resend: 0,
  ...over,
});
const gaudit = (action: string, gid = 'g1') => audit(headerKey(gid), action);
const fill = (name: string): PublishFill => {
  const r = rec({ name, version: '1.0.0' });
  return { version: r.version, build: r.build, requires_mojo: r.requires_mojo, deps: r.deps, native: r.native, files: r.files, manifest_sha256: r.manifest_sha256, published_at: r.published_at, published_by: 'octocat' };
};
const stage = (gid: string, attempt: number, name = 'p'): GroupEvent => ({ type: 'stage', group_id: gid, attempt, fill: fill(name) });
const flip = (gid: string, attempt: number): GroupEvent => ({ type: 'group_publish', group_id: gid, attempt, committed_at: COMMITTED_AT });
const commitArgs = (over: Partial<{ rev: number; writeOrder: number[]; now: string }> = {}) => ({ rev: 0, writeOrder: [1, 0], now: COMMITTED_AT, audit: gaudit('group_commit'), ...over });
const actions = async (r: Rig, name: string) => (await r.store.listAudit(name)).map((a) => a.action);
const raw = (r: Rig, name = 'p') => r.store.raw.rawGet(name, '1.0.0');

describe.each(RIGS)('the writers of a group: %s', (_label, make) => {
  let r: Rig;
  beforeEach(() => {
    r = make();
  });

  describe('creating a group', () => {
    test('writes the member list and the header with its audit row; the same call again changes nothing and returns the stored header', async () => {
      const g = group({ status: 'open' });
      expect(await r.store.createGroup(g, memberList('a', 'b'), gaudit('group_create'))).toEqual({ created: true, header: g });
      expect(await r.store.getGroup('g1')).toEqual(g);
      expect(await r.store.getGroupMembers('g1')).toEqual(memberList('a', 'b'));
      expect(await actions(r, 'grp#g1')).toEqual(['group_create']);

      const again = await r.store.createGroup({ ...g, actor: 'u:2' }, memberList('a', 'b'), gaudit('group_create'));
      expect(again).toEqual({ created: false, header: g });
      expect(await r.store.getGroup('g1')).toEqual(g);
      expect(await actions(r, 'grp#g1')).toEqual(['group_create']);
      expect(await r.store.getGroup('nope')).toBeUndefined();
      expect(await r.store.getGroupMembers('nope')).toBeUndefined();
    });

    test('a member list written by an earlier, interrupted create is accepted when it is the same list, and a different list is refused with the header unwritten', async () => {
      r.putGroupItem('grpm#g2', memberList('a'));
      expect((await r.store.createGroup(group({ group_id: 'g2' }), memberList('a'), gaudit('group_create', 'g2'))).created).toBe(true);

      await r.store.createGroup(group(), memberList('a', 'b'), gaudit('group_create'));
      await expect(r.store.createGroup(group({ group_id: 'g1', actor: 'u:9' }), memberList('a', 'c'), gaudit('group_create'))).rejects.toThrow(/already has another member list/);
      expect((await r.store.getGroup('g1'))!.actor).toBe('u:1');
      expect(await actions(r, 'grp#g1')).toEqual(['group_create']);
    });

    test('a header that carries the commit marker, or a committed status without it, is refused and nothing is written', async () => {
      await expect(r.store.createGroup(group({ status: 'committed', committed_at: COMMITTED_AT }), memberList('a'), gaudit('x'))).rejects.toThrow(/committed_at is written by commitGroup alone/);
      await expect(r.store.createGroup(group({ status: 'visible' }), memberList('a'), gaudit('x'))).rejects.toThrow(/does not match committed_at/);
      expect(await r.store.getGroup('g1')).toBeUndefined();
      expect(await r.store.getGroupMembers('g1')).toBeUndefined();
      expect(await actions(r, 'grp#g1')).toEqual([]);
    });
  });

  describe('updating a header', () => {
    beforeEach(async () => {
      await r.store.createGroup(group({ status: 'open' }), memberList('a', 'b'), gaudit('group_create'));
    });

    test('fn sees the header read, the result is written one revision on and returned; fn returning nothing writes nothing; a missing group is undefined', async () => {
      const u = await r.store.updateGroup('g1', (cur) => ({ ...cur, status: 'validating', reserved: bitmapSet(cur.reserved, 0) }), gaudit('group_validate'));
      expect(u).toMatchObject({ status: 'validating', rev: 1, reserved: '1' });
      expect(await r.store.getGroup('g1')).toEqual(u);
      expect(await r.store.updateGroup('g1', () => undefined, gaudit('never'))).toEqual(u);
      expect((await r.store.getGroup('g1'))!.rev).toBe(1);
      expect(await actions(r, 'grp#g1')).toEqual(['group_create', 'group_validate']);
      expect(await r.store.updateGroup('nope', (c) => c)).toBeUndefined();
      // Without an audit row it is a plain write.
      expect((await r.store.updateGroup('g1', (c) => ({ ...c, progress_at: '2026-10-14T08:45:00Z' })))!.rev).toBe(2);
      expect(await actions(r, 'grp#g1')).toEqual(['group_create', 'group_validate']);
    });

    test('four updates at once each keep their own change: none is lost, and the revision counts them', async () => {
      await Promise.all([0, 1, 2, 3].map((i) => r.store.updateGroup('g1', (cur) => ({ ...cur, reserved: bitmapSet(cur.reserved, i) }))));
      const end = (await r.store.getGroup('g1'))!;
      expect(bitmapIndexes(end.reserved)).toEqual([0, 1, 2, 3]);
      expect(end.rev).toBe(4);
    });

    test('an update never sets, changes or unsets the commit marker, never makes a status disagree with it, and never changes the group id', async () => {
      await r.store.updateGroup('g1', (c) => ({ ...c, status: 'validating' }));
      const set = (c: GroupRecord) => ({ ...c, committed_at: COMMITTED_AT });
      await expect(r.store.updateGroup('g1', set)).rejects.toThrow(/committed_at is written by commitGroup alone/);
      await expect(r.store.updateGroup('g1', (c) => ({ ...c, status: 'committed' }))).rejects.toThrow(/does not match committed_at/);
      await expect(r.store.updateGroup('g1', (c) => ({ ...c, group_id: 'g2' }))).rejects.toThrow(/the header read is group g1/);
      expect(await r.store.commitGroup('g1', commitArgs({ rev: 1 }))).toMatchObject({ outcome: 'committed' });

      const committed = (await r.store.getGroup('g1'))!;
      const unset = (c: GroupRecord): GroupRecord => {
        const { committed_at: _gone, ...rest } = c;
        return rest as GroupRecord;
      };
      await expect(r.store.updateGroup('g1', unset)).rejects.toThrow(/committed_at is written by commitGroup alone/);
      await expect(r.store.updateGroup('g1', (c) => ({ ...c, committed_at: '2026-10-15T00:00:00Z' }))).rejects.toThrow(/committed_at is written by commitGroup alone/);
      await expect(r.store.updateGroup('g1', (c) => ({ ...c, status: 'failed' }))).rejects.toThrow(/does not match committed_at/);
      expect(await r.store.getGroup('g1')).toEqual(committed);
      // What a committed group may do: go on to `visible`.
      expect(await r.store.updateGroup('g1', (c) => ({ ...c, status: 'visible' }))).toMatchObject({ status: 'visible', committed_at: COMMITTED_AT });
    });
  });

  describe('the commit', () => {
    beforeEach(async () => {
      await r.store.createGroup(group(), memberList('a', 'b'), gaudit('group_create'));
    });

    test('sets committed_at, the write order and the status in one write, with its audit row, and changes nothing else', async () => {
      const before = (await r.store.getGroup('g1'))!;
      const out = await r.store.commitGroup('g1', commitArgs());
      const want: GroupRecord = { ...before, status: 'committed', committed_at: COMMITTED_AT, write_order: [1, 0], progress_at: COMMITTED_AT, rev: 1 };
      expect(out).toEqual({ outcome: 'committed', header: want });
      expect(await r.store.getGroup('g1')).toEqual(want);
      expect(await actions(r, 'grp#g1')).toEqual(['group_create', 'group_commit']);
    });

    test.each([
      ['a revision other than the one the caller read', { rev: 7 }, {}, 'conflict'],
      ['a header that is not validating (open)', {}, { status: 'open' }, 'conflict'],
      ['a header that is not validating (failed)', {}, { status: 'failed' }, 'conflict'],
      ['a time past the deadline', { now: '2026-10-14T20:00:01Z' }, {}, 'deadline'],
    ] as const)('with %s nothing is written: no marker, no audit row, the header as it was', async (_why, args, stored, outcome) => {
      await r.store.updateGroup('g1', (c) => ({ ...c, ...stored, rev: c.rev }));
      const before = (await r.store.getGroup('g1'))!;
      const out = await r.store.commitGroup('g1', commitArgs({ rev: before.rev, ...args }));
      expect(out).toEqual({ outcome, header: before });
      expect(await r.store.getGroup('g1')).toEqual(before);
      expect(before.committed_at).toBeUndefined();
      expect(await actions(r, 'grp#g1')).toEqual(['group_create']);
    });

    test('the deadline itself is still in time', async () => {
      expect(await r.store.commitGroup('g1', commitArgs({ now: '2026-10-14T20:00:00Z' }))).toMatchObject({ outcome: 'committed' });
    });

    test('a group that does not exist is missing, and nothing is written', async () => {
      expect(await r.store.commitGroup('nope', commitArgs())).toEqual({ outcome: 'missing' });
      expect(await r.store.getGroup('nope')).toBeUndefined();
      expect(await actions(r, 'grp#nope')).toEqual([]);
    });

    test('a second commit finds the marker and writes nothing: same header, no second audit row', async () => {
      const first = await r.store.commitGroup('g1', commitArgs());
      const second = await r.store.commitGroup('g1', commitArgs({ now: '2026-10-14T10:00:00Z', writeOrder: [0, 1] }));
      expect(second).toEqual({ outcome: 'already', header: (first as { header: GroupRecord }).header });
      expect((await r.store.getGroup('g1'))!.committed_at).toBe(COMMITTED_AT);
      expect(await actions(r, 'grp#g1')).toEqual(['group_create', 'group_commit']);
    });

    test('two commits at once: exactly one writes the marker, the other reports it', async () => {
      const outs = await Promise.all([r.store.commitGroup('g1', commitArgs()), r.store.commitGroup('g1', commitArgs())]);
      expect(outs.map((o) => o.outcome).sort()).toEqual(['already', 'committed']);
      expect(await actions(r, 'grp#g1')).toEqual(['group_create', 'group_commit']);
      expect((await r.store.getGroup('g1'))!.rev).toBe(1);
    });
  });

  describe('adopting a number', () => {
    const noCall = () => {
      throw new Error('free must not be asked');
    };

    test('a free number is created: pending, named by the group, with one audit row', async () => {
      const out = await r.store.adoptVersion(reserved('p', 'g1'), audit('p', 'group_reserve', '1.0.0'), noCall);
      expect(out).toEqual({ outcome: 'created', record: reserved('p', 'g1') });
      expect(await raw(r)).toEqual(reserved('p', 'g1'));
      expect(await actions(r, 'p')).toEqual(['group_reserve']);
    });

    test('the row of a dead group is taken over when the caller says it is free: the new reservation, one revision on, no stamp of the old attempt', async () => {
      r.writeRow(staged('p', 'g0', 1, { rev: 3 }));
      const seen: VersionRecord[] = [];
      const out = await r.store.adoptVersion(reserved('p', 'g1'), audit('p', 'group_adopt', '1.0.0'), (cur) => {
        seen.push(cur);
        return true;
      });
      const want = { ...reserved('p', 'g1'), rev: 4 };
      expect(out).toEqual({ outcome: 'adopted', record: want });
      expect(await raw(r)).toEqual(want);
      expect(await raw(r)).not.toHaveProperty('staged_attempt');
      expect(seen.map((s) => [s.group_id, s.staged_attempt, s.rev])).toEqual([['g0', 1, 3]]);
      expect(await actions(r, 'p')).toEqual(['group_adopt']);
    });

    test('a row the caller does not call free stays as it was', async () => {
      r.writeRow(staged('p', 'g0', 1, { rev: 3 }));
      const out = await r.store.adoptVersion(reserved('p', 'g1'), audit('p', 'group_adopt', '1.0.0'), () => false);
      expect(out).toEqual({ outcome: 'taken', existing: staged('p', 'g0', 1, { rev: 3 }) });
      expect(await raw(r)).toEqual(staged('p', 'g0', 1, { rev: 3 }));
      expect(await actions(r, 'p')).toEqual([]);
    });

    test.each(['published', 'yanked', 'tombstoned'] as const)('a %s row is never adopted, whatever the caller would answer, and the caller is not asked', async (state) => {
      const row = rec({ name: 'p', version: '1.0.0', state, group_id: 'g0', staged_attempt: 1, rev: 5, ...(state === 'yanked' ? { yank_reason: 'x' } : {}) });
      r.writeRow(row);
      expect(await r.store.adoptVersion(reserved('p', 'g1'), audit('p', 'group_adopt', '1.0.0'), noCall)).toEqual({ outcome: 'taken', existing: row });
      expect(await raw(r)).toEqual(row);
    });

    test('only a pending row that names a group can be adopted', async () => {
      await expect(r.store.adoptVersion(rec({ name: 'p', version: '1.0.0' }), audit('p', 'x'), noCall)).rejects.toThrow(/pending row that names a group/);
      await expect(r.store.adoptVersion(rec({ name: 'p', version: '1.0.0', state: 'pending' }), audit('p', 'x'), noCall)).rejects.toThrow(/pending row that names a group/);
      expect(await raw(r)).toBeUndefined();
    });
  });

  describe('the stage event', () => {
    beforeEach(() => {
      r.writeRow(reserved('p', 'g1'));
    });

    test('fills a reserved member and stamps the attempt in one write: still pending, one revision on, one audit row', async () => {
      const out = await r.store.applyGroupEvent('p', '1.0.0', stage('g1', 1), audit('p', 'group_stage', '1.0.0'));
      expect(out).toEqual({ ...reserved('p', 'g1'), ...fill('p'), staged_attempt: 1, rev: 1 });
      expect(out.state).toBe('pending');
      expect(await raw(r)).toEqual(out);
      expect(await actions(r, 'p')).toEqual(['group_stage']);
    });

    test('a redelivered stage is a no-op: the same row, the same revision, no second audit row', async () => {
      const first = await r.store.applyGroupEvent('p', '1.0.0', stage('g1', 1), audit('p', 'group_stage', '1.0.0'));
      const again = await r.store.applyGroupEvent('p', '1.0.0', stage('g1', 1), audit('p', 'group_stage', '1.0.0'));
      expect(again).toEqual(first);
      expect(await raw(r)).toEqual(first);
      expect(await actions(r, 'p')).toEqual(['group_stage']);
    });

    test('two deliveries at once write once', async () => {
      const outs = await Promise.all([1, 2, 3].map(() => r.store.applyGroupEvent('p', '1.0.0', stage('g1', 1), audit('p', 'group_stage', '1.0.0'))));
      expect(outs.map((o) => o.rev)).toEqual([1, 1, 1]);
      expect(await actions(r, 'p')).toEqual(['group_stage']);
    });

    test('a stage that arrives after the commit changes nothing', async () => {
      await r.store.applyGroupEvent('p', '1.0.0', stage('g1', 1), audit('p', 'group_stage', '1.0.0'));
      r.putGroupItem(headerKey('g1'), header());
      r.putGroupItem('grpm#g1', memberList('p'));
      const before = await raw(r);
      await r.store.applyGroupEvent('p', '1.0.0', stage('g1', 1), audit('p', 'group_stage', '1.0.0'));
      expect(await raw(r)).toEqual(before);
      expect((await r.store.getVersion('p', '1.0.0'))!.state).toBe('published');
    });

    test('refuses a row of another group, a row of no group, and a row that is not pending: the row is not changed and no audit row is written', async () => {
      r.writeRow(rec({ name: 'single', version: '1.0.0', state: 'pending' }));
      r.writeRow(flipped('done', 'g1'));
      for (const [name, group_id] of [['p', 'g2'], ['single', 'g1']] as const) {
        const before = await raw(r, name);
        await expect(r.store.applyGroupEvent(name, '1.0.0', stage(group_id, 1, name), audit(name, 'group_stage', '1.0.0'))).rejects.toMatchObject({ code: 'invalid_transition', status: 409 });
        await expect(r.store.applyGroupEvent(name, '1.0.0', stage(group_id, 1, name), audit(name, 'group_stage', '1.0.0'))).rejects.toBeInstanceOf(WrongGroup);
        expect(await raw(r, name)).toEqual(before);
        expect(await actions(r, name)).toEqual([]);
      }
      await expect(r.store.applyGroupEvent('done', '1.0.0', stage('g1', 1, 'done'), audit('done', 'group_stage', '1.0.0'))).rejects.toMatchObject({ code: 'invalid_transition' });
      expect(await raw(r, 'done')).toEqual(flipped('done', 'g1'));
    });

    test('a newer attempt overwrites an older stamp, and a stage of an older attempt is refused', async () => {
      await r.store.applyGroupEvent('p', '1.0.0', stage('g1', 1), audit('p', 'group_stage', '1.0.0'));
      const two = await r.store.applyGroupEvent('p', '1.0.0', stage('g1', 2), audit('p', 'group_stage', '1.0.0'));
      expect([two.staged_attempt, two.rev]).toEqual([2, 2]);
      await expect(r.store.applyGroupEvent('p', '1.0.0', stage('g1', 1), audit('p', 'group_stage', '1.0.0'))).rejects.toMatchObject({ code: 'invalid_transition' });
      expect(await raw(r)).toEqual(two);
    });

    test('a number that does not exist is version_not_found', async () => {
      await expect(r.store.applyGroupEvent('nope', '1.0.0', stage('g1', 1), audit('nope', 'x'))).rejects.toMatchObject({ code: 'version_not_found' });
    });
  });

  describe('the group_publish event (the flip)', () => {
    test('publishes a pending member that carries the attempt, at the commit time, keeping group_id and the stamp; a redelivery changes nothing', async () => {
      r.writeRow(staged('p', 'g1', 1, { rev: 1 }));
      const out = await r.store.applyGroupEvent('p', '1.0.0', flip('g1', 1), audit('p', 'group_publish', '1.0.0'));
      expect(out).toEqual({ ...staged('p', 'g1', 1, { rev: 1 }), state: 'published', published_at: COMMITTED_AT, rev: 2 });
      expect(await raw(r)).toEqual(out);
      expect(await r.store.applyGroupEvent('p', '1.0.0', flip('g1', 1), audit('p', 'group_publish', '1.0.0'))).toEqual(out);
      expect(await actions(r, 'p')).toEqual(['group_publish']);
    });

    test('refuses a pending member that is not stamped with the attempt, and a member of another group', async () => {
      r.writeRow(reserved('p', 'g1'));
      r.writeRow(staged('q', 'g1', 2));
      r.writeRow(staged('o', 'g2', 1));
      for (const name of ['p', 'q']) {
        const before = await raw(r, name);
        await expect(r.store.applyGroupEvent(name, '1.0.0', flip('g1', 1), audit(name, 'group_publish', '1.0.0'))).rejects.toMatchObject({ code: 'invalid_transition' });
        expect(await raw(r, name)).toEqual(before);
      }
      await expect(r.store.applyGroupEvent('o', '1.0.0', flip('g1', 1), audit('o', 'group_publish', '1.0.0'))).rejects.toBeInstanceOf(WrongGroup);
      expect(await raw(r, 'o')).toEqual(staged('o', 'g2', 1));
    });

    test.each(['yanked', 'tombstoned', 'published'] as const)('never unyanks: a %s member is left as it is, without a write or an audit row', async (state) => {
      const row = rec({
        name: 'p',
        version: '1.0.0',
        state,
        group_id: 'g1',
        staged_attempt: 1,
        rev: 4,
        ...(state === 'yanked' ? { yank_reason: 'broken' } : {}),
        ...(state === 'tombstoned' ? { tombstone: { reason_code: 'malware', date: '2026-10-13' } } : {}),
      });
      r.writeRow(row);
      expect(await r.store.applyGroupEvent('p', '1.0.0', flip('g1', 1), audit('p', 'group_publish', '1.0.0'))).toEqual(row);
      expect(await raw(r)).toEqual(row);
      expect(await actions(r, 'p')).toEqual([]);
    });
  });

  describe('a member of a committed group that is yanked before its flip', () => {
    test('the yank writes a full yanked row that keeps group_id and staged_attempt; the flip then leaves it yanked; an unyank restores it published, still in its group', async () => {
      seedGroup(r, 'g1', header(), ['p'], [staged('p', 'g1', 1, { rev: 1 })]);
      const y = await r.store.updateVersion('p', '1.0.0', { type: 'yank', reason: 'broken' }, audit('p', 'yank', '1.0.0'));
      expect(y).toMatchObject({ state: 'yanked', yank_reason: 'broken', group_id: 'g1', staged_attempt: 1, rev: 2, published_at: COMMITTED_AT });
      expect(await raw(r)).toEqual(y);

      expect(await r.store.applyGroupEvent('p', '1.0.0', flip('g1', 1), audit('p', 'group_publish', '1.0.0'))).toEqual(y);
      expect(await raw(r)).toEqual(y);
      expect((await r.store.getVersion('p', '1.0.0'))!.state).toBe('yanked');

      const u = await r.store.updateVersion('p', '1.0.0', { type: 'unyank' }, audit('p', 'unyank', '1.0.0'));
      expect(u).toMatchObject({ state: 'published', group_id: 'g1', staged_attempt: 1, rev: 3 });
      expect(u).not.toHaveProperty('yank_reason');
      expect(await actions(r, 'p')).toEqual(['yank', 'unyank']);
    });

    test('a flipped member yanked later keeps its group_id too', async () => {
      seedGroup(r, 'g1', header({ status: 'visible' }), ['p'], [flipped('p', 'g1')]);
      const y = await r.store.updateVersion('p', '1.0.0', { type: 'yank', reason: 'late' }, audit('p', 'yank', '1.0.0'));
      expect(y).toMatchObject({ state: 'yanked', group_id: 'g1', staged_attempt: 1 });
      expect(await raw(r)).toEqual(y);
    });
  });

  test('a member stays hidden until the commit and shows after it, before and after its flip, through the readers of the store', async () => {
    const s = r.store;
    await s.createGroup(group({ status: 'open' }), memberList('a', 'b'), gaudit('group_create'));
    for (const n of ['a', 'b']) expect((await s.adoptVersion(reserved(n, 'g1'), audit(n, 'group_reserve', '1.0.0'), () => false)).outcome).toBe('created');
    const seen = async () => ({ one: (await s.getVersion('a', '1.0.0'))!.state, list: (await s.listVersions('b')).map((v) => v.state) });

    expect(await seen()).toEqual({ one: 'pending', list: ['pending'] });
    for (const n of ['a', 'b']) await s.applyGroupEvent(n, '1.0.0', stage('g1', 1, n), audit(n, 'group_stage', '1.0.0'));
    expect(await seen()).toEqual({ one: 'pending', list: ['pending'] });
    await s.updateGroup('g1', (c) => ({ ...c, status: 'validating' }));
    expect(await seen()).toEqual({ one: 'pending', list: ['pending'] });

    const cur = (await s.getGroup('g1'))!;
    expect(await s.commitGroup('g1', commitArgs({ rev: cur.rev, writeOrder: [0, 1] }))).toMatchObject({ outcome: 'committed' });
    expect(await seen()).toEqual({ one: 'published', list: ['published'] });
    expect((await s.getVersion('a', '1.0.0'))!.published_at).toBe(COMMITTED_AT);
    expect((await raw(r, 'a'))!.state).toBe('pending'); // the stored form, until the flip

    // The builders wait for the group's release gates.
    const builds = async () => [...(await s.versionsOf(['a', 'b'], repodataView('linux-64'))).values()].flat().map((v) => v.state);
    expect(await builds()).toEqual(['pending', 'pending']);
    await s.updateGroup('g1', (c) => ({ ...c, repodata_released: ['linux-64'] }));
    expect(await builds()).toEqual(['published', 'published']);

    for (const n of ['a', 'b']) await s.applyGroupEvent(n, '1.0.0', flip('g1', 1), audit(n, 'group_publish', '1.0.0'));
    expect((await raw(r, 'a'))!.state).toBe('published');
    await s.updateGroup('g1', (c) => ({ ...c, status: 'visible' }));
    expect(await seen()).toEqual({ one: 'published', list: ['published'] });
    expect((await raw(r, 'a'))!.published_at).toBe(COMMITTED_AT);
  });
});

describe('the DynamoDB adapter sends only what the roles are granted', () => {
  const allowed = new Set(['GetCommand', 'PutCommand', 'TransactWriteCommand', 'QueryCommand']);

  test('a whole group lifecycle uses Get, Put and TransactWrite of Puts: no UpdateItem, no DeleteItem, no ConditionCheck, no Scan', async () => {
    const r = dynamoRig();
    const s = r.store;
    const doc = r.doc!;
    await s.createGroup(group({ status: 'open' }), memberList('p'), gaudit('group_create'));
    await s.adoptVersion(reserved('p', 'g1'), audit('p', 'group_reserve', '1.0.0'), () => true);
    await s.adoptVersion(reserved('p', 'g1'), audit('p', 'group_adopt', '1.0.0'), () => true);
    await s.applyGroupEvent('p', '1.0.0', stage('g1', 1), audit('p', 'group_stage', '1.0.0'));
    await s.updateGroup('g1', (c) => ({ ...c, status: 'validating' }), gaudit('group_validate'));
    await s.updateGroup('g1', (c) => ({ ...c, staged: bitmapSet(c.staged, 0) }));
    await s.commitGroup('g1', commitArgs({ rev: 2 }));
    await s.getVersion('p', '1.0.0');
    await s.applyGroupEvent('p', '1.0.0', flip('g1', 1), audit('p', 'group_publish', '1.0.0'));
    await s.updateVersion('p', '1.0.0', { type: 'yank', reason: 'x' }, audit('p', 'yank', '1.0.0'));

    expect([...new Set(doc.calls)].filter((c) => !allowed.has(c))).toEqual([]);
    expect(doc.calls).toEqual(expect.arrayContaining(['GetCommand', 'PutCommand', 'TransactWriteCommand']));
    const txItems = doc.inputs.flatMap((i) => (i.TransactItems ?? []) as Array<Record<string, unknown>>);
    expect(txItems.length).toBeGreaterThan(6);
    expect(new Set(txItems.flatMap((i) => Object.keys(i)))).toEqual(new Set(['Put']));
  });

  test('the group items go to the publishes table and the audit rows to the audit table; the commit is a transaction of exactly those two Puts', async () => {
    const r = dynamoRig();
    await r.store.createGroup(group(), memberList('p'), gaudit('group_create'));
    await r.store.commitGroup('g1', commitArgs());
    const tx = r.doc!.inputs.filter((i) => i.TransactItems);
    expect(tx.map((t) => t.TransactItems.map((i: { Put: { TableName: string } }) => i.Put.TableName))).toEqual([
      ['mopm-t-publishes', 'mopm-t-audit'],
      ['mopm-t-publishes', 'mopm-t-audit'],
    ]);
    expect([...r.doc!.tables.get('mopm-t-publishes')!.keys()].sort()).toEqual(['grp#g1\u0000', 'grpm#g1\u0000']);
    expect([...r.doc!.tables.get('mopm-t-audit')!.values()].map((a) => a.name)).toEqual(['grp#g1', 'grp#g1']);
  });

  test('the member list is written before the header', async () => {
    const r = dynamoRig();
    await r.store.createGroup(group(), memberList('p'), gaudit('group_create'));
    const writes = r.doc!.inputs.filter((i) => i.Item || i.TransactItems);
    expect(writes[0].Item.publish_id).toBe('grpm#g1');
    expect(writes[1].TransactItems[0].Put.Item.publish_id).toBe('grp#g1');
  });
});

describe('adopting a number on DynamoDB', () => {
  test('a row that changes between the read and the takeover is lost: the takeover writes nothing, and the other writer\'s row stands', async () => {
    const r = dynamoRig();
    r.writeRow(staged('p', 'g0', 1, { rev: 3 }));
    const out = await r.store.adoptVersion(reserved('p', 'g1'), audit('p', 'group_adopt', '1.0.0'), (cur) => {
      r.writeRow({ ...cur, rev: cur.rev + 1 }); // another writer gets in after the read
      return true;
    });
    expect(out).toEqual({ outcome: 'lost' });
    expect(await raw(r)).toEqual(staged('p', 'g0', 1, { rev: 4 }));
    expect(await actions(r, 'p')).toEqual([]);
  });
});

describe('the commit on DynamoDB', () => {
  const commitSends = (r: Rig) => r.doc!.inputs.filter((i) => i.TransactItems?.[0]?.Put?.Item?.publish_id === 'grp#g1' && i.TransactItems[0].Put.Item.committed_at !== undefined);

  test('sends the hashed token: the first 32 hex characters of sha256 of commit|group|attempt, within the 36 DynamoDB allows', async () => {
    const r = dynamoRig();
    await r.store.createGroup(group({ attempt: 3 }), memberList('p'), gaudit('group_create'));
    await r.store.commitGroup('g1', commitArgs());
    const sent = commitSends(r);
    expect(sent).toHaveLength(1);
    const want = createHash('sha256').update('commit|g1|3').digest('hex').slice(0, 32);
    expect(sent[0].ClientRequestToken).toBe(want);
    expect(want).toMatch(/^[0-9a-f]{32}$/);
    expect(commitToken('g1', 3)).toBe(want);
    expect(commitToken('g1', 4)).not.toBe(want);
    expect(commitToken('g2', 3)).not.toBe(want);
  });

  test('the condition is the status and the revision the caller read, and nothing else', async () => {
    const r = dynamoRig();
    await r.store.createGroup(group(), memberList('p'), gaudit('group_create'));
    await r.store.commitGroup('g1', commitArgs());
    const put = commitSends(r)[0].TransactItems[0].Put;
    expect(put.ConditionExpression).toBe('#s = :s AND #r = :r');
    expect(put.ExpressionAttributeValues).toEqual({ ':s': 'validating', ':r': 0 });
  });

  test('a commit whose answer was lost is found by the retry, which reads the marker and sends nothing', async () => {
    const r = dynamoRig();
    await r.store.createGroup(group(), memberList('p'), gaudit('group_create'));
    const doc = r.doc!;
    const send = doc.send.bind(doc);
    let lose = true;
    doc.send = async (cmd: unknown) => {
      const out = await send(cmd);
      if (lose && cmd instanceof TransactWriteCommand && cmd.input.TransactItems?.[0]?.Put?.Item?.committed_at !== undefined) {
        lose = false;
        throw Object.assign(new Error('socket hang up'), { name: 'TimeoutError' });
      }
      return out;
    };
    await expect(r.store.commitGroup('g1', commitArgs())).rejects.toThrow('socket hang up');
    expect((await r.store.getGroup('g1'))!.committed_at).toBe(COMMITTED_AT); // it did happen
    const sentBefore = doc.calls.filter((c) => c === 'TransactWriteCommand').length;

    const retry = await r.store.commitGroup('g1', commitArgs());
    expect(retry).toMatchObject({ outcome: 'already', header: { committed_at: COMMITTED_AT, rev: 1 } });
    expect(doc.calls.filter((c) => c === 'TransactWriteCommand').length).toBe(sentBefore);
    expect(await actions(r, 'grp#g1')).toEqual(['group_create', 'group_commit']);
  });

  test('a header changed between the read and the write is a conflict, nothing is committed, and the new header is returned', async () => {
    const r = dynamoRig();
    await r.store.createGroup(group(), memberList('p'), gaudit('group_create'));
    const doc = r.doc!;
    const send = doc.send.bind(doc);
    let once = true;
    doc.send = async (cmd: unknown) => {
      if (once && cmd instanceof TransactWriteCommand) {
        once = false;
        await r.store.updateGroup('g1', (c) => ({ ...c, resend: c.resend + 1 }));
      }
      return send(cmd);
    };
    const out = await r.store.commitGroup('g1', commitArgs());
    expect(out).toMatchObject({ outcome: 'conflict', header: { rev: 1, resend: 1 } });
    expect((await r.store.getGroup('g1'))!.committed_at).toBeUndefined();
    expect(await actions(r, 'grp#g1')).toEqual(['group_create']);
  });

  test('an audit row that cannot be written stops the whole commit: the transaction is cancelled at the audit item, that is raised, and there is no marker', async () => {
    const r = dynamoRig();
    await r.store.createGroup(group(), memberList('p'), gaudit('group_create'));
    const taken = gaudit('group_commit');
    await r.store.appendAudit(taken);
    await expect(r.store.commitGroup('g1', { ...commitArgs(), audit: taken })).rejects.toMatchObject({ name: 'TransactionCanceledException' });
    const after = (await r.store.getGroup('g1'))!;
    expect([after.committed_at, after.status, after.rev]).toEqual([undefined, 'validating', 0]);
  });

  test('at 500 members, with the longest free text in the header, the transaction is a few KB and the member list a fraction of the item limit', async () => {
    const r = dynamoRig();
    const N = 500;
    const members = Array.from({ length: N }, (_, i) => ({ name: `p${String(i).padStart(3, '0')}`.padEnd(64, 'x'), version: '1.0.0', canonical: '1.0.0', subdirs: ['linux-64', 'noarch'] }));
    let full = '';
    for (let i = 0; i < N; i++) full = bitmapSet(full, i);
    // What the header holds at the commit: every member reserved, validated, staged and copied; nothing flipped or released yet.
    const g = group({ group_id: 'a'.repeat(32), member_count: N, actor: 'x'.repeat(500), reserved: full, validated: full, staged: full, copied: full });
    await r.store.createGroup(g, { members }, audit(headerKey(g.group_id), 'group_create'));
    const order = Array.from({ length: N }, (_, i) => N - 1 - i);
    const out = await r.store.commitGroup(g.group_id, { rev: 0, writeOrder: order, now: COMMITTED_AT, audit: audit(headerKey(g.group_id), 'group_commit') });
    expect(out).toMatchObject({ outcome: 'committed' });

    const sent = r.doc!.inputs.filter((i) => i.TransactItems && i.ClientRequestToken && i.TransactItems[0].Put.Item.committed_at !== undefined);
    expect(sent).toHaveLength(1);
    expect(sent[0].TransactItems).toHaveLength(2);
    // Bytes on the wire: the DynamoDB JSON of the items (what the 4 MB transaction limit counts).
    const wire = sent[0].TransactItems.map((i: { Put: { Item: Record<string, unknown> } }) => Buffer.byteLength(JSON.stringify(marshall(i.Put.Item, { removeUndefinedValues: true }))));
    expect(wire[0]).toBeLessThan(12_000);
    expect(wire[1]).toBeLessThan(1_000);
    expect(JSON.stringify(sent[0]).length).toBeLessThan(8_000);
    // The member names are in the member list, not in the commit.
    expect(JSON.stringify(sent[0])).not.toContain('p000xxxx');
    // The member list is its own item, written once: far below the 400 KB item limit.
    const list = r.doc!.tables.get('mopm-t-publishes')!.get(`grpm#${g.group_id}\u0000`)!;
    expect(JSON.stringify(list)).toContain('p000xxxx');
    expect(Buffer.byteLength(JSON.stringify(marshall(list)))).toBeLessThan(200_000);
    expect(bitmapIndexes((await r.store.getGroup(g.group_id))!.staged)).toHaveLength(N);
  });
});

describe('errors that are not a lost race are raised, not swallowed (DynamoDB)', () => {
  const boom = Object.assign(new Error('boom'), { name: 'InternalServerError' });
  const failing = (r: Rig, which: (cmd: unknown, n: number) => boolean) => {
    const doc = r.doc!;
    const send = doc.send.bind(doc);
    let n = 0;
    doc.send = async (cmd: unknown) => {
      if ((cmd instanceof PutCommand || cmd instanceof TransactWriteCommand) && which(cmd, ++n)) throw boom;
      return send(cmd);
    };
  };

  test('createGroup: the member list write and the header transaction', async () => {
    const a = dynamoRig();
    failing(a, (c) => c instanceof PutCommand);
    await expect(a.store.createGroup(group(), memberList('p'), gaudit('x'))).rejects.toBe(boom);
    const b = dynamoRig();
    failing(b, (c) => c instanceof TransactWriteCommand);
    await expect(b.store.createGroup(group(), memberList('p'), gaudit('x'))).rejects.toBe(boom);
  });

  test('updateGroup: the plain write and the transaction', async () => {
    const a = dynamoRig();
    await a.store.createGroup(group(), memberList('p'), gaudit('x'));
    failing(a, (c) => c instanceof PutCommand);
    await expect(a.store.updateGroup('g1', (c) => ({ ...c, resend: 1 }))).rejects.toBe(boom);
    const b = dynamoRig();
    await b.store.createGroup(group(), memberList('p'), gaudit('x'));
    failing(b, (c) => c instanceof TransactWriteCommand);
    await expect(b.store.updateGroup('g1', (c) => ({ ...c, resend: 1 }), gaudit('y'))).rejects.toBe(boom);
  });

  test('commitGroup: a transaction that fails for another reason', async () => {
    const r = dynamoRig();
    await r.store.createGroup(group(), memberList('p'), gaudit('x'));
    failing(r, (c) => c instanceof TransactWriteCommand);
    await expect(r.store.commitGroup('g1', commitArgs())).rejects.toBe(boom);
  });

  test('adoptVersion: the create, and the takeover after a create that found the row', async () => {
    const a = dynamoRig();
    failing(a, () => true);
    await expect(a.store.adoptVersion(reserved('p', 'g1'), audit('p', 'x', '1.0.0'), () => true)).rejects.toBe(boom);
    const b = dynamoRig();
    b.writeRow(staged('p', 'g0'));
    failing(b, (_c, n) => n === 2);
    await expect(b.store.adoptVersion(reserved('p', 'g1'), audit('p', 'x', '1.0.0'), () => true)).rejects.toBe(boom);
  });

  test('a header that keeps changing under an update is given up on, and nothing is written', async () => {
    const r = dynamoRig();
    await r.store.createGroup(group(), memberList('p'), gaudit('x'));
    const doc = r.doc!;
    const send = doc.send.bind(doc);
    doc.send = async (cmd: unknown) => {
      if (cmd instanceof PutCommand) throw Object.assign(new Error('The conditional request failed'), { name: 'ConditionalCheckFailedException' });
      if (cmd instanceof TransactWriteCommand) throw Object.assign(new Error('cancelled'), { name: 'TransactionCanceledException', CancellationReasons: [{ Code: 'ConditionalCheckFailed' }, { Code: 'None' }] });
      return send(cmd);
    };
    await expect(r.store.updateGroup('g1', (c) => ({ ...c, resend: 1 }))).rejects.toMatchObject({ code: 'internal_error' });
    await expect(r.store.updateGroup('g1', (c) => ({ ...c, resend: 1 }), gaudit('y'))).rejects.toMatchObject({ code: 'internal_error' });
    expect((await r.store.getGroup('g1'))!.rev).toBe(0);
  });

  test('reads of group items are consistent', async () => {
    const r = dynamoRig();
    await r.store.createGroup(group(), memberList('p'), gaudit('x'));
    await r.store.getGroup('g1');
    await r.store.getGroupMembers('g1');
    const gets = r.doc!.inputs.filter((i) => i.Key?.publish_id);
    expect(gets.length).toBe(2);
    expect(gets.every((g) => g.ConsistentRead === true && g.TableName === 'mopm-t-publishes')).toBe(true);
    expect(r.doc!.calls.filter((c) => c === 'GetCommand').length).toBe(2);
  });
});

describe('pure parts', () => {
  test('bitmaps hold member indexes, four to a character, lowest first; a missing character is zero', () => {
    expect(bitmapSet('', 0)).toBe('1');
    expect(bitmapSet('1', 1)).toBe('3');
    expect(bitmapSet('', 4)).toBe('01');
    let b = '';
    for (const i of [0, 3, 4, 9, 500, 3]) b = bitmapSet(b, i);
    expect(bitmapIndexes(b)).toEqual([0, 3, 4, 9, 500]);
    expect(b).toHaveLength(126);
    expect([0, 3, 4, 9, 500].every((i) => bitmapHas(b, i))).toBe(true);
    expect([1, 2, 5, 8, 499, 501, 5000].some((i) => bitmapHas(b, i))).toBe(false);
    expect(bitmapIndexes('')).toEqual([]);
  });

  test('the header item is the record under the publishes key, without undefined members, and reads back as the record', () => {
    const g = group({ committed_at: undefined });
    const item = groupItem(g);
    expect(item.publish_id).toBe('grp#g1');
    expect('committed_at' in item).toBe(false);
    expect(parseGroupRecord(item)).toEqual(group());
  });

  test('a member audit id is deterministic', () => {
    expect(memberAuditId('g1', 7)).toBe('a_g1_7');
  });

  test('applyEvent applies the group events by their own rules: the flip needs the attempt, a row of another group or of none is refused', () => {
    const row = staged('p', 'g1', 1);
    expect(applyEvent(row, flip('g1', 1))).toMatchObject({ state: 'published', rev: row.rev + 1 });
    expect(() => applyEvent(row, flip('g2', 1))).toThrow(WrongGroup);
    expect(() => applyEvent(rec({ name: 'p', version: '1.0.0', state: 'pending' }), stage('g1', 1))).toThrow(WrongGroup);
    expect(() => applyEvent(row, flip('g1', 2))).toThrow(/Cannot group_publish/);
  });
});

describe.each(RIGS)('deadlines and single takeovers: %s', (_label, make) => {
  let r: Rig;
  beforeEach(() => {
    r = make();
  });

  test.each(['', 'soon', 'NaN', '2026-13-45T99:00:00Z', 'tomorrow at noon'])('a header whose deadline_at is %j (not a time) is refused at create, with nothing written', async (deadline) => {
    await expect(r.store.createGroup(group({ status: 'open', deadline_at: deadline }), memberList('p'), gaudit('x'))).rejects.toThrow(/is not a time/);
    expect(await r.store.getGroup('g1')).toBeUndefined();
    expect(await r.store.getGroupMembers('g1')).toBeUndefined();
    expect(await actions(r, 'grp#g1')).toEqual([]);
  });

  test('an update cannot give a header a deadline that is not a time either: the header stays as it was', async () => {
    await r.store.createGroup(group({ status: 'open' }), memberList('p'), gaudit('x'));
    await expect(r.store.updateGroup('g1', (c) => ({ ...c, deadline_at: 'soon' }))).rejects.toThrow(/is not a time/);
    expect(await r.store.getGroup('g1')).toEqual(group({ status: 'open' }));
  });

  test('the commit refuses a group whose stored deadline is not a time (it is past, not never), commits at the deadline itself and refuses after it', async () => {
    r.putGroupItem(headerKey('g1'), groupItem(group({ status: 'validating', deadline_at: 'soon' })));
    expect(await r.store.commitGroup('g1', commitArgs())).toMatchObject({ outcome: 'deadline' });
    expect((await r.store.getGroup('g1'))!.committed_at).toBeUndefined();

    r.putGroupItem(headerKey('g1'), groupItem(group({ status: 'validating', deadline_at: COMMITTED_AT })));
    expect(await r.store.commitGroup('g1', commitArgs({ now: '2026-10-14T09:00:00.001Z' }))).toMatchObject({ outcome: 'deadline' });
    expect(await r.store.commitGroup('g1', commitArgs({ now: COMMITTED_AT }))).toMatchObject({ outcome: 'committed' });
  });

  test('adoptSingle: creates a reservation where there is none, takes a free pending row one revision on (the stored row names no group), and leaves a row that is not free', async () => {
    const single = (over: Partial<VersionRecord> = {}) => rec({ name: 'p', version: '1.0.0', state: 'pending', files: [], build: '', requires_mojo: '', ...over });
    const a = audit('p', 'publish_adopt', '1.0.0');
    expect((await r.store.adoptSingle(single(), a, () => true)).outcome).toBe('created');
    expect(await raw(r)).toMatchObject({ state: 'pending', rev: 0 });

    r.writeRow(reserved('p', 'g1'));
    const taken = await r.store.adoptSingle(single(), audit('p', 'publish_adopt', '1.0.0'), () => false);
    expect(taken).toMatchObject({ outcome: 'taken', existing: { group_id: 'g1' } });
    expect(await raw(r)).toMatchObject({ group_id: 'g1', rev: 0 });

    const adopted = await r.store.adoptSingle(single({ published_by: 'octocat' }), audit('p', 'publish_adopt', '1.0.0'), (cur) => cur.group_id === 'g1');
    expect(adopted).toMatchObject({ outcome: 'adopted', record: { rev: 1, published_by: 'octocat' } });
    const stored = (await raw(r))!;
    expect(stored.group_id).toBeUndefined();
    expect(stored).toMatchObject({ state: 'pending', rev: 1, published_by: 'octocat' });

    r.writeRow(rec({ name: 'p', version: '1.0.0', state: 'published', rev: 5 }));
    expect(await r.store.adoptSingle(single(), audit('p', 'publish_adopt', '1.0.0'), () => true)).toMatchObject({ outcome: 'taken', existing: { state: 'published' } });
    expect(await raw(r)).toMatchObject({ state: 'published', rev: 5 });
  });

  test('adoptSingle takes a row that names no group, and adoptVersion one that does: each refuses the other\'s', async () => {
    await expect(r.store.adoptSingle(reserved('p', 'g1'), audit('p', 'x', '1.0.0'), () => true)).rejects.toThrow(/names no group/);
    await expect(r.store.adoptSingle(rec({ name: 'p', version: '1.0.0', state: 'published' }), audit('p', 'x', '1.0.0'), () => true)).rejects.toThrow(/names no group/);
    await expect(r.store.adoptVersion(rec({ name: 'p', version: '1.0.0', state: 'pending' }), audit('p', 'x', '1.0.0'), () => true)).rejects.toThrow(/names a group/);
  });

  test('adoptSingle loses a race for the row cleanly (DynamoDB: the revision moved between the read and the write)', async () => {
    if (!r.doc) return;
    r.writeRow(reserved('p', 'g1'));
    const out = await r.store.adoptSingle(rec({ name: 'p', version: '1.0.0', state: 'pending', files: [], build: '', requires_mojo: '' }), audit('p', 'publish_adopt', '1.0.0'), (cur) => {
      r.writeRow({ ...cur, rev: cur.rev + 1 });
      return true;
    });
    expect(out).toEqual({ outcome: 'lost' });
    expect(await raw(r)).toMatchObject({ group_id: 'g1', rev: 1 });
    expect(await actions(r, 'p')).toEqual([]);
  });
});
