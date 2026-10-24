import { MemoryPresigner } from '../../src/publish/memory';
import { GroupService } from '../../src/publish/group-service';
import { RIGS, type Rig } from '../group-rig';
import { errorCode, GroupEnv, json } from './group-env';
import { Scenario } from './group-scenario';

/**
 * POST /groups/{group_id}/commit, on both registry adapters: the request that says a group's files are uploaded and hands
 * over each member's manifest hash and display fields. It moves the group from `open` to `validating` and queues the
 * validation. It publishes nothing. Each test says what it proves.
 */

const HOUR = 3_600_000;

describe.each(RIGS)('commit a group: %s', (_label, make) => {
  let rig: Rig;
  let env: GroupEnv;
  beforeEach(() => {
    rig = make();
    env = new GroupEnv(rig);
  });
  const sentOnGroupQueue = () => env.groupQueue.sent.map((m) => ({ ...m, body: JSON.parse(m.body) }));

  describe('a group that is ready', () => {
    test('is answered 202, moves to validating with its phase and request hash, and queues its validation once', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).create();
      await s.upload();
      const r = await s.commit();
      expect(r.statusCode).toBe(202);
      expect(json(r)).toEqual({ group_id: s.gid, status: 'validating', attempt: 1, status_url: `/api/v1/groups/${s.gid}` });
      expect(r.headers['cache-control']).toBe('no-store');

      const h = (await s.header())!;
      expect(h).toMatchObject({ status: 'validating', attempt: 1, phase: 1, resend: 0, sweep_pk: 'active' });
      expect(h.commit_hash).toMatch(/^[0-9a-f]{16}$/);
      expect(h.committed_at).toBeUndefined();
      expect(sentOnGroupQueue()).toEqual([
        { body: { type: 'validate_group', group_id: s.gid, attempt: 1, n: 0 }, groupId: s.gid, dedupId: `vg:${s.gid}:1:0:0` },
      ]);
      // It stored each member's inputs, and nothing is visible: no row changed, no file reached the channel.
      expect(await rig.store.getCommitInput(s.gid, h.commit_hash!, 0)).toEqual({ name: 'alpha', manifest_sha256: s.pkgs[0]!.manifest });
      expect(await rig.store.getCommitInput(s.gid, h.commit_hash!, 2)).toBeUndefined();
      expect((await s.row('alpha'))!.rev).toBe(0);
      expect(s.channelFiles()).toEqual([]);
      expect((await rig.store.listAudit(`grp#${s.gid}`)).map((a) => a.action).sort()).toEqual(['group_commit_request', 'group_create']);
      // The single validator's queue was not used.
      expect(env.validateQueue.sent).toEqual([]);
    });

    test('the same request again queues nothing more (the queue drops the repeated id), and a different manifest is refused', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).start();
      const again = await s.commit();
      expect(again.statusCode).toBe(202);
      expect(sentOnGroupQueue()).toHaveLength(1);
      const other = await s.commit({ members: [{ name: 'alpha', manifest_sha256: 'e'.repeat(64) }] });
      expect(other.statusCode).toBe(409);
      expect(errorCode(other)).toBe('group_commit_refused');
      expect(json(other).error.message).toContain('another commit request');
    });

    test('a request whose members and fields are written in another order is the same request', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).create();
      await s.upload();
      const [a, b] = s.pkgs;
      expect((await s.commit({ members: [{ manifest_sha256: b!.manifest, description: 'B', name: 'beta' }, { name: 'alpha', manifest_sha256: a!.manifest }] })).statusCode).toBe(202);
      const hash = (await s.header())!.commit_hash;
      expect((await s.commit({ members: [{ name: 'alpha', manifest_sha256: a!.manifest }, { name: 'beta', description: 'B', manifest_sha256: b!.manifest }] })).statusCode).toBe(202);
      expect((await s.header())!.commit_hash).toBe(hash);
    });

    test('a group that has committed answers 200 as it is, and sends nothing; on another request it is refused', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).start();
      expect(await s.runAll()).toEqual(['committed']);
      const r = await s.commit();
      expect(r.statusCode).toBe(200);
      expect(json(r)).toMatchObject({ group_id: s.gid, status: 'committed' });
      expect(env.groupQueue.sent).toEqual([]);
      expect(errorCode(await s.commit({ members: [{ name: 'alpha', manifest_sha256: 'e'.repeat(64) }] }))).toBe('group_commit_refused');
    });

    test('is not gated by the groups switch: a group that exists is finished whatever the switch says', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).create();
      await s.upload();
      env.flags.groupActors.clear();
      expect((await s.commit()).statusCode).toBe(202);
    });
  });

  describe('a group that is not ready or not open is refused with group_commit_refused', () => {
    test('a group past its deadline: it expires, nothing is stored, nothing is queued', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).create();
      await s.upload();
      env.clock.advance(13 * HOUR);
      const r = await s.commit();
      expect(r.statusCode).toBe(409);
      expect(errorCode(r)).toBe('group_commit_refused');
      expect(json(r).error.message).toContain('expired');
      expect((await s.header())).toMatchObject({ status: 'expired' });
      expect(env.groupQueue.sent).toEqual([]);
    });

    test('a group whose deadline passes between the check and the compare-and-set is refused and not started', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).create();
      await s.upload();
      const put = rig.store.putCommitInputs.bind(rig.store);
      rig.store.putCommitInputs = async (gid, hash, inputs, expiresAt) => {
        await put(gid, hash, inputs, expiresAt);
        env.clock.advance(13 * HOUR);
      };
      const r = await s.commit();
      expect(r.statusCode).toBe(409);
      expect(json(r).error.message).toContain('past its deadline');
      expect((await s.header())!.status).toBe('open');
      expect(env.groupQueue.sent).toEqual([]);
    });

    test('a group whose header is gone by the time it is written is refused as gone', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).create();
      await s.upload();
      const put = rig.store.putCommitInputs.bind(rig.store);
      rig.store.putCommitInputs = async (gid, hash, inputs, expiresAt) => {
        await put(gid, hash, inputs, expiresAt);
        rig.dropGroupItem(`grp#${gid}`);
      };
      const r = await s.commit();
      expect(r.statusCode).toBe(409);
      expect(json(r).error.message).toContain('is gone');
      expect(env.groupQueue.sent).toEqual([]);
    });

    test('a group that was aborted, and one aborted while the request was being handled', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).create();
      await s.upload();
      expect((await env.abort(s.token, s.gid)).statusCode).toBe(200);
      const r = await s.commit();
      expect(r.statusCode).toBe(409);
      expect(json(r).error.message).toContain('is aborted');

      const t = await new Scenario(env, [{ name: 'gamma' }], 2).create();
      await t.upload();
      const put = rig.store.putCommitInputs.bind(rig.store);
      rig.store.putCommitInputs = async (gid, hash, inputs, expiresAt) => {
        await put(gid, hash, inputs, expiresAt);
        expect((await env.abort(t.token, t.gid)).statusCode).toBe(200);
      };
      const lost = await t.commit();
      expect(lost.statusCode).toBe(409);
      expect(json(lost).error.message).toContain('is aborted');
      expect(env.groupQueue.sent).toEqual([]);
    });

    test('a group whose members are not all reserved yet', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).create();
      await s.upload();
      await rig.store.updateGroup(s.gid, (cur) => ({ ...cur, reserved: '1' }));
      const r = await s.commit();
      expect(r.statusCode).toBe(409);
      expect(json(r).error.message).toContain('1 of 2 members are not reserved yet');
      expect((await s.header())!.status).toBe('open');
    });

    test('a group whose row was taken from under it', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).create();
      await s.upload();
      rig.writeRow({ ...(await s.row('beta'))!, group_id: 'grp_other' });
      const r = await s.commit();
      expect(r.statusCode).toBe(409);
      expect(json(r).error.message).toContain('beta 1.0.0 is not reserved for this group');
    });

    test('a group with a file that was not uploaded: the first one is named (400 upload_invalid), and nothing is stored', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).create();
      await s.upload(['alpha']);
      const r = await s.commit();
      expect(r.statusCode).toBe(400);
      expect(errorCode(r)).toBe('upload_invalid');
      expect(json(r).error.message).toContain(`${s.pkgs[1]!.filename} of 'beta' was not uploaded`);
      // A file of the wrong size is as good as missing.
      await env.objects.put(s.keyOf('beta'), Buffer.from('short'), { contentType: 'x' });
      expect(errorCode(await s.commit())).toBe('upload_invalid');
      expect((await s.header())!.status).toBe('open');
      expect(env.groupQueue.sent).toEqual([]);
    });
  });

  describe('the request', () => {
    test.each([
      ['no members', {}],
      ['members that is not a list', { members: {} }],
      ['a member that is not an object', { members: ['alpha'] }],
      ['a member without a name', { members: [{ manifest_sha256: 'a'.repeat(64) }] }],
      ['a manifest that is not a hash', { members: [{ name: 'alpha', manifest_sha256: 'abc' }, { name: 'beta', manifest_sha256: 'a'.repeat(64) }] }],
      ['a member twice', { members: [{ name: 'alpha', manifest_sha256: 'a'.repeat(64) }, { name: 'alpha', manifest_sha256: 'a'.repeat(64) }] }],
      ['a member of the group missing', { members: [{ name: 'alpha', manifest_sha256: 'a'.repeat(64) }] }],
      ['a member that is not in the group', { members: [{ name: 'alpha', manifest_sha256: 'a'.repeat(64) }, { name: 'beta', manifest_sha256: 'a'.repeat(64) }, { name: 'zed', manifest_sha256: 'a'.repeat(64) }] }],
      ['a description of two lines', { members: [{ name: 'alpha', manifest_sha256: 'a'.repeat(64), description: 'one\ntwo' }, { name: 'beta', manifest_sha256: 'a'.repeat(64) }] }],
    ])('%s is refused 400 invalid_request and stores nothing', async (_why, body) => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).create();
      await s.upload();
      const r = await s.commit(body);
      expect(r.statusCode).toBe(400);
      expect(errorCode(r)).toBe('invalid_request');
      expect((await s.header())!.status).toBe('open');
      expect(env.groupQueue.sent).toEqual([]);
    });

    test('a body that is not JSON, and a missing body, are refused', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).create();
      await s.upload();
      expect(errorCode(await s.commit('{not json'))).toBe('invalid_request');
      expect(errorCode(await env.call('POST', `/api/v1/groups/${s.gid}/commit`, s.token))).toBe('invalid_request');
    });
  });

  describe('who may commit', () => {
    test('the creator, and an owner of every package of the group; anyone else is told the group does not exist', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).create();
      await s.upload();
      const stranger = await env.account(9, 'mallory', ['elsewhere']);
      const r = await s.commit(undefined, stranger);
      expect(r.statusCode).toBe(404);
      expect(errorCode(r)).toBe('group_not_found');
      // An owner of both packages (not the creator) may.
      await env.own(3, 'colleague', ['alpha', 'beta']);
      const colleague = await env.token(3, ['alpha', 'beta']);
      expect((await s.commit(undefined, colleague)).statusCode).toBe(202);
    });

    test('a request with no token, a bad token, or a CI token is refused', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).create();
      await s.upload();
      expect((await env.call('POST', `/api/v1/groups/${s.gid}/commit`, undefined, s.commitBody())).statusCode).toBe(401);
      expect((await env.call('POST', `/api/v1/groups/${s.gid}/commit`, 'mopm_nope', s.commitBody())).statusCode).toBe(401);
      const ci = await env.ciToken('alpha', '1.0.0');
      const r = await s.commit(undefined, ci);
      expect(r.statusCode).toBe(404);
      expect(errorCode(r)).toBe('group_not_found');
    });

    test('an id that is not a group id is group_not_found', async () => {
      const token = await env.account(1, 'octocat', ['alpha']);
      expect(errorCode(await env.call('POST', '/api/v1/groups/nope/commit', token, { members: [] }))).toBe('group_not_found');
    });
  });

  describe('read-only mode and a deployment without the queue', () => {
    test('read-only mode refuses a commit and leaves the group open; reading and aborting it still work', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).create();
      await s.upload();
      env.flags.ro = true;
      const r = await s.commit();
      expect(r.statusCode).toBe(503);
      expect(errorCode(r)).toBe('read_only_mode');
      expect((await env.get(s.token, s.gid)).statusCode).toBe(200);
      env.flags.ro = false;
      expect((await s.commit()).statusCode).toBe(202);
    });

    test('a deployment with no group queue answers unavailable and starts nothing', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).create();
      await s.upload();
      const bare = new GroupService({ registry: rig.store, publishes: env.publishes, objects: env.objects, presigner: new MemoryPresigner(), config: env.config, now: env.clock.now });
      const principal = await env.deps.publish!.auth.authenticate(`Bearer ${s.token}`);
      await expect(bare.commit(principal, s.gid, s.commitBody())).rejects.toMatchObject({ code: 'unavailable' });
      expect((await s.header())!.status).toBe('open');
    });
  });
});
