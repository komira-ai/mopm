import { Metrics } from '../../src/metrics';
import { MAX_RESENDS, STALL_MS, sweepGroups } from '../../src/publish/group-sweeper';
import { RIGS, type Rig } from '../group-rig';
import { GroupEnv } from './group-env';
import { Scenario } from './group-scenario';

/**
 * The sweeper's validating part (src/publish/group-sweeper.ts), on both registry adapters. It reads the sparse index of groups
 * that are not over and sends the validate message again for a group that has shown no sign of life. Each test says what
 * it proves.
 */

const MINUTE = 60_000;

describe.each(RIGS)('the group sweeper: %s', (_label, make) => {
  let rig: Rig;
  let env: GroupEnv;
  let lines: Array<Record<string, unknown>>;
  beforeEach(() => {
    rig = make();
    env = new GroupEnv(rig);
    lines = [];
  });
  const sweep = () => sweepGroups({ groups: rig.store, groupQueue: env.groupQueue, now: env.clock.now, metrics: new Metrics((l) => lines.push(l)), log: (l) => env.jobLogs.push(l) });
  const metric = (name: string) => lines.map((l) => l[name]).filter((v) => v !== undefined);

  /** A group that is validating whose message was lost: the commit queued it and the queue lost it. */
  async function stalled(names = ['alpha']) {
    const s = await new Scenario(env, names.map((name) => ({ name }))).start();
    expect(env.groupQueue.take()).toBeDefined();
    return s;
  }

  test('a group that is moving is left alone', async () => {
    const s = await stalled();
    env.clock.advance(STALL_MS - MINUTE);
    const r = await sweep();
    expect(r).toEqual({ validating: 1, resent: [], gaveUp: [], oldestSeconds: (STALL_MS - MINUTE) / 1000 });
    expect(env.groupQueue.sent).toEqual([]);
    expect((await s.header())!.resend).toBe(0);
  });

  test('a stalled validating group gets its message again, each resend with a new dedup id, and then only the alarm', async () => {
    const s = await stalled();
    const ids: string[] = [];
    for (let k = 1; k <= MAX_RESENDS; k++) {
      env.clock.advance(STALL_MS + MINUTE);
      const r = await sweep();
      expect(r.resent).toEqual([s.gid]);
      expect(r.gaveUp).toEqual([]);
      const m = env.groupQueue.take()!;
      expect(JSON.parse(m.body)).toEqual({ type: 'validate_group', group_id: s.gid, attempt: 1, n: 0 });
      expect(m.groupId).toBe(s.gid);
      ids.push(m.dedupId);
      expect((await s.header())).toMatchObject({ resend: k, status: 'validating' });
    }
    // Not the id of the message the commit sent (`vg:<id>:1:0:0`), and none repeated: a FIFO queue drops a repeated id for five minutes.
    expect(ids).toEqual([`vg:${s.gid}:1:0:1`, `vg:${s.gid}:1:0:2`, `vg:${s.gid}:1:0:3`]);

    // The resends are used up: the next sweep resends nothing and counts the group for the alarm.
    env.clock.advance(STALL_MS + MINUTE);
    const last = await sweep();
    expect(last.resent).toEqual([]);
    expect(last.gaveUp).toEqual([s.gid]);
    expect(env.groupQueue.sent).toEqual([]);
    expect(metric('group_sweeper_gave_up')).toEqual([0, 0, 0, 1]);
    expect(metric('group_sweeper_resends')).toEqual([1, 1, 1, 0]);
    expect(env.jobLogs.some((l) => String(l.msg).includes('as often as it will'))).toBe(true);
    // It ended nothing and burned nothing.
    expect((await s.header())).toMatchObject({ status: 'validating', resend: MAX_RESENDS });
    expect((await s.row('alpha'))!.state).toBe('pending');
  });

  test('a resend is not repeated before the group has had the time again, and the resent message finishes the group', async () => {
    const s = await stalled();
    env.clock.advance(STALL_MS + MINUTE);
    expect((await sweep()).resent).toEqual([s.gid]);
    // Five minutes on (the next scheduled run): the resend counts as a sign of life.
    env.clock.advance(5 * MINUTE);
    expect((await sweep()).resent).toEqual([]);
    expect(env.groupQueue.sent).toHaveLength(1);

    expect(await env.runGroupJobs()).toEqual(['committed']);
    expect((await s.header())).toMatchObject({ status: 'committed', resend: 0 });
  });

  test('progress sets the resend count back: a group that moved is stalled afresh', async () => {
    const s = await new Scenario(env, Array.from({ length: 10 }, (_x, i) => ({ name: `pkg${i}` }))).start();
    env.groupQueue.take();
    env.clock.advance(STALL_MS + MINUTE);
    expect((await sweep()).resent).toEqual([s.gid]);
    expect((await s.header())!.resend).toBe(1);
    // The resent message runs for a while and saves progress (its first save is after eight members): resend is 0 again.
    const put = env.objects.put.bind(env.objects);
    env.objects.put = async (k, body, opts) => {
      if (!k.startsWith('quarantine/')) throw new Error('stop after the first phase');
      return put(k, body, opts);
    };
    await expect(env.runGroupJob()).rejects.toThrow('stop after the first phase');
    expect((await s.header())).toMatchObject({ resend: 0, phase: 2 });
  });

  test('a group that saved progress between the sweeper reading it and writing it is not resent', async () => {
    const s = await stalled();
    env.clock.advance(STALL_MS + MINUTE);
    const update = rig.store.updateGroup.bind(rig.store);
    let first = true;
    rig.store.updateGroup = async (gid, fn, audit) => {
      if (first) {
        first = false;
        // The validator's save lands first.
        await update(gid, (cur) => ({ ...cur, progress_at: env.clock.now().toISOString(), sweep_at: env.clock.now().toISOString() }));
      }
      return update(gid, fn, audit);
    };
    const r = await sweep();
    expect(r.resent).toEqual([]);
    expect(env.groupQueue.sent).toEqual([]);
    expect((await s.header())!.resend).toBe(0);
  });

  test('only a validating group is looked after: an open group, a committed one and a group that is over are not', async () => {
    const open = await new Scenario(env, [{ name: 'alpha' }]).create();
    const done = await new Scenario(env, [{ name: 'beta' }], 2).start();
    expect(await done.runAll()).toEqual(['committed']);
    const aborted = await new Scenario(env, [{ name: 'gamma' }], 3).create();
    expect((await env.abort(aborted.token, aborted.gid)).statusCode).toBe(200);
    env.clock.advance(STALL_MS * 2);
    const r = await sweep();
    expect(r).toEqual({ validating: 0, resent: [], gaveUp: [], oldestSeconds: 0 });
    expect(env.groupQueue.sent).toEqual([]);
    expect((await open.header())!.status).toBe('open');
    expect(metric('group_oldest_nonterminal_age_seconds')).toEqual([0]);
  });

  test('the oldest age is of the group that has been quiet the longest', async () => {
    await stalled(['alpha']);
    env.clock.advance(10 * MINUTE);
    const young = await new Scenario(env, [{ name: 'beta' }], 2).start();
    expect(young.gid).not.toBe('');
    env.clock.advance(5 * MINUTE);
    const r = await sweep();
    expect(r.validating).toBe(2);
    expect(r.oldestSeconds).toBe(15 * 60);
    expect(metric('group_oldest_nonterminal_age_seconds')).toEqual([15 * 60]);
  });

  test('every group of a long index is looked at (the index is read to its end)', async () => {
    for (let i = 0; i < 5; i++) await new Scenario(env, [{ name: `pkg${i}` }], i + 1).start();
    env.groupQueue.sent.length = 0; // their messages were lost
    env.clock.advance(STALL_MS + MINUTE);
    const r = await sweep();
    expect(r.validating).toBe(5);
    expect(r.resent).toHaveLength(5);
    expect(new Set(env.groupQueue.sent.map((m) => m.dedupId)).size).toBe(5);
  });
});
