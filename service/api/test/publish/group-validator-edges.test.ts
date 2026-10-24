import { Metrics } from '../../src/metrics';
import { sweepGroups } from '../../src/publish/group-sweeper';
import { validateGroup } from '../../src/publish/group-validator';
import { RIGS, type Rig } from '../group-rig';
import { GroupEnv } from './group-env';
import { Scenario } from './group-scenario';

/**
 * The edges of the group's validator and sweeper: what they do when the rows are not as staged, when the header moves under
 * them, when a store call fails, and when the index they read is stale. Both registry adapters. Each test says what it proves.
 */

describe.each(RIGS)('the validator and sweeper at their edges: %s', (_label, make) => {
  let rig: Rig;
  let env: GroupEnv;
  beforeEach(() => {
    rig = make();
    env = new GroupEnv(rig);
  });
  const message = () => JSON.parse(env.groupQueue.sent[0]!.body) as { group_id: string; attempt: number; n: number };

  describe('the verification pass before the commit', () => {
    test('a member row that is not as it was staged is never committed: the job fails (dead-letter queue, alarm) and the group stays validating', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).start();
      const put = env.objects.put.bind(env.objects);
      let last = 0;
      env.objects.put = async (k, body, opts) => {
        const r = await put(k, body, opts);
        // After the last copy, a row is changed by something that should not be able to: its stamp goes.
        if (!k.startsWith('quarantine/') && ++last === 2) rig.writeRow({ ...(await s.row('beta'))!, staged_attempt: 0 });
        return r;
      };
      await expect(validateGroup(env.validatorDeps(), message())).rejects.toThrow('beta 1.0.0 is not as it was staged');
      const h = (await s.header())!;
      expect(h).toMatchObject({ status: 'validating', phase: 3 });
      expect(h.committed_at).toBeUndefined();
      expect((await s.shown('alpha'))!.state).toBe('pending');
    });

    test('a member row that is gone, or is another group\'s, is the same defect', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).start();
      rig.writeRow({ ...(await s.row('alpha'))!, group_id: 'grp_other' });
      await expect(validateGroup(env.validatorDeps(), message())).rejects.toThrow("is not the group's pending row");
      rig.writeRow({ ...(await s.row('alpha'))!, group_id: s.gid, state: 'published' });
      await expect(validateGroup(env.validatorDeps(), message())).rejects.toThrow("is not the group's pending row (published");
    });

    test('a member list that is missing, and a commit input that is missing, are defects the job throws', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).start();
      const h = (await s.header())!;
      rig.dropGroupItem(`grpc#${s.gid}#${h.commit_hash}#0`);
      await expect(validateGroup(env.validatorDeps(), message())).rejects.toThrow('the commit input of alpha');
      rig.dropGroupItem(`grpm#${s.gid}`);
      await expect(validateGroup(env.validatorDeps(), message())).rejects.toThrow('its member list is missing');
    });

    test('a failure that is not a verdict on an archive is thrown from the archive pass', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).start();
      env.objects.get = async () => {
        throw new Error('S3 is down');
      };
      await expect(validateGroup(env.validatorDeps(), message())).rejects.toThrow('S3 is down');
      expect((await s.header())!.status).toBe('validating');
    });
  });

  describe('the commit', () => {
    test('a header that moved between the read and the compare-and-set is read again, up to three times', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).start();
      const commit = rig.store.commitGroup.bind(rig.store);
      let conflicts = 2;
      rig.store.commitGroup = async (gid, c) => {
        if (conflicts-- > 0) {
          // A resend of the sweeper moves the header.
          await rig.store.updateGroup(gid, (cur) => ({ ...cur, resend: cur.resend + 1 }));
        }
        return commit(gid, c);
      };
      expect(await validateGroup(env.validatorDeps(), message())).toBe('committed');
      expect((await s.header())!.committed_at).toBeDefined();

      const t = await new Scenario(env, [{ name: 'beta' }], 2).start();
      rig.store.commitGroup = async (gid, c) => {
        await rig.store.updateGroup(gid, (cur) => ({ ...cur, resend: cur.resend + 1 }));
        return commit(gid, c);
      };
      await expect(validateGroup(env.validatorDeps(), JSON.parse(env.groupQueue.sent.find((m) => JSON.parse(m.body).group_id === t.gid)!.body))).rejects.toThrow('lost its compare-and-set three times');
      expect((await t.header())!.status).toBe('validating');
    });

    test('a commit that finds the marker already there, and one that finds the group gone, end the job quietly', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).start();
      const commit = rig.store.commitGroup.bind(rig.store);
      rig.store.commitGroup = async () => ({ outcome: 'already', header: (await s.header())! });
      expect(await validateGroup(env.validatorDeps(), message())).toBe('already');
      rig.store.commitGroup = async () => ({ outcome: 'missing' });
      expect(await validateGroup(env.validatorDeps(), message())).toBe('skipped');
      rig.store.commitGroup = commit;
    });

    test('a group that another worker committed between the verification and the commit is already committed, and nothing more is done', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).start();
      const get = rig.store.getGroup.bind(rig.store);
      const commit = rig.store.commitGroup.bind(rig.store);
      const commits = jest.fn(commit);
      rig.store.commitGroup = commits;
      rig.store.getGroup = async (gid) => {
        const h = await get(gid);
        // From the commit loop on (phase 3) the header reads as committed by someone else.
        return h && h.phase === 3 ? { ...h, status: 'committed', committed_at: '2026-10-14T12:00:00.000Z' } : h;
      };
      expect(await validateGroup(env.validatorDeps(), message())).toBe('already');
      expect(commits).not.toHaveBeenCalled();
      rig.store.getGroup = get;
      expect((await s.header())!.committed_at).toBeUndefined();
    });

    test('a group ended or replaced between the verification and the commit is left alone', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).start();
      const get = rig.store.getGroup.bind(rig.store);
      let reads = 0;
      rig.store.getGroup = async (gid) => {
        const h = await get(gid);
        // From the commit loop on (the group is in phase 3) the header reads as the next attempt's.
        return ++reads >= 2 && h && h.phase === 3 ? { ...h, attempt: h.attempt + 1 } : h;
      };
      expect(await validateGroup(env.validatorDeps(), message())).toBe('skipped');
      rig.store.getGroup = get;
      expect((await s.header())!.committed_at).toBeUndefined();
    });

    test('a quarantine object that cannot be deleted after the commit is logged, and the group is committed', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).start();
      env.objects.delete = async () => {
        throw new Error('S3 would not delete');
      };
      expect(await s.run()).toBe('committed');
      expect(env.jobLogs.some((l) => l.msg === 'could not delete a quarantine object; the lifecycle rule will')).toBe(true);
      expect((await s.header())!.committed_at).toBeDefined();
    });
  });

  describe('a header that is ended while the job runs', () => {
    test('a job that runs out of time and finds the group ended does not queue its continuation', async () => {
      const slow = new GroupEnv(make(), { groupBudgetMs: 1000 });
      await new Scenario(slow, Array.from({ length: 4 }, (_x, i) => ({ name: `pkg${i}` }))).start();
      const store = slow.rig.store;
      const input = store.getCommitInput.bind(store);
      store.getCommitInput = async (gid, hash, i) => {
        // While the second member is read, the operator's tool ends the group.
        if (i === 1) await store.updateGroup(gid, (cur) => ({ ...cur, status: 'failed', sweep_pk: undefined, expires_at: 1 }));
        return input(gid, hash, i);
      };
      let t = 0;
      const before = slow.groupQueue.sent.length;
      expect(await slow.runGroupJob({ clock: () => (t += 600) })).toBe('skipped');
      // Only the message it was given was taken; it sent nothing.
      expect(slow.groupQueue.sent.length).toBe(before - 1);
    });

    test('a verdict on a group that someone else already ended changes nothing and says skipped', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'broken', drop: ['info/index.json'] }]).start();
      const get = env.objects.get.bind(env.objects);
      env.objects.get = async (k: string) => {
        // The owner's account is closed, say, and the group is aborted by hand while the job reads the archives.
        await rig.store.updateGroup(s.gid, (cur) => ({ ...cur, status: 'aborted', sweep_pk: undefined, expires_at: 1 }));
        return get(k);
      };
      expect(await s.run()).toBe('skipped');
      expect((await s.header())!.status).toBe('aborted');
      expect((await s.header())!.failure).toBeUndefined();
    });
  });

  describe('headers and rows that lack what the writers usually leave', () => {
    test('a failed group whose header records no failure is burned under a default code', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).start();
      await rig.store.updateGroup(s.gid, (cur) => ({ ...cur, status: 'failed', sweep_pk: undefined, expires_at: 1 }));
      expect(await validateGroup(env.validatorDeps(), message())).toBe('failed');
      expect(await s.row('alpha')).toMatchObject({ state: 'tombstoned', tombstone: { reason_code: 'failed' } });
    });

    test('a validating header with no request hash is a defect the job throws', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).start();
      await rig.store.updateGroup(s.gid, ({ commit_hash: _gone, ...cur }) => cur);
      await expect(validateGroup(env.validatorDeps(), message())).rejects.toThrow('(no hash)');
    });

    test('a reserved row with no publisher recorded is published by the group\'s account', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).start();
      const { published_by: _gone, ...bare } = (await s.row('alpha'))!;
      rig.writeRow(bare);
      expect(await validateGroup(env.validatorDeps(), message())).toBe('committed');
      expect((await s.shown('alpha'))!.published_by).toBe('u:1');
    });
  });

  describe('the sweeper reads an index that may be stale', () => {
    const sweep = () => sweepGroups({ groups: rig.store, groupQueue: env.groupQueue, now: env.clock.now, metrics: new Metrics(() => undefined), log: () => undefined });

    test('an entry whose group is gone, or whose header says it is moving, is not resent', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).start();
      env.groupQueue.take();
      const old = env.clock.now().toISOString();
      env.clock.advance(3_600_000);
      const listed = rig.store.listActiveGroups.bind(rig.store);
      rig.store.listActiveGroups = async () => {
        const [real] = await listed();
        // The index is behind: it lists a group the table no longer has, and the real one as it was an hour ago.
        return [
          { ...real!, progress_at: old, sweep_at: old },
          { ...real!, group_id: 'grp_00000000000000000000000000000000', progress_at: old, sweep_at: old },
        ];
      };
      await rig.store.updateGroup(s.gid, (cur) => ({ ...cur, progress_at: env.clock.now().toISOString() }));
      const r = await sweep();
      expect(r.resent).toEqual([]);
      expect(r.validating).toBe(2);
      expect(env.groupQueue.sent).toEqual([]);
    });
  });
});
