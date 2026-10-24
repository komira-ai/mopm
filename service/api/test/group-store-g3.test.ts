import { headerKey } from '../src/group';
import { commitInputKey, commitRequestHash, type GroupRecord } from '../src/group-store';
import { applyEvent, WrongGroup, type GroupEvent, type PublishFill } from '../src/state';
import { audit, rec } from './helpers';
import { COMMITTED_AT, memberList, RIGS, reserved, staged, type Rig } from './group-rig';

/**
 * What the group's validator and sweeper added to the writers of a group (src/group-store.ts): the commit inputs, the
 * sweeper's index, the member list that follows its header's expiry, and the event that burns a failed group's numbers.
 * Both adapters. Each test names what it proves.
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
  sweep_pk: 'active',
  sweep_at: '2026-10-14T08:30:00Z',
  ...over,
});
const gaudit = (action: string, gid = 'g1') => audit(headerKey(gid), action);
const fill = (name: string): PublishFill => {
  const r = rec({ name, version: '1.0.0' });
  return { version: r.version, build: r.build, requires_mojo: r.requires_mojo, deps: r.deps, native: r.native, files: r.files, manifest_sha256: r.manifest_sha256, published_at: r.published_at };
};
const burn = (gid: string, code = 'sha256_mismatch'): GroupEvent => ({ type: 'group_burn', group_id: gid, reason_code: code, date: '2026-10-14' });

describe('the burn event', () => {
  test('tombstones a pending member, with nothing of its files kept and its time cleared', () => {
    const row = staged('p', 'g1', 1, { free_after: 5, rev: 3 });
    const out = applyEvent(row, burn('g1'));
    expect(out).toMatchObject({ state: 'tombstoned', tombstone: { reason_code: 'sha256_mismatch', date: '2026-10-14' }, files: [], rev: 4 });
    expect(out.free_after).toBeUndefined();
    expect(applyEvent(reserved('q', 'g1', { free_after: 5 }), burn('g1', 'operator')).tombstone).toEqual({ reason_code: 'operator', date: '2026-10-14' });
  });

  test('leaves a row that is not pending as it is (a burn repeated, a yanked or published member), and refuses another group\'s row', () => {
    for (const state of ['tombstoned', 'yanked', 'published'] as const) {
      const row = rec({ name: 'p', version: '1.0.0', state, group_id: 'g1', rev: 4 });
      expect(applyEvent(row, burn('g1'))).toBe(row);
    }
    expect(() => applyEvent(staged('p', 'g2', 1), burn('g1'))).toThrow(WrongGroup);
    expect(() => applyEvent(rec({ name: 'p', version: '1.0.0', state: 'pending' }), burn('g1'))).toThrow(WrongGroup);
  });

  test('the stage keeps the time of the reservation, and the flip removes it', () => {
    const reservedRow = reserved('p', 'g1', { free_after: 9, rev: 0 });
    const filled = applyEvent(reservedRow, { type: 'stage', group_id: 'g1', attempt: 1, fill: fill('p') });
    expect(filled.free_after).toBe(9);
    const flipped = applyEvent(filled, { type: 'group_publish', group_id: 'g1', attempt: 1, committed_at: COMMITTED_AT });
    expect(flipped).toMatchObject({ state: 'published', published_at: COMMITTED_AT });
    expect(flipped.free_after).toBeUndefined();
  });
});

describe.each(RIGS)('the writers of a group, validation and sweeping: %s', (_label, make) => {
  let r: Rig;
  beforeEach(() => {
    r = make();
  });

  describe('the commit inputs', () => {
    test('are stored one item to a member under the hash of the request, with a TTL, and read back', async () => {
      const hash = commitRequestHash('[{"name":"a"}]');
      expect(hash).toMatch(/^[0-9a-f]{16}$/);
      await r.store.putCommitInputs('g1', hash, [{ name: 'a', manifest_sha256: 'a'.repeat(64) }, { name: 'b', manifest_sha256: 'b'.repeat(64), display: { description: 'B', keywords: ['k'] } }], 1_900_000_000);
      expect(await r.store.getCommitInput('g1', hash, 0)).toEqual({ name: 'a', manifest_sha256: 'a'.repeat(64) });
      expect(await r.store.getCommitInput('g1', hash, 1)).toEqual({ name: 'b', manifest_sha256: 'b'.repeat(64), display: { description: 'B', keywords: ['k'] } });
      expect(await r.store.getCommitInput('g1', hash, 2)).toBeUndefined();
      expect(await r.store.getCommitInput('g1', 'another hash', 0)).toBeUndefined();
      expect(r.groupItem(commitInputKey('g1', hash, 1))).toMatchObject({ publish_id: commitInputKey('g1', hash, 1), name: 'b', expires_at: 1_900_000_000 });
    });

    test('a request of more than sixteen members is stored whole (they go sixteen at a time)', async () => {
      const inputs = Array.from({ length: 40 }, (_x, i) => ({ name: `m${i}`, manifest_sha256: String(i % 10).repeat(64) }));
      await r.store.putCommitInputs('g1', 'h', inputs, 1_900_000_000);
      for (const i of [0, 15, 16, 39]) expect(await r.store.getCommitInput('g1', 'h', i)).toEqual(inputs[i]);
    });
  });

  describe('the sweeper\'s index', () => {
    test('lists the groups that are not over, with what the index projects, every page of it, and none that ended', async () => {
      for (let i = 0; i < 5; i++) {
        // The same sweep time for all: the pages are cut between items with the same sort value.
        await r.store.createGroup(group({ group_id: `g${i}`, status: i === 0 ? 'open' : 'validating' }), memberList('a'), gaudit('group_create', `g${i}`));
      }
      await r.store.updateGroup('g4', (cur) => ({ ...cur, status: 'aborted', sweep_pk: undefined, sweep_at: undefined, expires_at: 9_999_999_999 }));
      const listed = await r.store.listActiveGroups();
      expect(listed.map((g) => g.group_id).sort()).toEqual(['g0', 'g1', 'g2', 'g3']);
      expect(listed.find((g) => g.group_id === 'g0')).toEqual({ group_id: 'g0', status: 'open', attempt: 1, actor: 'u:1', rev: 0, progress_at: '2026-10-14T08:30:00Z', sweep_at: '2026-10-14T08:30:00Z', deadline_at: '2026-10-14T20:00:00Z', resend: 0 });
    });

    test('is empty when nothing is active, and ignores an item of the table that is not a header', async () => {
      expect(await r.store.listActiveGroups()).toEqual([]);
      r.putGroupItem('grpm#g9', { ...memberList('a'), sweep_pk: 'active', sweep_at: '2026-10-14T08:30:00Z' });
      expect(await r.store.listActiveGroups()).toEqual([]);
    });
  });

  describe('the member list and the header\'s expiry', () => {
    test('a header that gains an expiry takes the list along, two days later; losing it takes it off the list', async () => {
      await r.store.createGroup(group({ status: 'open' }), memberList('a', 'b'), gaudit('group_create'));
      expect(r.groupItem('grpm#g1')!.expires_at).toBeUndefined();
      const ended = await r.store.updateGroup('g1', (cur) => ({ ...cur, status: 'aborted', sweep_pk: undefined, sweep_at: undefined, expires_at: 1_800_000_000 }), gaudit('group_abort'));
      expect(ended!.expires_at).toBe(1_800_000_000);
      expect(r.groupItem('grp#g1')!.expires_at).toBe(1_800_000_000);
      expect(r.groupItem('grpm#g1')!.expires_at).toBe(1_800_000_000 + 2 * 86_400);
      expect(await r.store.getGroupMembers('g1')).toEqual(memberList('a', 'b'));

      // A write that leaves the expiry as it is leaves the list as it is.
      await r.store.updateGroup('g1', (cur) => ({ ...cur, resend: 1 }));
      expect(r.groupItem('grpm#g1')!.expires_at).toBe(1_800_000_000 + 2 * 86_400);

      await r.store.updateGroup('g1', (cur) => {
        const { expires_at: _e, ...rest } = cur;
        return { ...rest, status: 'open' };
      });
      expect(r.groupItem('grp#g1')!.expires_at).toBeUndefined();
      expect(r.groupItem('grpm#g1')!.expires_at).toBeUndefined();
      expect(await r.store.getGroupMembers('g1')).toEqual(memberList('a', 'b'));
    });

    test('a header whose list is gone ends all the same (the list is not made up)', async () => {
      await r.store.createGroup(group({ status: 'open' }), memberList('a'), gaudit('group_create'));
      r.dropGroupItem('grpm#g1');
      const out = await r.store.updateGroup('g1', (cur) => ({ ...cur, status: 'aborted', expires_at: 1_800_000_000 }));
      expect(out!.status).toBe('aborted');
      expect(r.groupItem('grpm#g1')).toBeUndefined();
    });
  });

  describe('the burn event through the store', () => {
    test('burns a staged member with its audit row, once: a repeat writes nothing', async () => {
      r.writeRow(staged('p', 'g1', 1, { rev: 1, free_after: 3 }));
      const out = await r.store.applyGroupEvent('p', '1.0.0', burn('g1'), audit('p', 'group_burn', '1.0.0'));
      expect(out).toMatchObject({ state: 'tombstoned', rev: 2, files: [] });
      expect(await r.store.raw.rawGet('p', '1.0.0')).toEqual(out);
      expect(await r.store.applyGroupEvent('p', '1.0.0', burn('g1'), audit('p', 'group_burn', '1.0.0'))).toEqual(out);
      expect((await r.store.listAudit('p')).map((a) => a.action)).toEqual(['group_burn']);
    });
  });
});
