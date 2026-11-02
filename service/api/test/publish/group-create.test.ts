import { bitmapHas, type GroupRecord, type GroupStatus } from '../../src/group-store';
import { expireIfDue } from '../../src/publish/group-lifecycle';
import { groupIdFor } from '../../src/publish/group-service';
import { rec } from '../helpers';
import { RIGS, reserved, type Rig } from '../group-rig';
import type { PublishFill } from '../../src/state';
import { errorCode, GroupEnv, json } from './group-env';
import { sha256 } from './harness';

/**
 * POST /groups, GET /groups/{id} and DELETE /groups/{id}, on both registry adapters. Every test names what it proves. The
 * routes ship dark: the `groups_enabled` switch is off unless a test turns it on (GroupEnv.allow), as in production.
 */

const HOUR = 3_600_000;
const fill = (name: string): PublishFill => {
  const r = rec({ name, version: '1.0.0' });
  return { version: r.version, build: r.build, requires_mojo: r.requires_mojo, deps: r.deps, native: r.native, files: r.files, manifest_sha256: r.manifest_sha256, published_at: r.published_at };
};
const stageAudit = (name: string) => ({ name, ts: '2026-10-14T12:30:00Z', id: `stage_${name}`, actor: 'u:1', action: 'group_stage', version: '1.0.0' });
const actions = async (rig: Rig, name: string) => (await rig.store.listAudit(name)).map((a) => a.action);
const DEAD: GroupStatus[] = ['expired', 'aborted', 'rejected', 'superseded'];

describe.each(RIGS)('groups over the registry: %s', (_label, make) => {
  let rig: Rig;
  let env: GroupEnv;
  const isDynamo = make().doc !== undefined;
  const dynamoOnly = isDynamo ? test : test.skip;
  beforeEach(() => {
    rig = make();
    env = new GroupEnv(rig);
  });

  /** Nothing of a group exists: no header, no rows, no list of the actor's groups, no charge. */
  const nothingWritten = async (gid: string | undefined, names: string[] = []) => {
    if (gid !== undefined) {
      expect(await rig.store.getGroup(gid)).toBeUndefined();
      expect(await rig.store.getGroupMembers(gid)).toBeUndefined();
    }
    for (const n of names) expect(await rig.store.raw.rawGet(n, '1.0.0')).toBeUndefined();
    expect(env.publishes.counters.size).toBe(0);
    expect(env.publishes.uploads.size).toBe(0);
  };
  const idOf = (actor: string, ...names: string[]) => groupIdFor(actor, env.groups.parse({ members: names.map((n) => env.member(n)) }));

  describe('identity, resume and reopening', () => {
    test('the same request is the same group, whatever the order of its members: 201 once, 200 after, and no row is written twice', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      const a = await env.create(me, [env.member('alpha'), env.member('beta')]);
      expect(a.statusCode).toBe(201);
      const first = json(a);
      expect(first.group_id).toMatch(/^grp_[0-9a-f]{32}$/);
      expect(first).toMatchObject({ status: 'open', attempt: 1, deadline_at: '2026-10-15T00:00:00.000Z' });
      expect(first.members.map((m: { name: string; action: string }) => [m.name, m.action])).toEqual([
        ['alpha', 'new'],
        ['beta', 'new'],
      ]);
      expect(first.members[0].files[0]).toMatchObject({
        subdir: 'linux-64',
        filename: 'mojo-alpha-1.0.0-mojo1.0.0_0.conda',
        uploaded: false,
        upload_id: expect.stringMatching(/^upl_g[0-9a-f]{31}$/),
        put_url: expect.stringContaining('quarantine/upl_g'),
      });

      const b = await env.create(me, [env.member('beta'), env.member('alpha')]);
      expect(b.statusCode).toBe(200);
      const again = json(b);
      expect(again.group_id).toBe(first.group_id);
      expect(again.members.map((m: { action: string }) => m.action)).toEqual(['join', 'join']);
      expect(again.members[0].files[0].upload_id).toBe(first.members[0].files[0].upload_id);

      for (const n of ['alpha', 'beta']) {
        expect(await rig.store.raw.rawGet(n, '1.0.0')).toMatchObject({ state: 'pending', group_id: first.group_id, rev: 0, published_by: 'octocat' });
        expect(await actions(rig, n)).toEqual(['group_reserve']);
      }
      expect(await rig.store.getGroup(first.group_id)).toMatchObject({ status: 'open', attempt: 1, reserved: '3', member_count: 2, actor: 'u:1', sweep_pk: 'active', rev: 1 });
      expect(await rig.store.getGroupMembers(first.group_id)).toEqual({
        members: [
          { name: 'alpha', version: '1.0.0', canonical: '1.0.0', subdirs: ['linux-64'] },
          { name: 'beta', version: '1.0.0', canonical: '1.0.0', subdirs: ['linux-64'] },
        ],
      });
      expect(env.publishes.uploads.size).toBe(2);
    });

    test('the id is a function of the actor and the declared set: another actor, another file hash or another member is another group', () => {
      const base = idOf('u:1', 'alpha', 'beta');
      expect(idOf('u:1', 'beta', 'alpha')).toBe(base);
      expect(idOf('u:2', 'alpha', 'beta')).not.toBe(base);
      expect(idOf('u:1', 'alpha')).not.toBe(base);
      const other = env.groups.parse({ members: [env.member('alpha'), { ...env.member('beta'), files: [{ ...env.member('beta').files[0]!, sha256: 'e'.repeat(64) }] }] });
      expect(groupIdFor('u:1', other)).not.toBe(base);
      const twoFiles = env.groups.parse({ members: [env.member('alpha'), { ...env.member('beta'), files: [...env.member('beta').files, { ...env.member('beta').files[0]!, subdir: 'noarch' }] }] });
      expect(groupIdFor('u:1', twoFiles)).not.toBe(base);
    });

    test('a group that ended without committing reopens on the identical request with the next attempt; its rows are not rewritten and a stamp of the old attempt stays stale', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      const first = json(await env.create(me, [env.member('alpha'), env.member('beta')]));
      const gid = first.group_id as string;
      await rig.store.applyGroupEvent('alpha', '1.0.0', { type: 'stage', group_id: gid, attempt: 1, fill: fill('alpha') }, stageAudit('alpha'));
      env.clock.advance(1000);
      expect((await env.abort(me, gid)).statusCode).toBe(200);
      expect(await rig.store.getGroup(gid)).toMatchObject({ status: 'aborted', attempt: 1 });
      expect((await rig.store.getGroup(gid))!.sweep_pk).toBeUndefined();

      env.clock.advance(1000);
      const r = await env.create(me, [env.member('alpha'), env.member('beta')]);
      expect(r.statusCode).toBe(201);
      expect(json(r)).toMatchObject({ group_id: gid, status: 'open', attempt: 2 });
      const header = (await rig.store.getGroup(gid))!;
      expect(header).toMatchObject({ status: 'open', attempt: 2, reserved: '3', staged: '', sweep_pk: 'active' });
      // The stage of attempt 1 is not this attempt's: the row is the one the stage wrote, and it does not count.
      expect(await rig.store.raw.rawGet('alpha', '1.0.0')).toMatchObject({ group_id: gid, staged_attempt: 1, rev: 1 });
      expect(await rig.store.raw.rawGet('beta', '1.0.0')).toMatchObject({ group_id: gid, rev: 0 });
      expect((await rig.store.getVersion('alpha', '1.0.0'))!.state).toBe('pending');
      expect(await actions(rig, 'grp#' + gid)).toEqual(['group_create', 'group_abort', 'group_reopen']);
    });

    test('an open group past its deadline is expired by the first call that meets it (a status read), and an identical create then reopens it', async () => {
      const me = await env.account(1, 'octocat', ['alpha']);
      const gid = json(await env.create(me, [env.member('alpha')])).group_id as string;
      env.clock.advance(13 * HOUR);
      const status = json(await env.get(me, gid));
      expect(status).toMatchObject({ group_id: gid, status: 'expired', attempt: 1 });
      expect(await rig.store.getGroup(gid)).toMatchObject({ status: 'expired' });
      expect(await actions(rig, 'grp#' + gid)).toEqual(['group_create', 'group_expire']);

      const r = await env.create(me, [env.member('alpha')]);
      expect(r.statusCode).toBe(201);
      expect(json(r)).toMatchObject({ status: 'open', attempt: 2, deadline_at: new Date(env.clock.t + 12 * HOUR).toISOString() });
    });

    test('a create that meets an open group past its deadline expires it itself and reopens it', async () => {
      const me = await env.account(1, 'octocat', ['alpha']);
      const gid = json(await env.create(me, [env.member('alpha')])).group_id as string;
      env.clock.advance(13 * HOUR);
      const r = await env.create(me, [env.member('alpha')]);
      expect(r.statusCode).toBe(201);
      expect(json(r)).toMatchObject({ group_id: gid, attempt: 2 });
      expect(await actions(rig, 'grp#' + gid)).toEqual(['group_create', 'group_expire', 'group_reopen']);
    });

    test('a group that is validating stays validating past its deadline: a status read and an identical create leave it as it is', async () => {
      const me = await env.account(1, 'octocat', ['alpha']);
      const gid = json(await env.create(me, [env.member('alpha')])).group_id as string;
      await rig.store.updateGroup(gid, (cur) => ({ ...cur, status: 'validating' }));
      env.clock.advance(13 * HOUR);

      expect(json(await env.get(me, gid))).toMatchObject({ group_id: gid, status: 'validating', attempt: 1 });
      const r = await env.create(me, [env.member('alpha')]);
      expect(r.statusCode).toBe(200);
      expect(json(r)).toMatchObject({ group_id: gid, status: 'validating', attempt: 1 });
      expect(await rig.store.getGroup(gid)).toMatchObject({ status: 'validating', attempt: 1 });
      expect(await actions(rig, 'grp#' + gid)).toEqual(['group_create']);
    });

    test('an open header read before the group began validating does not expire it: the change is made only to a group that is still open', async () => {
      const me = await env.account(1, 'octocat', ['alpha']);
      const gid = json(await env.create(me, [env.member('alpha')])).group_id as string;
      const staleRead = (await rig.store.getGroup(gid))!;
      expect(staleRead.status).toBe('open');
      await rig.store.updateGroup(gid, (cur) => ({ ...cur, status: 'validating' }));
      env.clock.advance(13 * HOUR);

      const after = await expireIfDue(rig.store, staleRead, env.clock.now());
      expect(after.status).toBe('validating');
      expect(await rig.store.getGroup(gid)).toMatchObject({ status: 'validating' });
      expect(await actions(rig, 'grp#' + gid)).toEqual(['group_create']);
    });

    test('a group that is validating, committed or visible is returned as it is (200, every member skip_identical, no URL); a failed one refuses with group_conflict', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta', 'gamma']);
      const gid = json(await env.create(me, [env.member('alpha'), env.member('beta')])).group_id as string;
      const members = [env.member('alpha'), env.member('beta')];
      const uploads = env.publishes.uploads.size;
      const same = async (status: string) => {
        const r = await env.create(me, members);
        expect(r.statusCode).toBe(200);
        expect(json(r)).toMatchObject({ group_id: gid, status });
        expect(json(r).members).toEqual([
          { name: 'alpha', version: '1.0.0', action: 'skip_identical', files: [] },
          { name: 'beta', version: '1.0.0', action: 'skip_identical', files: [] },
        ]);
      };
      await rig.store.updateGroup(gid, (cur) => ({ ...cur, status: 'validating' }));
      await same('validating');
      const header = (await rig.store.getGroup(gid))!;
      const out = await rig.store.commitGroup(gid, { rev: header.rev, writeOrder: [0, 1], now: env.clock.now().toISOString(), audit: { name: 'grp#' + gid, ts: env.clock.now().toISOString(), id: 'commit', actor: 'u:1', action: 'group_commit' } });
      expect(out.outcome).toBe('committed');
      await same('committed');
      await rig.store.updateGroup(gid, (cur) => ({ ...cur, status: 'visible' }));
      await same('visible');
      expect(await rig.store.raw.rawGet('alpha', '1.0.0')).toMatchObject({ rev: 0 });
      expect(env.publishes.uploads.size).toBe(uploads);

      const fresh = json(await env.create(me, [env.member('gamma')])).group_id as string;
      await rig.store.updateGroup(fresh, (cur) => ({ ...cur, status: 'failed' }));
      const failed = await env.create(me, [env.member('gamma')]);
      expect(failed.statusCode).toBe(409);
      expect(errorCode(failed)).toBe('group_conflict');
      expect(json(failed).error.message).toContain('burned');
    });

    test('an upload already in quarantine is reported uploaded and gets no URL, the others get a fresh one, and the upload ids and records stay the same on every call', async () => {
      const me = await env.account(1, 'octocat', ['alpha']);
      const two = env.member('alpha', '1.0.0', {
        files: [
          { subdir: 'linux-64', filename: 'mojo-alpha-1.0.0-mojo1.0.0_0.conda', sha256: 'a'.repeat(64), size: 1000 },
          { subdir: 'noarch', filename: 'mojo-alpha-1.0.0-mojo1.0.0_0.conda', sha256: 'b'.repeat(64), size: 700 },
        ],
      });
      const first = json(await env.create(me, [two]));
      const [f1, f2] = first.members[0].files;
      expect(f1.subdir).toBe('linux-64');
      expect(f2.subdir).toBe('noarch');
      await env.objects.put(`quarantine/${f1.upload_id}/${f1.filename}`, Buffer.alloc(1000), { contentType: 'application/octet-stream' });
      const again = json(await env.create(me, [two]));
      expect(again.members[0].files[0]).toEqual({ subdir: 'linux-64', filename: f1.filename, upload_id: f1.upload_id, uploaded: true });
      expect(again.members[0].files[1]).toMatchObject({ upload_id: f2.upload_id, uploaded: false, put_url: expect.any(String) });
      expect(env.publishes.uploads.size).toBe(2);
      expect([...env.publishes.uploads.values()].map((u) => [u.name, u.subdir, u.size, u.actor]).sort()).toEqual([
        ['alpha', 'linux-64', 1000, 'u:1'],
        ['alpha', 'noarch', 700, 'u:1'],
      ]);
    });
  });

  describe('who may create a group, and who may read one', () => {
    test('a member the caller does not own refuses the whole group, naming it, and writes nothing', async () => {
      await env.own(1, 'octocat', ['alpha']);
      await env.own(2, 'other', ['beta']);
      env.allow(1);
      const me = await env.token(1, ['alpha', 'beta']);
      const r = await env.create(me, [env.member('alpha'), env.member('beta')]);
      expect(r.statusCode).toBe(403);
      expect(errorCode(r)).toBe('not_owner');
      expect(json(r).error.message).toBe("You are not an owner of 'beta'.");
      await nothingWritten(idOf('u:1', 'alpha', 'beta'), ['alpha', 'beta']);
      expect(env.publishes.actorGroups.size).toBe(0);
    });

    test('a member whose package nobody claimed refuses the whole group, naming it', async () => {
      await env.own(1, 'octocat', ['alpha']);
      env.allow(1);
      const me = await env.token(1, ['alpha', 'ghost']);
      const r = await env.create(me, [env.member('ghost'), env.member('alpha')]);
      expect(r.statusCode).toBe(404);
      expect(errorCode(r)).toBe('package_not_found');
      expect(json(r).error.message).toBe("There is no package 'ghost'.");
      await nothingWritten(idOf('u:1', 'alpha', 'ghost'), ['alpha']);
    });

    test('the token must list every member: the first package it does not cover is named, and nothing is written', async () => {
      await env.own(1, 'octocat', ['alpha', 'beta']);
      env.allow(1);
      const me = await env.token(1, ['alpha']);
      const r = await env.create(me, [env.member('alpha'), env.member('beta')]);
      expect(r.statusCode).toBe(403);
      expect(errorCode(r)).toBe('scope_missing');
      expect(json(r).error.message).toBe("The token does not have the 'publish' scope for 'beta'.");
      await nothingWritten(idOf('u:1', 'alpha', 'beta'), ['alpha', 'beta']);
    });

    test('a CI identity token cannot create a group, even one that names its own package and version', async () => {
      await env.own(1, 'octocat', ['alpha']);
      env.flags.groupsAll = true;
      const ci = await env.ciToken('alpha', '1.0.0');
      const r = await env.create(ci, [env.member('alpha')]);
      expect(r.statusCode).toBe(403);
      expect(errorCode(r)).toBe('scope_missing');
      expect(await rig.store.raw.rawGet('alpha', '1.0.0')).toBeUndefined();
    });

    test('no token is token_missing, and a bad token token_unknown', async () => {
      expect(errorCode(await env.create(undefined, [env.member('alpha')]))).toBe('token_missing');
      expect(errorCode(await env.create(`mopm_${'a'.repeat(40)}`, [env.member('alpha')]))).toBe('token_unknown');
      expect(errorCode(await env.get('not-a-token', 'grp_' + 'a'.repeat(32)))).toBe('token_unknown');
    });

    test('a group is read and aborted by its creator and by an owner of every package in it, and by nobody else (group_not_found)', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      await env.own(2, 'both', ['alpha', 'beta']);
      await env.own(3, 'half', ['alpha']);
      const both = await env.token(2, ['alpha', 'beta']);
      const half = await env.token(3, ['alpha']);
      const stranger = await env.token(4, []);
      const gid = json(await env.create(me, [env.member('alpha'), env.member('beta')])).group_id as string;

      expect(json(await env.get(me, gid))).toMatchObject({ group_id: gid, status: 'open', member_count: 2 });
      expect((await env.get(both, gid)).statusCode).toBe(200);
      for (const t of [half, stranger]) {
        const r = await env.get(t, gid);
        expect(r.statusCode).toBe(404);
        expect(errorCode(r)).toBe('group_not_found');
        expect(errorCode(await env.abort(t, gid))).toBe('group_not_found');
      }
      expect(await rig.store.getGroup(gid)).toMatchObject({ status: 'open' });
      expect((await env.abort(both, gid)).statusCode).toBe(200);
      expect(await rig.store.getGroup(gid)).toMatchObject({ status: 'aborted' });
    });

    test('an id that is not a group id, or names no group, is group_not_found', async () => {
      const me = await env.account(1, 'octocat', ['alpha']);
      for (const id of ['nope', 'grp_short', `grp_${'a'.repeat(32)}`, `pub_${'a'.repeat(32)}`]) {
        const r = await env.get(me, id);
        expect(r.statusCode).toBe(404);
        expect(errorCode(r)).toBe('group_not_found');
        expect(errorCode(await env.abort(me, id))).toBe('group_not_found');
      }
    });
  });

  describe('the switches', () => {
    test('groups are off unless the switch admits the caller: create answers route_not_found and writes nothing', async () => {
      await env.own(1, 'octocat', ['alpha']);
      const me = await env.token(1, ['alpha']);
      const r = await env.create(me, [env.member('alpha')]);
      expect(r.statusCode).toBe(404);
      expect(errorCode(r)).toBe('route_not_found');
      await nothingWritten(idOf('u:1', 'alpha'), ['alpha']);
      expect(env.publishes.actorGroups.size).toBe(0);
    });

    test('the allow list admits only the actors it names', async () => {
      await env.own(1, 'octocat', ['alpha']);
      await env.own(2, 'other', ['beta']);
      env.allow(1);
      const t1 = await env.token(1, ['alpha']);
      const t2 = await env.token(2, ['beta']);
      expect((await env.create(t2, [env.member('beta')])).statusCode).toBe(404);
      expect(await rig.store.raw.rawGet('beta', '1.0.0')).toBeUndefined();
      expect((await env.create(t1, [env.member('alpha')])).statusCode).toBe(201);
    });

    test('with the switch off again, an existing group is still read and aborted, and only a create is refused', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      const gid = json(await env.create(me, [env.member('alpha')])).group_id as string;
      env.flags.groupActors.clear();
      expect(json(await env.get(me, gid))).toMatchObject({ status: 'open' });
      expect(errorCode(await env.create(me, [env.member('beta')]))).toBe('route_not_found');
      expect((await env.abort(me, gid)).statusCode).toBe(200);
      expect(errorCode(await env.create(me, [env.member('alpha')]))).toBe('route_not_found');
    });

    test('read-only mode refuses a create (503 read_only_mode, nothing written) and lets a group be read and aborted', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      const gid = json(await env.create(me, [env.member('alpha')])).group_id as string;
      env.flags.ro = true;
      const r = await env.create(me, [env.member('beta')]);
      expect(r.statusCode).toBe(503);
      expect(errorCode(r)).toBe('read_only_mode');
      expect(await rig.store.raw.rawGet('beta', '1.0.0')).toBeUndefined();
      expect((await env.get(me, gid)).statusCode).toBe(200);
      expect((await env.abort(me, gid)).statusCode).toBe(200);
    });

    test('a switch that cannot be read fails closed: create answers unavailable and writes nothing', async () => {
      const me = await env.account(1, 'octocat', ['alpha']);
      env.flags.groupsBroken = true;
      const spy = jest.spyOn(console, 'error').mockImplementation(() => undefined);
      try {
        const r = await env.create(me, [env.member('alpha')]);
        expect(r.statusCode).toBe(503);
        expect(errorCode(r)).toBe('unavailable');
      } finally {
        spy.mockRestore();
      }
      await nothingWritten(idOf('u:1', 'alpha'), ['alpha']);
    });

    test('when the deployment has no group service the group routes are not routes', async () => {
      const me = await env.account(1, 'octocat', ['alpha']);
      const { groups: _off, ...publish } = env.deps.publish!;
      env.deps.publish = publish;
      const r = await env.create(me, [env.member('alpha')]);
      expect(r.statusCode).toBe(404);
      expect(errorCode(r)).toBe('route_not_found');
      expect(errorCode(await env.get(me, 'grp_' + 'a'.repeat(32)))).toBe('route_not_found');
    });
  });

  describe('the rate counter', () => {
    test('a group is charged once per attempt, one hit of its file count, on counters of its own; the singles budget is untouched', async () => {
      env = new GroupEnv(rig, { ratePerAccountPerDay: 1, ratePerTokenPerDay: 1 });
      const me = await env.account(1, 'octocat', ['alpha', 'beta', 'gamma']);
      const two = (name: string) => env.member(name, '1.0.0', { files: [{ ...env.member(name).files[0]!, subdir: 'linux-64' }, { ...env.member(name).files[0]!, subdir: 'noarch' }] });
      const members = [two('alpha'), two('beta')];
      const counters = () => Object.fromEntries([...env.publishes.counters].map(([k, v]) => [k.replace(/#tok_[0-9a-z]+#/, '#<token>#'), v]));

      const gid = json(await env.create(me, members)).group_id as string;
      expect(counters()).toEqual({ 'rl#gu#1#2026-10-14': 4, 'rl#gt#<token>#2026-10-14': 4 });
      await env.create(me, members); // a resume
      await env.create(me, members);
      expect(counters()).toEqual({ 'rl#gu#1#2026-10-14': 4, 'rl#gt#<token>#2026-10-14': 4 });

      await env.abort(me, gid);
      expect((await env.create(me, members)).statusCode).toBe(201); // a new attempt
      expect(counters()).toEqual({ 'rl#gu#1#2026-10-14': 8, 'rl#gt#<token>#2026-10-14': 8 });

      // The singles' limits are 1 a day here, and a group of four files left them whole: one begin passes, the next is limited.
      expect((await env.begin(me, 'gamma')).statusCode).toBe(200);
      expect(errorCode(await env.begin(me, 'gamma'))).toBe('rate_limited');
      expect(Object.keys(counters()).sort()).toEqual(['rl#gt#<token>#2026-10-14', 'rl#gu#1#2026-10-14', 'rl#t#<token>#2026-10-14', 'rl#u#1#2026-10-14']);
    });

    test('two identical creates at once charge the counters once, for a new group and for one that is reopened; the other create is a resume', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      const members = [env.member('alpha'), env.member('beta')];
      const counters = () => Object.fromEntries([...env.publishes.counters].map(([k, v]) => [k.replace(/#tok_[0-9a-z]+#/, '#<token>#'), v]));

      const first = await Promise.all([env.create(me, members), env.create(me, members)]);
      expect(first.map((r) => r.statusCode).sort()).toEqual([200, 201]);
      expect(json(first[0]!).group_id).toBe(json(first[1]!).group_id);
      expect(counters()).toEqual({ 'rl#gu#1#2026-10-14': 2, 'rl#gt#<token>#2026-10-14': 2 });

      await env.abort(me, json(first[0]!).group_id);
      const again = await Promise.all([env.create(me, members), env.create(me, members)]);
      expect(again.map((r) => r.statusCode).sort()).toEqual([200, 201]);
      expect(json(again[0]!)).toMatchObject({ attempt: 2 });
      expect(counters()).toEqual({ 'rl#gu#1#2026-10-14': 4, 'rl#gt#<token>#2026-10-14': 4 });
    });

    test('a group over what is left of the day is rate_limited with Retry-After, creates nothing and charges nothing', async () => {
      env = new GroupEnv(rig, { groupRatePerTokenPerDay: 5 });
      const me = await env.account(1, 'octocat', ['alpha', 'beta', 'gamma']);
      const members = (names: string[]) => names.map((n) => env.member(n, '1.0.0', { files: [env.member(n).files[0]!, { ...env.member(n).files[0]!, subdir: 'noarch' }] }));
      expect((await env.create(me, members(['alpha']))).statusCode).toBe(201);
      const r = await env.create(me, members(['beta', 'gamma']));
      expect(r.statusCode).toBe(429);
      expect(errorCode(r)).toBe('rate_limited');
      expect(r.headers['retry-after']).toBe(String(12 * 3600));
      expect([...env.publishes.counters.values()]).toEqual([2, 2]);
      expect(await rig.store.getGroup(idOf('u:1', 'beta', 'gamma'))).toBeUndefined();
      expect(await rig.store.raw.rawGet('beta', '1.0.0')).toBeUndefined();
    });

    test('a group with more files than the day allows is invalid_request, not a rate limit that would never clear', async () => {
      env = new GroupEnv(rig, { groupRatePerTokenPerDay: 1 });
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      const r = await env.create(me, [env.member('alpha'), env.member('beta')]);
      expect(r.statusCode).toBe(400);
      expect(errorCode(r)).toBe('invalid_request');
      await nothingWritten(idOf('u:1', 'alpha', 'beta'), ['alpha', 'beta']);
    });

    // With the default limits. A set is many members of several files each; a validation reject ends the group, so a retry is routine.
    const wide = (e: GroupEnv, count: number, perMember: number) => {
      const names = Array.from({ length: count }, (_, i) => `pkg${i}`);
      const subdirs = ['linux-64', 'noarch', 'osx-arm64', 'linux-aarch64'];
      const members = names.map((n) => e.member(n, '1.0.0', { files: subdirs.slice(0, perMember).map((subdir) => ({ ...e.member(n).files[0]!, subdir })) }));
      return { names, members };
    };

    test('with the default limits, a group of 170 members of three files is created again after it was aborted, on the same day', async () => {
      const { names, members } = wide(env, 170, 3);
      const me = await env.account(1, 'octocat', names);
      const first = await env.create(me, members);
      expect(first.statusCode).toBe(201);
      await env.abort(me, json(first).group_id);
      const second = await env.create(me, members);
      expect(second.statusCode).toBe(201);
      expect(json(second)).toMatchObject({ attempt: 2 });
    });

    test('with the default limits, a group of 300 members of four files is not refused as invalid_request', async () => {
      const { names, members } = wide(env, 300, 4);
      const me = await env.account(1, 'octocat', names);
      const r = await env.create(me, members);
      expect(r.statusCode).toBe(201);
    });
  });

  describe('the open-group cap and superseding', () => {
    test('an actor has at most groupOpenPerActor groups open: the next create is group_conflict and writes nothing; ending one makes room', async () => {
      env = new GroupEnv(rig, { groupOpenPerActor: 2 });
      const me = await env.account(1, 'octocat', ['a1', 'a2', 'a3']);
      const g1 = json(await env.create(me, [env.member('a1')])).group_id as string;
      expect((await env.create(me, [env.member('a2')])).statusCode).toBe(201);
      const r = await env.create(me, [env.member('a3')]);
      expect(r.statusCode).toBe(409);
      expect(errorCode(r)).toBe('group_conflict');
      expect(json(r).error.message).toContain('at most 2');
      expect(await rig.store.raw.rawGet('a3', '1.0.0')).toBeUndefined();
      expect(await rig.store.getGroup(idOf('u:1', 'a3'))).toBeUndefined();

      await env.abort(me, g1);
      expect((await env.create(me, [env.member('a3')])).statusCode).toBe(201);
    });

    test('a group past its deadline does not count against the cap: creating expires it', async () => {
      env = new GroupEnv(rig, { groupOpenPerActor: 1 });
      const me = await env.account(1, 'octocat', ['a1', 'a2']);
      const g1 = json(await env.create(me, [env.member('a1')])).group_id as string;
      expect(errorCode(await env.create(me, [env.member('a2')]))).toBe('group_conflict');
      env.clock.advance(13 * HOUR);
      expect((await env.create(me, [env.member('a2')])).statusCode).toBe(201);
      expect(await rig.store.getGroup(g1)).toMatchObject({ status: 'expired' });
    });

    test('the cap is per actor: another account has its own', async () => {
      env = new GroupEnv(rig, { groupOpenPerActor: 1 });
      const me = await env.account(1, 'octocat', ['a1']);
      const you = await env.account(2, 'other', ['b1']);
      expect((await env.create(me, [env.member('a1')])).statusCode).toBe(201);
      expect((await env.create(you, [env.member('b1')])).statusCode).toBe(201);
    });

    test('two creates of one actor racing for the last place cannot both take it', async () => {
      env = new GroupEnv(rig, { groupOpenPerActor: 1 });
      const me = await env.account(1, 'octocat', ['a1', 'a2']);
      const [x, y] = await Promise.all([env.create(me, [env.member('a1')]), env.create(me, [env.member('a2')])]);
      expect([x.statusCode, y.statusCode].sort()).toEqual([201, 409]);
      expect(errorCode(x.statusCode === 409 ? x : y)).toBe('group_conflict');
    });

    test('a different set that shares a member with the actor\'s open group supersedes it: the shared number moves to the new group, the old one\'s other number stays free', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta', 'gamma']);
      const old = json(await env.create(me, [env.member('alpha'), env.member('beta')])).group_id as string;
      env.clock.advance(1000);
      const r = await env.create(me, [env.member('alpha'), env.member('gamma')]);
      expect(r.statusCode).toBe(201);
      const fresh = json(r);
      expect(fresh.group_id).not.toBe(old);
      expect(fresh.members.map((m: { name: string; action: string }) => [m.name, m.action])).toEqual([
        ['alpha', 'join'],
        ['gamma', 'new'],
      ]);
      expect(await rig.store.getGroup(old)).toMatchObject({ status: 'superseded' });
      expect((await rig.store.getGroup(old))!.sweep_pk).toBeUndefined();
      expect(await actions(rig, 'grp#' + old)).toEqual(['group_create', 'group_supersede']);
      expect(await rig.store.raw.rawGet('alpha', '1.0.0')).toMatchObject({ group_id: fresh.group_id, state: 'pending', rev: 1 });
      expect(await rig.store.raw.rawGet('beta', '1.0.0')).toMatchObject({ group_id: old, state: 'pending', rev: 0 });
      expect(await actions(rig, 'alpha')).toEqual(['group_reserve', 'group_reserve']);
    });

    test('a group that is validating is never superseded: the create is group_conflict, and the group and its row are as they were', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      const old = json(await env.create(me, [env.member('alpha')])).group_id as string;
      await rig.store.updateGroup(old, (cur) => ({ ...cur, status: 'validating' }));
      const before = await rig.store.raw.rawGet('alpha', '1.0.0');
      const r = await env.create(me, [env.member('alpha'), env.member('beta')]);
      expect(r.statusCode).toBe(409);
      expect(errorCode(r)).toBe('group_conflict');
      expect(json(r).error.message).toContain('validating');
      expect(await rig.store.getGroup(old)).toMatchObject({ status: 'validating' });
      expect(await rig.store.raw.rawGet('alpha', '1.0.0')).toEqual(before);
      expect(await rig.store.getGroup(idOf('u:1', 'alpha', 'beta'))).toBeUndefined();
      expect(await rig.store.raw.rawGet('beta', '1.0.0')).toBeUndefined();
    });

    test('one create supersedes at most groupSupersedeMax groups', async () => {
      const names = ['a1', 'a2', 'a3', 'a4'];
      const me = await env.account(1, 'octocat', names);
      const ids = [];
      for (const n of names) ids.push(json(await env.create(me, [env.member(n)])).group_id as string);
      const r = await env.create(me, names.map((n) => env.member(n)));
      expect(r.statusCode).toBe(409);
      expect(errorCode(r)).toBe('group_conflict');
      expect(json(r).error.message).toContain('supersedes at most 3');
      for (const id of ids) expect(await rig.store.getGroup(id)).toMatchObject({ status: 'open' });
    });

    test('another account\'s open group is never superseded: its numbers are held, group_conflict', async () => {
      const me = await env.account(1, 'octocat', ['alpha']);
      const you = await env.account(2, 'other', ['alpha']);
      const mine = json(await env.create(me, [env.member('alpha')])).group_id as string;
      const r = await env.create(you, [env.member('alpha')]);
      expect(r.statusCode).toBe(409);
      expect(errorCode(r)).toBe('group_conflict');
      expect(json(r).error.message).toContain(mine);
      expect(await rig.store.getGroup(mine)).toMatchObject({ status: 'open' });
      expect(await rig.store.raw.rawGet('alpha', '1.0.0')).toMatchObject({ group_id: mine, rev: 0 });
    });
  });

  describe('adoption of a dead group\'s rows', () => {
    const makeDead = async (token: string, status: GroupStatus, names: string[]) => {
      const gid = json(await env.create(token, names.map((n) => env.member(n)))).group_id as string;
      await rig.store.updateGroup(gid, (cur) => {
        const { sweep_pk: _a, sweep_at: _b, ...rest } = cur;
        return { ...rest, status };
      });
      return gid;
    };

    test.each(DEAD)('a group takes over the row of a group that is %s, checked against the row\'s revision', async (status) => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta', 'gamma']);
      const old = await makeDead(me, status, ['alpha', 'beta']);
      const r = await env.create(me, [env.member('alpha'), env.member('gamma')]);
      expect(r.statusCode).toBe(201);
      const gid = json(r).group_id as string;
      expect(json(r).members.map((m: { action: string }) => m.action)).toEqual(['join', 'new']);
      expect(await rig.store.raw.rawGet('alpha', '1.0.0')).toMatchObject({ group_id: gid, state: 'pending', rev: 1 });
      expect(await rig.store.raw.rawGet('beta', '1.0.0')).toMatchObject({ group_id: old, rev: 0 });
    });

    test.each(DEAD)('a single publish takes over the row of a group that is %s: the row is the single\'s reservation, one revision on', async (status) => {
      const me = await env.account(1, 'octocat', ['alpha']);
      const old = await makeDead(me, status, ['alpha']);
      env.clock.advance(1000);
      const r = await env.begin(me, 'alpha');
      expect(r.statusCode).toBe(200);
      const row = (await rig.store.raw.rawGet('alpha', '1.0.0'))!;
      expect(row.group_id).toBeUndefined();
      expect(row).toMatchObject({ state: 'pending', rev: 1, published_by: 'octocat' });
      expect(old).toBeDefined();
      expect(await actions(rig, 'alpha')).toEqual(['group_reserve', 'publish_adopt']);
      expect(env.publishes.uploads.size).toBe(2); // the group's own upload record, and the single's
      // It is an ordinary single reservation now: another begin joins it.
      expect((await env.begin(me, 'alpha')).statusCode).toBe(200);
    });

    test('a single does not take the row of a group that is open, or has no header', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      const open = json(await env.create(me, [env.member('alpha')])).group_id as string;
      const uploads = env.publishes.uploads.size; // the group's own
      const r = await env.begin(me, 'alpha');
      expect(r.statusCode).toBe(409);
      expect(errorCode(r)).toBe('version_exists');
      expect(await rig.store.raw.rawGet('alpha', '1.0.0')).toMatchObject({ group_id: open, rev: 0 });

      rig.writeRow(reserved('beta', 'gh'));
      const h = await env.begin(me, 'beta');
      expect(h.statusCode).toBe(409);
      expect(errorCode(h)).toBe('version_exists');
      expect(await rig.store.raw.rawGet('beta', '1.0.0')).toMatchObject({ group_id: 'gh', rev: 0 });
      expect(env.publishes.uploads.size).toBe(uploads); // neither single recorded an upload
    });

    test('a row with no header is hidden and cannot be adopted by a group: group_conflict, the row as it was, no header made', async () => {
      const me = await env.account(1, 'octocat', ['alpha']);
      rig.writeRow(reserved('alpha', 'gh'));
      expect((await rig.store.getVersion('alpha', '1.0.0'))!.state).toBe('pending');
      expect((await rig.store.listVersions('alpha')).filter((v) => v.state === 'published')).toEqual([]);
      const r = await env.create(me, [env.member('alpha')]);
      expect(r.statusCode).toBe(409);
      expect(errorCode(r)).toBe('group_conflict');
      expect(json(r).error.message).toContain('no header');
      expect(await rig.store.raw.rawGet('alpha', '1.0.0')).toMatchObject({ group_id: 'gh', rev: 0 });
      expect(await rig.store.getGroup(idOf('u:1', 'alpha'))).toBeUndefined();
    });

    test('a number a published version holds refuses the whole group as version_exists, naming it, and writes nothing', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      rig.writeRow(rec({ name: 'beta', version: '1.0.0' }));
      const r = await env.create(me, [env.member('alpha'), env.member('beta')]);
      expect(r.statusCode).toBe(409);
      expect(errorCode(r)).toBe('version_exists');
      expect(json(r).error.message).toContain("'beta' 1.0.0");
      expect(await rig.store.raw.rawGet('alpha', '1.0.0')).toBeUndefined();
      expect(await rig.store.getGroup(idOf('u:1', 'alpha', 'beta'))).toBeUndefined();
    });

    test('a single\'s reservation is joined by a group unless a publish holds the number', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      expect((await env.begin(me, 'alpha')).statusCode).toBe(200);
      expect((await env.begin(me, 'beta')).statusCode).toBe(200);
      await env.publishes.claimVersion('beta', '1.0.0', 'pub_x');
      expect(errorCode(await env.create(me, [env.member('beta')]))).toBe('version_exists');
      const ok = await env.create(me, [env.member('alpha')]);
      expect(ok.statusCode).toBe(201);
      expect(json(ok).members[0].action).toBe('join');
      expect(await rig.store.raw.rawGet('alpha', '1.0.0')).toMatchObject({ group_id: json(ok).group_id, rev: 1 });
    });

    test('a package over its storage limit refuses the group as limit_exceeded, naming it', async () => {
      env = new GroupEnv(rig, { projectQuotaBytes: 1500 });
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      rig.writeRow(rec({ name: 'alpha', version: '0.9.0' }));
      const r = await env.create(me, [env.member('alpha'), env.member('beta')]);
      expect(r.statusCode).toBe(403);
      expect(errorCode(r)).toBe('limit_exceeded');
      expect(json(r).error.message).toContain("'alpha'");
      expect(await rig.store.raw.rawGet('beta', '1.0.0')).toBeUndefined();
    });

    dynamoOnly('a group that loses the race for a dead group\'s row loses cleanly: group_conflict, the row as the winner left it, and the group ended', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      await makeDead(me, 'aborted', ['alpha']);
      const orig = rig.store.adoptVersion.bind(rig.store);
      rig.store.adoptVersion = (r, a, free) =>
        orig(r, a, (cur) => {
          const ok = free(cur);
          rig.writeRow({ ...cur, rev: cur.rev + 1 }); // another writer gets there between the read and the write
          return ok;
        });
      const res = await env.create(me, [env.member('alpha'), env.member('beta')]);
      expect(res.statusCode).toBe(409);
      expect(errorCode(res)).toBe('group_conflict');
      expect(await rig.store.raw.rawGet('alpha', '1.0.0')).toMatchObject({ rev: 1 });
      expect((await rig.store.raw.rawGet('alpha', '1.0.0'))!.group_id).not.toBe(idOf('u:1', 'alpha', 'beta'));
      expect(await rig.store.getGroup(idOf('u:1', 'alpha', 'beta'))).toMatchObject({ status: 'aborted' });
    });

    dynamoOnly('a single that loses the race for a dead group\'s row loses cleanly: version_exists, the row as the winner left it, no upload', async () => {
      const me = await env.account(1, 'octocat', ['alpha']);
      const old = await makeDead(me, 'aborted', ['alpha']);
      const uploads = env.publishes.uploads.size; // the dead group's own
      const orig = rig.store.adoptSingle.bind(rig.store);
      rig.store.adoptSingle = (r, a, free) =>
        orig(r, a, (cur) => {
          const ok = free(cur);
          rig.writeRow({ ...cur, rev: cur.rev + 1 });
          return ok;
        });
      const res = await env.begin(me, 'alpha');
      expect(res.statusCode).toBe(409);
      expect(errorCode(res)).toBe('version_exists');
      expect(await rig.store.raw.rawGet('alpha', '1.0.0')).toMatchObject({ group_id: old, rev: 1 });
      expect(env.publishes.uploads.size).toBe(uploads);
    });

    test('a member taken from under a group while it reserves ends the group (aborted) and refuses the call, leaving the rows it had reserved free', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta', 'gamma']);
      const orig = rig.store.adoptVersion.bind(rig.store);
      rig.store.adoptVersion = (r, a, free) => (r.name === 'gamma' ? Promise.resolve({ outcome: 'taken' as const, existing: rec({ name: 'gamma', version: '1.0.0', state: 'pending', group_id: 'other' }) }) : orig(r, a, free));
      const res = await env.create(me, [env.member('alpha'), env.member('beta'), env.member('gamma')]);
      expect(res.statusCode).toBe(409);
      expect(errorCode(res)).toBe('group_conflict');
      const gid = idOf('u:1', 'alpha', 'beta', 'gamma');
      expect(await rig.store.getGroup(gid)).toMatchObject({ status: 'aborted' });
      expect(await rig.store.raw.rawGet('gamma', '1.0.0')).toBeUndefined();
      // Its rows are pending, named by an ended group: free for the next group.
      rig.store.adoptVersion = orig;
      const next = await env.create(me, [env.member('alpha')]);
      expect(next.statusCode).toBe(201);
      expect(json(next).members[0].action).toBe('join');
    });
  });

  describe('the order of writes, and a create that runs out of time', () => {
    test('the member list and the header are written before the first row, and the header is open', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      const gid = idOf('u:1', 'alpha', 'beta');
      const seen: Array<{ header?: GroupRecord; members: boolean }> = [];
      const orig = rig.store.adoptVersion.bind(rig.store);
      rig.store.adoptVersion = async (r, a, free) => {
        seen.push({ header: await rig.store.getGroup(gid), members: (await rig.store.getGroupMembers(gid)) !== undefined });
        return orig(r, a, free);
      };
      expect((await env.create(me, [env.member('alpha'), env.member('beta')])).statusCode).toBe(201);
      expect(seen).toHaveLength(2);
      for (const s of seen) {
        expect(s.members).toBe(true);
        expect(s.header).toMatchObject({ status: 'open', attempt: 1 });
      }
    });

    dynamoOnly('on the wire: the member list, then the header, then the first version row', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      const before = rig.doc!.inputs.length;
      expect((await env.create(me, [env.member('alpha'), env.member('beta')])).statusCode).toBe(201);
      const writes = rig.doc!.inputs.slice(before).flatMap((i: any, at: number) => {
        const puts: Array<{ table: string; key: string }> = [];
        if (i.Item) puts.push({ table: i.TableName, key: String(i.Item.publish_id ?? i.Item.name) });
        for (const t of i.TransactItems ?? []) if (t.Put) puts.push({ table: t.Put.TableName, key: String(t.Put.Item.publish_id ?? t.Put.Item.name) });
        return puts.map((p) => ({ ...p, at }));
      });
      const first = (pred: (w: { table: string; key: string }) => boolean) => writes.find(pred)!.at;
      const members = first((w) => w.key.startsWith('grpm#'));
      const header = first((w) => w.table === 'mopm-t-publishes' && w.key.startsWith('grp#'));
      const row = first((w) => w.table === 'mopm-t-versions');
      expect(members).toBeLessThan(header);
      expect(header).toBeLessThan(row);
    });

    test('a create that runs out of time answers the members it reached with reserving k of n, and the identical request continues from the checkpoint', async () => {
      env = new GroupEnv(rig, { groupCreateBudgetMs: 1000 });
      const names = Array.from({ length: 40 }, (_, i) => `p${String(i).padStart(2, '0')}`);
      const me = await env.account(1, 'octocat', names);
      const members = names.map((n) => env.member(n));
      let adopted = 0;
      const orig = rig.store.adoptVersion.bind(rig.store);
      rig.store.adoptVersion = async (r, a, free) => {
        adopted++;
        env.mono += 100; // each reservation takes 100 ms
        return orig(r, a, free);
      };
      const gid = idOf('u:1', ...names);

      const one = await env.create(me, members);
      expect(one.statusCode).toBe(201);
      expect(json(one).reserving).toEqual({ done: 16, total: 40 });
      expect(json(one).members).toHaveLength(16);
      const h1 = (await rig.store.getGroup(gid))!;
      expect(Array.from({ length: 40 }, (_, i) => bitmapHas(h1.reserved, i))).toEqual([...Array(16).fill(true), ...Array(24).fill(false)]);
      expect(json(await env.get(me, gid)).members.map((m: { state: string }) => m.state)).toEqual([...Array(16).fill('reserved'), ...Array(24).fill('pending')]);
      expect(adopted).toBe(16);

      const two = await env.create(me, members);
      expect(two.statusCode).toBe(200);
      expect(json(two).reserving).toEqual({ done: 32, total: 40 });
      expect(adopted).toBe(32); // the first 16 were not reserved again

      const three = await env.create(me, members);
      expect(json(three).reserving).toBeUndefined();
      expect(json(three).members).toHaveLength(40);
      expect(adopted).toBe(40);
      expect((await rig.store.getGroup(gid))!.reserved).toBe('ffffffffff');
      for (const n of names) {
        expect(await rig.store.raw.rawGet(n, '1.0.0')).toMatchObject({ group_id: gid, rev: 0 });
        expect(await actions(rig, n)).toEqual(['group_reserve']);
      }
      // The charge was made once, for the whole group.
      expect([...env.publishes.counters.values()]).toEqual([40, 40]);
    });

    test('a call whose first batch takes the whole budget still moves the checkpoint (it never stops before reserving something)', async () => {
      env = new GroupEnv(rig, { groupCreateBudgetMs: 100 });
      const names = Array.from({ length: 20 }, (_, i) => `q${String(i).padStart(2, '0')}`);
      const me = await env.account(1, 'octocat', names);
      const members = names.map((n) => env.member(n));
      const gid = idOf('u:1', ...names);
      // Every reservation takes a second: the first batch spends the whole budget.
      const orig = rig.store.adoptVersion.bind(rig.store);
      rig.store.adoptVersion = async (r, a, free) => {
        env.mono += 1000;
        return orig(r, a, free);
      };
      const one = await env.create(me, members);
      expect(json(one).reserving).toEqual({ done: 16, total: 20 });
      expect(json(one).members).toHaveLength(16);
      // A call that answers `reserving` carries no files: the client asks again and reads only the counts.
      expect(json(one).members.every((m: { files: unknown[] }) => m.files.length === 0)).toBe(true);
      expect((await rig.store.getGroup(gid))!.reserved).toBe('ffff');
      const two = await env.create(me, members);
      expect(json(two).reserving).toBeUndefined();
      expect(json(two).members).toHaveLength(20);
      // The call that answers every member answers the files of every member, the ones an earlier call reserved included.
      expect(json(two).members.every((m: { files: Array<{ put_url?: string }> }) => m.files.length === 1 && m.files[0]!.put_url !== undefined)).toBe(true);
      expect(json(two).members.map((m: { action: string }) => m.action)).toEqual([...Array(16).fill('join'), ...Array(4).fill('new')]);
      expect((await rig.store.getGroup(gid))!.reserved).toBe('fffff');
    });
  });

  describe('what a request must declare', () => {
    test.each([
      ['an empty body', {}, 'invalid_request'],
      ['no members', { members: [] }, 'invalid_request'],
      ['a member that is not an object', { members: ['alpha'] }, 'invalid_request'],
      ['a member with no version', { members: [{ name: 'alpha', files: [] }] }, 'invalid_request'],
      ['a bad package name', { members: [{ name: 'Not-Valid', version: '1.0.0', files: [] }] }, 'invalid_name'],
      ['a bad version', { members: [{ name: 'alpha', version: 'x', files: [] }] }, 'invalid_version'],
      ['a member with no files', { members: [{ name: 'alpha', version: '1.0.0', files: [] }] }, 'invalid_request'],
      ['a file name that breaks the rule', { members: [{ name: 'alpha', version: '1.0.0', files: [{ subdir: 'linux-64', filename: 'alpha.conda', sha256: 'a'.repeat(64), size: 10 }] }] }, 'upload_invalid'],
      ['a size of zero', { members: [{ name: 'alpha', version: '1.0.0', files: [{ subdir: 'linux-64', filename: 'mojo-alpha-1.0.0-mojo1.0.0_0.conda', sha256: 'a'.repeat(64), size: 0 }] }] }, 'invalid_request'],
      ['a size over the per-file limit', { members: [{ name: 'alpha', version: '1.0.0', files: [{ subdir: 'linux-64', filename: 'mojo-alpha-1.0.0-mojo1.0.0_0.conda', sha256: 'a'.repeat(64), size: 100_000_001 }] }] }, 'payload_too_large'],
      ['a subdir that is not known', { members: [{ name: 'alpha', version: '1.0.0', files: [{ subdir: 'win-64', filename: 'mojo-alpha-1.0.0-mojo1.0.0_0.conda', sha256: 'a'.repeat(64), size: 10 }] }] }, 'invalid_request'],
    ])('%s is refused before anything is written', async (_what, body, code) => {
      const me = await env.account(1, 'octocat', ['alpha']);
      const r = await env.call('POST', '/api/v1/groups', me, body);
      expect(r.statusCode).toBeGreaterThanOrEqual(400);
      expect(errorCode(r)).toBe(code);
      await nothingWritten(undefined, ['alpha']);
      expect(env.publishes.actorGroups.size).toBe(0);
    });

    test('a body that is not JSON is invalid_request', async () => {
      const me = await env.account(1, 'octocat', ['alpha']);
      expect(errorCode(await env.call('POST', '/api/v1/groups', me, '{'))).toBe('invalid_request');
      expect(errorCode(await env.call('POST', '/api/v1/groups', me, ''))).toBe('invalid_request');
    });

    test('one version of each package: a package named twice, or a file listed twice, is refused', async () => {
      const me = await env.account(1, 'octocat', ['alpha']);
      const twice = await env.create(me, [env.member('alpha', '1.0.0'), env.member('alpha', '2.0.0')]);
      expect(errorCode(twice)).toBe('invalid_request');
      expect(json(twice).error.message).toContain("'alpha' appears twice");
      const file = env.member('alpha').files[0]!;
      const dup = await env.create(me, [env.member('alpha', '1.0.0', { files: [file, file] })]);
      expect(errorCode(dup)).toBe('invalid_request');
      expect(json(dup).error.message).toContain('twice');
    });

    test('a member over twenty files, a group over its member cap and a group over its byte cap are refused', async () => {
      env = new GroupEnv(rig, { groupMaxMembers: 2, groupMaxBytes: 1500 });
      const me = await env.account(1, 'octocat', ['alpha', 'beta', 'gamma']);
      const file = env.member('alpha').files[0]!;
      const many = Array.from({ length: 21 }, (_, i) => ({ ...file, filename: file.filename.replace('mojo1', `mojo${i + 1}`) }));
      expect(json(await env.create(me, [env.member('alpha', '1.0.0', { files: many })])).error.message).toContain('1 to 20 files');
      expect(json(await env.create(me, [env.member('alpha'), env.member('beta'), env.member('gamma')])).error.message).toContain('at most 2 members');
      expect(json(await env.create(me, [env.member('alpha'), env.member('beta')])).error.message).toContain('total 2000 bytes');
      await nothingWritten(undefined, ['alpha', 'beta', 'gamma']);
    });
  });

  describe('the deadline', () => {
    test('a group is created with a deadline that is a time, groupDeadlineHours on; a clock that gives none writes nothing', async () => {
      env = new GroupEnv(rig, { groupDeadlineHours: 3 });
      const me = await env.account(1, 'octocat', ['alpha']);
      const made = json(await env.create(me, [env.member('alpha')]));
      expect(made.deadline_at).toBe('2026-10-14T15:00:00.000Z');
      expect(Number.isFinite(Date.parse((await rig.store.getGroup(made.group_id))!.deadline_at))).toBe(true);
    });

    test('with no time from the clock the create fails before it writes the header, a row, a counter or the actor\'s list', async () => {
      const me = await env.account(1, 'octocat', ['alpha']);
      env.clock.t = Number.NaN;
      const principal = { token_id: 'tok', kind: 'api' as const, github_id: 1, scopes: ['publish' as const], packages: ['alpha'] };
      await expect(env.groups.create(principal, env.groups.parse({ members: [env.member('alpha')] }))).rejects.toThrow('The clock gave no time.');
      await nothingWritten(idOf('u:1', 'alpha'), ['alpha']);
      expect(env.publishes.actorGroups.size).toBe(0);
      expect(me).toBeDefined();
    });
  });

  describe('reading and aborting', () => {
    test('a group is shown with its status, attempt, deadline and each member\'s state', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      const gid = json(await env.create(me, [env.member('alpha'), env.member('beta')])).group_id as string;
      expect(json(await env.get(me, gid))).toEqual({
        group_id: gid,
        status: 'open',
        attempt: 1,
        created_at: '2026-10-14T12:00:00.000Z',
        deadline_at: '2026-10-15T00:00:00.000Z',
        member_count: 2,
        members: [
          { name: 'alpha', version: '1.0.0', state: 'reserved', files: [{ subdir: 'linux-64', filename: 'mojo-alpha-1.0.0-mojo1.0.0_0.conda', sha256: sha256('alpha-1.0.0'), size: 1000, uploaded: false }] },
          { name: 'beta', version: '1.0.0', state: 'reserved', files: [{ subdir: 'linux-64', filename: 'mojo-beta-1.0.0-mojo1.0.0_0.conda', sha256: sha256('beta-1.0.0'), size: 1000, uploaded: false }] },
        ],
      });
      await rig.store.updateGroup(gid, (cur) => ({ ...cur, staged: '1', flipped: '2' }));
      expect(json(await env.get(me, gid)).members.map((m: { state: string }) => m.state)).toEqual(['staged', 'published']);
    });

    test('abort ends an open group and is repeatable; a group that is validating, expired or committed is group_not_open', async () => {
      const me = await env.account(1, 'octocat', ['a1', 'a2', 'a3']);
      const open = json(await env.create(me, [env.member('a1')])).group_id as string;
      const r = await env.abort(me, open);
      expect(r.statusCode).toBe(200);
      expect(json(r)).toMatchObject({ status: 'aborted' });
      expect((await env.abort(me, open)).statusCode).toBe(200);
      expect(await actions(rig, 'grp#' + open)).toEqual(['group_abort', 'group_create']);

      const validating = json(await env.create(me, [env.member('a2')])).group_id as string;
      await rig.store.updateGroup(validating, (cur) => ({ ...cur, status: 'validating' }));
      const v = await env.abort(me, validating);
      expect(v.statusCode).toBe(409);
      expect(errorCode(v)).toBe('group_not_open');
      expect(json(v).error.message).toBe(`Group ${validating} is validating; only an open group can be aborted.`);
      expect(await rig.store.getGroup(validating)).toMatchObject({ status: 'validating' });

      const expiring = json(await env.create(me, [env.member('a3')])).group_id as string;
      env.clock.advance(13 * HOUR);
      expect(errorCode(await env.abort(me, expiring))).toBe('group_not_open');
      expect(await rig.store.getGroup(expiring)).toMatchObject({ status: 'expired' });
    });

    test('abort and a create that supersedes the same group cannot both win: exactly one ends it', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      const old = json(await env.create(me, [env.member('alpha')])).group_id as string;
      await Promise.all([env.abort(me, old), env.create(me, [env.member('alpha'), env.member('beta')])]);
      const header = (await rig.store.getGroup(old))!;
      expect(['aborted', 'superseded']).toContain(header.status);
      expect(await actions(rig, 'grp#' + old)).toHaveLength(2); // create, and one end
    });
  });

  describe('the pending-rows metric', () => {
    test('a create writes the most pending rows any member\'s package holds, so rows that dead groups leave behind can be alarmed on', async () => {
      const me = await env.account(1, 'octocat', ['alpha']);
      rig.writeRow(reserved('alpha', 'gx', { version: '2.0.0', canonical: '2.0.0' }));
      rig.writeRow(reserved('alpha', 'gy', { version: '3.0.0', canonical: '3.0.0' }));
      expect((await env.create(me, [env.member('alpha')])).statusCode).toBe(201); // 1.0.0 is free
      const values = env.metricLines.map((l) => l.group_pending_rows_per_package_max);
      expect(values).toEqual([2]);
      expect(env.metricLines[0]!._aws).toMatchObject({ CloudWatchMetrics: [{ Namespace: 'Mopm/Registry', Metrics: [{ Name: 'group_pending_rows_per_package_max', Unit: 'Count' }] }] });
    });

    test('a package with no pending rows reports 0, so the alarm has a value to compare', async () => {
      const me = await env.account(1, 'octocat', ['alpha']);
      await env.create(me, [env.member('alpha')]);
      expect(env.metricLines.map((l) => l.group_pending_rows_per_package_max)).toEqual([0]);
    });
  });
});
