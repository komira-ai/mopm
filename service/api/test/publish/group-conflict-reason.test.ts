import type { HttpResponse } from '../../src/http/router';
import { groupIdFor } from '../../src/publish/group-service';
import { RIGS, reserved, type Rig } from '../group-rig';
import { errorCode, GroupEnv, json } from './group-env';

/**
 * `error.reason` of a group_conflict (one value per cause) and the `on_overlap` option of POST /groups with the
 * `superseded` list of the answer, on both registry adapters. Every test names the site it drives.
 */

const reasonOf = (r: HttpResponse): string | undefined => json(r).error.reason;

describe.each(RIGS)('group_conflict reasons and on_overlap over the registry: %s', (_label, make) => {
  let rig: Rig;
  let env: GroupEnv;
  beforeEach(() => {
    rig = make();
    env = new GroupEnv(rig);
  });
  const idOf = (actor: string, ...names: string[]) => groupIdFor(actor, env.groups.parse({ members: names.map((n) => env.member(n)) }));
  const conflict = (r: HttpResponse, reason: string) => {
    expect(r.statusCode).toBe(409);
    expect(errorCode(r)).toBe('group_conflict');
    expect(reasonOf(r)).toBe(reason);
    // The reason is a field of its own: never part of the message or the hint, and no group id is a field of the error.
    expect(Object.keys(json(r).error).sort()).toEqual(['code', 'hint', 'message', 'reason']);
    expect(json(r).error.message).not.toContain(reason);
    expect(json(r).error.hint).not.toContain(reason);
  };

  describe('one reason for each cause', () => {
    test('number_held: another account\'s open group holds the number', async () => {
      const me = await env.account(1, 'octocat', ['alpha']);
      const you = await env.account(2, 'other', ['alpha']);
      await env.create(me, [env.member('alpha')]);
      conflict(await env.create(you, [env.member('alpha')]), 'number_held');
    });

    test('number_held: the caller\'s own group is validating and is never superseded', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      const old = json(await env.create(me, [env.member('alpha')])).group_id as string;
      await rig.store.updateGroup(old, (cur) => ({ ...cur, status: 'validating' }));
      conflict(await env.create(me, [env.member('alpha'), env.member('beta')]), 'number_held');
    });

    test('number_held: an own group that began validating after the overlap scan is found not dead when it is superseded', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      const old = json(await env.create(me, [env.member('alpha')])).group_id as string;
      const put = env.publishes.putActorGroups.bind(env.publishes);
      env.publishes.putActorGroups = async (actor, groups, rev) => {
        const ok = await put(actor, groups, rev);
        // The scan has found `old` open and chosen it for superseding; it moves on before the create ends it.
        if (ok) await rig.store.updateGroup(old, (cur) => ({ ...cur, status: 'validating' }));
        return ok;
      };
      conflict(await env.create(me, [env.member('alpha'), env.member('beta')]), 'number_held');
      expect(await rig.store.getGroup(old)).toMatchObject({ status: 'validating' });
    });

    test('group_failed: a failed group asked for again has burned its numbers', async () => {
      const me = await env.account(1, 'octocat', ['alpha']);
      const gid = json(await env.create(me, [env.member('alpha')])).group_id as string;
      await rig.store.updateGroup(gid, (cur) => ({ ...cur, status: 'failed' }));
      conflict(await env.create(me, [env.member('alpha')]), 'group_failed');
    });

    test('open_cap: the actor already has the most groups open', async () => {
      env = new GroupEnv(rig, { groupOpenPerActor: 1 });
      const me = await env.account(1, 'octocat', ['a1', 'a2']);
      await env.create(me, [env.member('a1')]);
      conflict(await env.create(me, [env.member('a2')]), 'open_cap');
    });

    test('supersede_cap: the set overlaps more open groups than one create supersedes', async () => {
      const names = ['a1', 'a2', 'a3', 'a4'];
      const me = await env.account(1, 'octocat', names);
      for (const n of names) await env.create(me, [env.member(n)]);
      conflict(await env.create(me, names.map((n) => env.member(n))), 'supersede_cap');
    });

    test('takeover_blocked: a row whose group has no header is not yet free', async () => {
      const me = await env.account(1, 'octocat', ['alpha']);
      rig.writeRow(reserved('alpha', 'gh'));
      conflict(await env.create(me, [env.member('alpha')]), 'takeover_blocked');
    });

    test('number_taken: another publish took the number while the group was being created', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      const orig = rig.store.adoptVersion.bind(rig.store);
      rig.store.adoptVersion = (r, a, free) => (r.name === 'beta' ? Promise.resolve({ outcome: 'taken' as const, existing: { ...r, group_id: 'other' } }) : orig(r, a, free));
      conflict(await env.create(me, [env.member('alpha'), env.member('beta')]), 'number_taken');
    });

    test('overlap_refused: see the on_overlap tests below', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      await env.create(me, [env.member('alpha')]);
      conflict(await env.create(me, [env.member('alpha'), env.member('beta')], { on_overlap: 'refuse' }), 'overlap_refused');
    });

    test('a conflict that is not a group_conflict carries no reason (version_exists)', async () => {
      const me = await env.account(1, 'octocat', ['alpha']);
      rig.writeRow({ ...reserved('alpha', 'gh'), state: 'published' });
      const r = await env.create(me, [env.member('alpha')]);
      expect(errorCode(r)).toBe('version_exists');
      expect(json(r).error.reason).toBeUndefined();
    });
  });

  describe('on_overlap', () => {
    test('refuse: the create answers overlap_refused naming the caller\'s own group, supersedes nothing, and writes nothing', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      const old = json(await env.create(me, [env.member('alpha')])).group_id as string;
      const before = await rig.store.raw.rawGet('alpha', '1.0.0');
      const r = await env.create(me, [env.member('alpha'), env.member('beta')], { on_overlap: 'refuse' });
      conflict(r, 'overlap_refused');
      expect(json(r).error.message).toContain(old);
      expect(await rig.store.getGroup(old)).toMatchObject({ status: 'open' });
      expect(await rig.store.raw.rawGet('alpha', '1.0.0')).toEqual(before);
      expect(await rig.store.raw.rawGet('beta', '1.0.0')).toBeUndefined();
      expect(await rig.store.getGroup(idOf('u:1', 'alpha', 'beta'))).toBeUndefined();
      expect((await rig.store.listAudit('grp#' + old)).map((a) => a.action)).toEqual(['group_create']);
    });

    test('refuse names every overlapping group of the caller, and no other account\'s', async () => {
      const me = await env.account(1, 'octocat', ['a1', 'a2', 'b1']);
      const you = await env.account(2, 'other', ['c1']);
      const g1 = json(await env.create(me, [env.member('a1')])).group_id as string;
      const g2 = json(await env.create(me, [env.member('a2')])).group_id as string;
      const gb = json(await env.create(me, [env.member('b1')])).group_id as string;
      const gc = json(await env.create(you, [env.member('c1')])).group_id as string;
      const r = await env.create(me, [env.member('a1'), env.member('a2')], { on_overlap: 'refuse' });
      conflict(r, 'overlap_refused');
      const msg = json(r).error.message as string;
      expect(msg).toContain(g1);
      expect(msg).toContain(g2);
      expect(msg).not.toContain(gb); // shares nothing with the new set
      expect(msg).not.toContain(gc);
    });

    test('refuse with nothing overlapping creates the group as usual, and names no superseded group', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      await env.create(me, [env.member('alpha')]);
      const r = await env.create(me, [env.member('beta')], { on_overlap: 'refuse' });
      expect(r.statusCode).toBe(201);
      expect('superseded' in json(r)).toBe(false);
    });

    test('refuse also holds past the supersede cap: overlap_refused, not supersede_cap', async () => {
      const names = ['a1', 'a2', 'a3', 'a4'];
      const me = await env.account(1, 'octocat', names);
      for (const n of names) await env.create(me, [env.member(n)]);
      conflict(await env.create(me, names.map((n) => env.member(n)), { on_overlap: 'refuse' }), 'overlap_refused');
    });

    test('refuse and a validating group that shares a number is still a group_conflict, with its reason', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      const old = json(await env.create(me, [env.member('alpha')])).group_id as string;
      await rig.store.updateGroup(old, (cur) => ({ ...cur, status: 'validating' }));
      conflict(await env.create(me, [env.member('alpha'), env.member('beta')], { on_overlap: 'refuse' }), 'number_held');
      expect(await rig.store.getGroup(old)).toMatchObject({ status: 'validating' });
    });

    test('the default is supersede: the old group ends, and the answer names it', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      const old = json(await env.create(me, [env.member('alpha')])).group_id as string;
      const r = await env.create(me, [env.member('alpha'), env.member('beta')]);
      expect(r.statusCode).toBe(201);
      expect(json(r).superseded).toEqual([old]);
      expect(await rig.store.getGroup(old)).toMatchObject({ status: 'superseded' });
    });

    test('supersede spelled out is the default', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      const old = json(await env.create(me, [env.member('alpha')])).group_id as string;
      const r = await env.create(me, [env.member('alpha'), env.member('beta')], { on_overlap: 'supersede' });
      expect(r.statusCode).toBe(201);
      expect(json(r).superseded).toEqual([old]);
    });

    test('the answer lists each group the create ended, and omits the key when it ended none', async () => {
      const me = await env.account(1, 'octocat', ['a1', 'a2', 'a3']);
      const g1 = json(await env.create(me, [env.member('a1')])).group_id as string;
      const g2 = json(await env.create(me, [env.member('a2')])).group_id as string;
      const first = await env.create(me, [env.member('a3')]);
      expect('superseded' in json(first)).toBe(false);
      const r = await env.create(me, [env.member('a1'), env.member('a2')]);
      expect([...json(r).superseded].sort()).toEqual([g1, g2].sort());
      // Asked for again, the group is only continued: it ended nothing this time.
      const again = await env.create(me, [env.member('a1'), env.member('a2')]);
      expect(again.statusCode).toBe(200);
      expect('superseded' in json(again)).toBe(false);
    });

    test.each([['replace'], [5], [null], [true], [['refuse']]])('an on_overlap of %p is invalid_request and writes nothing', async (value) => {
      const me = await env.account(1, 'octocat', ['alpha']);
      const r = await env.create(me, [env.member('alpha')], { on_overlap: value });
      expect(r.statusCode).toBe(400);
      expect(errorCode(r)).toBe('invalid_request');
      expect(json(r).error.reason).toBeUndefined();
      expect(await rig.store.getGroup(idOf('u:1', 'alpha'))).toBeUndefined();
      expect(await rig.store.raw.rawGet('alpha', '1.0.0')).toBeUndefined();
    });

    test('on_overlap is not part of the group id: the same set with either value is the same group, so a retry stays idempotent', async () => {
      const me = await env.account(1, 'octocat', ['alpha']);
      const a = json(await env.create(me, [env.member('alpha')], { on_overlap: 'refuse' }));
      const b = await env.create(me, [env.member('alpha')]);
      expect(b.statusCode).toBe(200);
      expect(json(b).group_id).toBe(a.group_id);
      const c = await env.create(me, [env.member('alpha')], { on_overlap: 'refuse' });
      expect(c.statusCode).toBe(200);
      expect(json(c).group_id).toBe(a.group_id);
      expect(idOf('u:1', 'alpha')).toBe(a.group_id);
    });
  });
});
