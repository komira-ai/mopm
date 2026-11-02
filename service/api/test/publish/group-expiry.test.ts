import { ENDED_TAIL_SECONDS, ended, freeAfterFor, orphanFree } from '../../src/publish/group-lifecycle';
import { MEMBERS_TTL_EXTRA_SECONDS } from '../../src/group-store';
import { rec } from '../helpers';
import { RIGS, type Rig } from '../group-rig';
import { errorCode, GroupEnv, json } from './group-env';
import { Scenario } from './group-scenario';

/**
 * What becomes of a group that ended without committing: its header (and member list) are given a TTL and DynamoDB removes
 * them, and the pending rows its members reserved become free for any group or single to take once the header is gone. A
 * group that committed is never given an expiry, by any path. Both registry adapters. Each test says what it proves.
 */

const HOUR = 3_600_000;
const DAY = 24 * HOUR;
const seconds = (iso: string) => Math.floor(Date.parse(iso) / 1000);

describe.each(RIGS)('groups that end: %s', (_label, make) => {
  let rig: Rig;
  let env: GroupEnv;
  beforeEach(() => {
    rig = make();
    env = new GroupEnv(rig);
  });
  const item = (gid: string, prefix: 'grp#' | 'grpm#') => rig.groupItem(`${prefix}${gid}`)!;

  describe('the expiry of a header that ended without committing', () => {
    test('abort gives the header an expiry seven days after its deadline, and the member list two days more', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).create();
      const deadline = (await s.header())!.deadline_at;
      expect((await env.abort(s.token, s.gid)).statusCode).toBe(200);
      const h = (await s.header())!;
      expect(h.status).toBe('aborted');
      expect(h.expires_at).toBe(seconds(deadline) + ENDED_TAIL_SECONDS);
      expect(item(s.gid, 'grp#').expires_at).toBe(h.expires_at);
      expect(item(s.gid, 'grpm#').expires_at).toBe(h.expires_at! + MEMBERS_TTL_EXTRA_SECONDS);
      // The member list is otherwise as it was written.
      expect(await rig.store.getGroupMembers(s.gid)).toEqual({ members: [{ name: 'alpha', version: '1.0.0', canonical: '1.0.0', subdirs: ['noarch'] }] });
    });

    test('lazy expiry of an open group that nobody finished gives it the expiry too, counted from the day it was met', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).create();
      env.clock.advance(30 * DAY);
      expect((await env.get(await env.token(1, ['alpha']), s.gid)).statusCode).toBe(200);
      const h = (await s.header())!;
      expect(h.status).toBe('expired');
      expect(h.expires_at).toBe(seconds(env.clock.now().toISOString()) + ENDED_TAIL_SECONDS);
    });

    test('superseding a group, and rejecting one in the validator, give it the expiry', async () => {
      const first = await new Scenario(env, [{ name: 'alpha' }]).create();
      // A different set that shares alpha 1.0.0 supersedes the first group.
      await env.own(1, 'octocat', ['beta']);
      const both = await env.token(1, ['alpha', 'beta']);
      const second = await env.create(both, [env.member('alpha', '1.0.0'), env.member('beta', '1.0.0')]);
      expect(second.statusCode).toBe(201);
      const sup = (await first.header())!;
      expect(sup.status).toBe('superseded');
      expect(sup.expires_at).toEqual(expect.any(Number));
      expect(sup.sweep_pk).toBeUndefined();

      const bad = await new Scenario(env, [{ name: 'gamma' }, { name: 'broken', drop: ['info/index.json'] }], 2).start();
      expect(await bad.runAll()).toEqual(['rejected']);
      expect((await bad.header())!.expires_at).toEqual(expect.any(Number));
    });

    test('a group that opens again loses the expiry, and so does its member list', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).create();
      expect((await env.abort(s.token, s.gid)).statusCode).toBe(200);
      expect(item(s.gid, 'grp#').expires_at).toEqual(expect.any(Number));
      expect(item(s.gid, 'grpm#').expires_at).toEqual(expect.any(Number));
      expect((await s.recreate()).statusCode).toBe(201);
      expect((await s.header())).toMatchObject({ status: 'open', attempt: 2 });
      expect(item(s.gid, 'grp#').expires_at).toBeUndefined();
      expect(item(s.gid, 'grpm#').expires_at).toBeUndefined();
    });
  });

  describe('a group that committed is never given an expiry', () => {
    test('its header and member list have none, and no write can give it one or end it', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).start();
      expect(await s.runAll()).toEqual(['committed']);
      expect(item(s.gid, 'grp#').expires_at).toBeUndefined();
      expect(item(s.gid, 'grpm#').expires_at).toBeUndefined();

      const at = env.clock.now().toISOString();
      // Ending it (any status that carries an expiry) is refused: the marker would go with the header.
      for (const status of ['aborted', 'expired', 'superseded', 'rejected', 'failed'] as const) {
        await expect(rig.store.updateGroup(s.gid, (cur) => ended(cur, status, at))).rejects.toThrow();
      }
      // An expiry on a committed header is refused whatever its status says.
      await expect(rig.store.updateGroup(s.gid, (cur) => ({ ...cur, expires_at: 1 }))).rejects.toThrow('only for a group that ended without committing');
      expect((await s.header())!.committed_at).toBeDefined();
      expect(item(s.gid, 'grp#').expires_at).toBeUndefined();
    });

    test('and no write gives an expiry to a group that has not ended', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).create();
      for (const status of ['open', 'validating'] as const) {
        await expect(rig.store.updateGroup(s.gid, (cur) => ({ ...cur, status, expires_at: 1 }))).rejects.toThrow('only for a group that ended without committing');
      }
      expect((await s.header())!.expires_at).toBeUndefined();
    });
  });

  describe('the rows of a group whose header has expired', () => {
    /** The header and member list gone, as the table's TTL leaves them. */
    const expire = (gid: string) => {
      rig.dropGroupItem(`grp#${gid}`);
      rig.dropGroupItem(`grpm#${gid}`);
    };

    test('stay taken until the time the row says, and then any group or single takes them', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).create();
      const deadline = (await s.header())!.deadline_at;
      expect((await env.abort(s.token, s.gid)).statusCode).toBe(200);
      expect((await s.row('alpha'))!.free_after).toBe(seconds(deadline) + ENDED_TAIL_SECONDS);
      expire(s.gid);

      // The header is gone and the time has not come: the row cannot be taken (it is hidden, and its group is unknown).
      const single = await env.begin(s.token, 'alpha');
      expect(single.statusCode).toBe(409);
      expect(errorCode(single)).toBe('version_exists');
      const group = await env.create(s.token, [env.member('alpha')]);
      expect(group.statusCode).toBe(409);
      expect(errorCode(group)).toBe('group_conflict');
      expect(json(group).error.message).toContain('which has no header and so cannot be taken over');

      // The time comes: a single takes alpha, a group takes beta.
      env.clock.advance(12 * HOUR + ENDED_TAIL_SECONDS * 1000 + HOUR);
      const token = await env.token(1, ['alpha', 'beta']);
      expect((await env.begin(token, 'alpha')).statusCode).toBe(200);
      expect((await s.row('alpha'))!.group_id).toBeUndefined();
      const taken = await env.create(token, [env.member('beta')]);
      expect(taken.statusCode).toBe(201);
      expect((await s.row('beta'))!.group_id).toBe(json(taken).group_id);
    });

    test('a staged row keeps its time: a group rejected after staging leaves rows that are free once its header is gone', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'broken', drop: ['info/index.json'] }]).start();
      expect(await s.runAll()).toEqual(['rejected']);
      const staged = (await s.row('alpha'))!;
      expect(staged.staged_attempt).toBe(1);
      expect(staged.free_after).toEqual(expect.any(Number));
      expire(s.gid);
      env.clock.advance(12 * HOUR + ENDED_TAIL_SECONDS * 1000 + HOUR);
      const token = await env.token(1, ['alpha', 'broken']);
      expect((await env.begin(token, 'alpha')).statusCode).toBe(200);
    });

    test('a row of a group that is still alive is never free, however old: only a group that ended frees its rows', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).start();
      env.clock.advance(60 * DAY);
      const token = await env.token(1, ['alpha']);
      const single = await env.begin(token, 'alpha');
      expect(single.statusCode).toBe(409);
      expect(errorCode(single)).toBe('version_exists');
      expect((await s.header())!.status).toBe('validating');
    });

    test('a row with no time of its own, or one that is filled and published, is not free without a header', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).create();
      expect((await env.abort(s.token, s.gid)).statusCode).toBe(200);
      const row = (await s.row('alpha'))!;
      const { free_after: _gone, ...bare } = row;
      rig.writeRow(bare);
      expire(s.gid);
      env.clock.advance(60 * DAY);
      const token = await env.token(1, ['alpha']);
      expect(errorCode(await env.begin(token, 'alpha'))).toBe('version_exists');
    });
  });
});

describe('the lifecycle helpers', () => {
  const header = { group_id: 'g', status: 'open' as const, attempt: 1, rev: 0, actor: 'u:1', member_count: 1, created_at: '2026-10-14T12:00:00.000Z', deadline_at: '2026-10-15T00:00:00.000Z', progress_at: '2026-10-14T12:00:00.000Z', reserved: '', validated: '', staged: '', copied: '', flipped: '', resend: 0, sweep_pk: 'active', sweep_at: '2026-10-14T12:00:00.000Z' };

  test('ended: the expiry counts from the later of the end and the deadline, the sweeper index entry goes, and the failure is kept', () => {
    const early = ended(header, 'aborted', '2026-10-14T13:00:00.000Z');
    expect(early.expires_at).toBe(seconds('2026-10-15T00:00:00.000Z') + ENDED_TAIL_SECONDS);
    expect(early).toMatchObject({ status: 'aborted', progress_at: '2026-10-14T13:00:00.000Z' });
    expect(early.sweep_pk).toBeUndefined();
    expect(early.sweep_at).toBeUndefined();
    expect(early.failure).toBeUndefined();
    const late = ended(header, 'failed', '2026-11-01T00:00:00.000Z', { code: 'x', message: 'y' });
    expect(late.expires_at).toBe(seconds('2026-11-01T00:00:00.000Z') + ENDED_TAIL_SECONDS);
    expect(late.failure).toEqual({ code: 'x', message: 'y' });
  });

  test('a row is free without a header only when it is pending, has a time, and the time has passed', () => {
    const at = freeAfterFor('2026-10-15T00:00:00.000Z');
    expect(at).toBe(seconds('2026-10-15T00:00:00.000Z') + ENDED_TAIL_SECONDS);
    const pending = rec({ name: 'a', version: '1.0.0', state: 'pending', free_after: at });
    expect(orphanFree(pending, new Date((at - 1) * 1000))).toBe(false);
    expect(orphanFree(pending, new Date(at * 1000))).toBe(false);
    expect(orphanFree(pending, new Date((at + 1) * 1000))).toBe(true);
    expect(orphanFree({ ...pending, state: 'published' }, new Date((at + 1) * 1000))).toBe(false);
    expect(orphanFree({ state: 'pending' }, new Date((at + 1) * 1000))).toBe(false);
  });
});
