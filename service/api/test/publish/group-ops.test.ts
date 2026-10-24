import { DynamoStore, tablesFor } from '../../src/dynamo-store';
import { bitmapIndexes } from '../../src/group-store';
import { main, QUEUES, realDeps } from '../../src/ops/group-ops-main';
import { parseOpsArgs, runOps, type OpsArgs, type OpsDeps, type QueueDepth } from '../../src/ops/group-ops';
import { validateGroup } from '../../src/publish/group-validator';
import { RIGS, type Rig } from '../group-rig';
import { GroupEnv } from './group-env';
import { Scenario } from './group-scenario';

/**
 * The operator's tool for groups (src/ops/group-ops.ts): the read-only status mode that is the check before any revert, and
 * the mode that ends a group that is stuck. Each test says what it proves.
 */

describe('the flags', () => {
  test('are parsed, and every mistake is an error that says what is wrong', () => {
    expect(parseOpsArgs(['--mode=status', '--stage=beta'])).toEqual({ mode: 'status', apply: false, stage: 'beta' });
    expect(parseOpsArgs(['--mode=fail', '--group=grp_1', '--apply', '--stage=gamma', '--region=eu-west-1'])).toEqual({ mode: 'fail', group: 'grp_1', apply: true, stage: 'gamma', region: 'eu-west-1' });
    expect(parseOpsArgs(['--mode=fail', '--group=grp_1'])).toEqual({ mode: 'fail', group: 'grp_1', apply: false });
    for (const [argv, why] of [
      [[], '--mode is status or fail'],
      [['--mode=other'], '--mode is status or fail'],
      [['status'], 'not a flag: status'],
      [['--mode=fail'], '--mode=fail needs --group'],
      [['--mode=status', '--apply'], 'read-only'],
      [['--mode=status', '--group=grp_1'], 'read-only'],
      [['--mode=status', '--bogus=1'], 'unknown flag --bogus'],
      [['--mode=status', '--mode=fail'], '--mode is given twice'],
    ] as Array<[string[], string]>) {
      expect(() => parseOpsArgs(argv)).toThrow(why);
    }
  });
});

describe.each(RIGS)('the group tool: %s', (_label, make) => {
  let rig: Rig;
  let env: GroupEnv;
  let out: Array<Record<string, unknown>>;
  let depth: QueueDepth[];
  beforeEach(() => {
    rig = make();
    env = new GroupEnv(rig);
    out = [];
    depth = QUEUES.map((queue) => ({ queue: `mopm-beta-${queue}.fifo`, visible: 0, in_flight: 0 }));
  });
  const deps = (): OpsDeps => ({ groups: rig.store, queueDepth: async () => depth, now: env.clock.now, out: (l) => out.push(l) });
  const run = (args: Partial<OpsArgs> & { mode: OpsArgs['mode'] }) => runOps({ apply: false, ...args }, deps());
  const kinds = () => out.map((l) => l.kind);

  describe('status', () => {
    test('with no group that is not over and empty queues it says a revert is safe, and exits 0', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).create();
      expect((await env.abort(s.token, s.gid)).statusCode).toBe(200);
      expect(await run({ mode: 'status' })).toBe(0);
      expect(out.filter((l) => l.kind === 'group')).toEqual([]);
      expect(out.filter((l) => l.kind === 'queue')).toHaveLength(QUEUES.length);
      expect(out[out.length - 1]).toEqual({ kind: 'verdict', safe_to_revert: true, groups_not_over: 0, queues_not_empty: [] });
    });

    test('lists a group that is open, one that is validating and one that committed and is not flipped, and exits 3', async () => {
      await new Scenario(env, [{ name: 'alpha' }], 1).create();
      const validating = await new Scenario(env, [{ name: 'beta' }], 2).start();
      const done = await new Scenario(env, [{ name: 'gamma' }, { name: 'delta' }], 3).start();
      // Both jobs are on the queue; run only the second's.
      const first = env.groupQueue.sent.findIndex((m) => JSON.parse(m.body).group_id === done.gid);
      const msg = JSON.parse(env.groupQueue.sent.splice(first, 1)[0]!.body);
      expect(await validateGroup(env.validatorDeps(), msg)).toBe('committed');
      env.clock.advance(90_000);

      expect(await run({ mode: 'status' })).toBe(3);
      const groups = out.filter((l) => l.kind === 'group');
      expect(groups).toHaveLength(3);
      const by = (id: string) => groups.find((g) => g.group_id === id)!;
      expect(by(validating.gid)).toMatchObject({ status: 'validating', phase: 1, committed: false, unflipped: null, last_sign_of_life_seconds: 90, actor: 'u:2', members: 1 });
      expect(by(done.gid)).toMatchObject({ status: 'committed', phase: 3, committed: true, unflipped: 2, members: 2 });
      expect(groups.filter((g) => g.status === 'open')).toHaveLength(1);
      expect(out[out.length - 1]).toMatchObject({ kind: 'verdict', safe_to_revert: false, groups_not_over: 3 });
    });

    test('a queue with a message in it, waiting or in flight, makes a revert unsafe on its own', async () => {
      depth[1] = { ...depth[1]!, visible: 2 };
      depth[4] = { ...depth[4]!, in_flight: 1 };
      expect(await run({ mode: 'status' })).toBe(3);
      expect(out[out.length - 1]).toEqual({ kind: 'verdict', safe_to_revert: false, groups_not_over: 0, queues_not_empty: [depth[1]!.queue, depth[4]!.queue] });
    });

    test('writes nothing', async () => {
      await new Scenario(env, [{ name: 'alpha' }]).start();
      const spy = jest.fn();
      for (const m of ['createGroup', 'updateGroup', 'commitGroup', 'adoptVersion', 'adoptSingle', 'applyGroupEvent', 'putCommitInputs'] as const) {
        (rig.store as unknown as Record<string, unknown>)[m] = spy;
      }
      const before = rig.doc?.inputs.length;
      expect(await run({ mode: 'status' })).toBe(3);
      expect(spy).not.toHaveBeenCalled();
      // On the DynamoDB adapter: reads only (Query of the index, GetItem of the headers).
      if (rig.doc) expect([...new Set(rig.doc.inputs.slice(before).map((i) => (i.IndexName ? 'Query' : 'GetItem')))].sort()).toEqual(['GetItem', 'Query']);
    });

    test('status skips an entry of the index whose header is gone, and a group whose times are not all there', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).start();
      const entry = { status: 'validating' as const, attempt: 1, actor: 'u:1', rev: 0, progress_at: (await s.header())!.progress_at, sweep_at: '2026-10-14T12:00:00.000Z', deadline_at: '2026-10-15T00:00:00.000Z', resend: 0 };
      rig.store.listActiveGroups = async () => [{ ...entry, group_id: s.gid }, { ...entry, group_id: 'grp_00000000000000000000000000000000' }];
      await rig.store.updateGroup(s.gid, ({ sweep_at: _gone, ...cur }) => cur);
      expect(await run({ mode: 'status' })).toBe(3);
      const groups = out.filter((l) => l.kind === 'group');
      expect(groups).toHaveLength(1);
      expect(groups[0]).toMatchObject({ group_id: s.gid, last_sign_of_life_seconds: 0 });
    });
  });

  describe('fail', () => {
    const plan = () => out.find((l) => l.kind === 'plan')!;

    test('without --apply only says what it would do, and changes nothing (phase 1: the group would be rejected)', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).start();
      const before = await s.header();
      expect(await run({ mode: 'fail', group: s.gid })).toBe(0);
      expect(plan()).toEqual({ kind: 'plan', group_id: s.gid, from: 'validating', to: 'rejected', phase: 1, burns_numbers: false, members: 1, dry_run: true });
      expect(kinds()).toEqual(['plan']);
      expect(await s.header()).toEqual(before);
      expect((await s.row('alpha'))!.rev).toBe(0);
    });

    test('with --apply a group that has not begun to copy is rejected: its numbers are free and a commit that follows loses', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).start();
      const seen = (await s.header())!;
      expect(await run({ mode: 'fail', group: s.gid, apply: true })).toBe(0);
      expect(kinds()).toEqual(['plan', 'ended']);
      const h = (await s.header())!;
      expect(h).toMatchObject({ status: 'rejected', failure: { code: 'operator' } });
      expect(h.sweep_pk).toBeUndefined();
      expect(h.expires_at).toEqual(expect.any(Number));
      expect((await rig.store.listAudit(`grp#${s.gid}`)).map((a) => a.action)).toContain('group_operator_end');
      expect((await env.begin(s.token, 'alpha')).statusCode).toBe(200);
      // The validator's commit, started from the header it read before: the compare-and-set loses.
      const out2 = await rig.store.commitGroup(s.gid, { rev: seen.rev, writeOrder: [0, 1], now: env.clock.now().toISOString(), audit: { name: `grp#${s.gid}`, ts: '2026-10-14T12:00:00Z', id: 'a_commit', actor: 'system', action: 'group_commit' } });
      expect(out2.outcome).toBe('conflict');
      expect((await s.header())!.committed_at).toBeUndefined();
      // And a validator that wakes up later finds the group over and does nothing.
      expect(await env.runGroupJobs()).toEqual(['skipped']);
    });

    test('with --apply a group that began to copy is failed first, and then its numbers are burned', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).start();
      const put = env.objects.put.bind(env.objects);
      env.objects.put = async (k, body, opts) => {
        if (!k.startsWith('quarantine/')) throw new Error('the Lambda died while copying');
        return put(k, body, opts);
      };
      await expect(env.runGroupJob()).rejects.toThrow('the Lambda died while copying');
      expect((await s.header())!.phase).toBe(2);

      expect(await run({ mode: 'fail', group: s.gid, apply: true })).toBe(0);
      expect(plan()).toMatchObject({ to: 'failed', phase: 2, burns_numbers: true, dry_run: false });
      expect(kinds()).toEqual(['plan', 'ended', 'burned']);
      expect(out[out.length - 1]).toEqual({ kind: 'burned', group_id: s.gid, members: 2 });
      expect((await s.header())).toMatchObject({ status: 'failed', failure: { code: 'operator' } });
      for (const n of ['alpha', 'beta']) expect(await s.row(n)).toMatchObject({ state: 'tombstoned', tombstone: { reason_code: 'operator' } });
      expect((await env.begin(s.token, 'alpha')).statusCode).toBe(409);
      // Run again: the group is over.
      out.length = 0;
      expect(await run({ mode: 'fail', group: s.gid, apply: true })).toBe(2);
      expect(out).toEqual([{ kind: 'refused', group_id: s.gid, status: 'failed', reason: expect.stringContaining('only a group that is validating') }]);
    });

    test('a racing commit loses: the header is failed before the commit can start, and the group never commits', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).start();
      const commit = rig.store.commitGroup.bind(rig.store);
      let ended = 0;
      rig.store.commitGroup = async (gid, c) => {
        // The validator has finished the copies and read the header; the operator's tool ends the group now.
        if (!ended++) expect(await run({ mode: 'fail', group: gid, apply: true })).toBe(0);
        return commit(gid, c);
      };
      expect(await env.runGroupJobs()).toEqual(['skipped']);
      const h = (await s.header())!;
      expect(h).toMatchObject({ status: 'failed' });
      expect(h.committed_at).toBeUndefined();
      expect((await s.shown('alpha'))!.state).toBe('tombstoned');
      expect(bitmapIndexes(h.copied)).toEqual([0, 1]);
      expect((await rig.store.listAudit(`grp#${s.gid}`)).filter((a) => a.action === 'group_commit')).toEqual([]);
    });

    test('loses cleanly when the group moved on between its plan and its compare-and-set (the validator began to copy)', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).start();
      const update = rig.store.updateGroup.bind(rig.store);
      rig.store.updateGroup = async (gid, fn, audit) => {
        await update(gid, (cur) => ({ ...cur, phase: 2 }));
        return update(gid, fn, audit);
      };
      expect(await run({ mode: 'fail', group: s.gid, apply: true })).toBe(4);
      expect(out[out.length - 1]).toMatchObject({ kind: 'lost', group_id: s.gid, status: 'validating' });
      expect((await s.header())!.status).toBe('validating');
      expect((await s.row('alpha'))!.state).toBe('pending');
    });

    test('refuses a group that is not validating, one that committed and one that does not exist; and writes nothing', async () => {
      const open = await new Scenario(env, [{ name: 'alpha' }], 1).create();
      const done = await new Scenario(env, [{ name: 'beta' }], 2).start();
      expect(await done.runAll()).toEqual(['committed']);
      const rev = (await done.header())!.rev;

      expect(await run({ mode: 'fail', group: open.gid, apply: true })).toBe(2);
      expect(out.pop()).toMatchObject({ kind: 'refused', status: 'open' });
      expect(await run({ mode: 'fail', group: done.gid, apply: true })).toBe(2);
      expect(out.pop()).toMatchObject({ kind: 'refused', status: 'committed' });
      expect(await run({ mode: 'fail', group: 'grp_00000000000000000000000000000000', apply: true })).toBe(2);
      expect(out.pop()).toMatchObject({ kind: 'refused', reason: 'there is no such group' });
      expect((await done.header())!.rev).toBe(rev);
      expect((await done.header())!.committed_at).toBeDefined();
    });

    test('says so when the group is gone by the time it writes, and when a failed group has no member list left to burn', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).start();
      const update = rig.store.updateGroup.bind(rig.store);
      rig.store.updateGroup = async () => undefined;
      expect(await run({ mode: 'fail', group: s.gid, apply: true })).toBe(4);
      expect(out[out.length - 1]).toMatchObject({ kind: 'lost', status: 'missing' });
      rig.store.updateGroup = update;

      // A group that began to copy whose member list has gone: it is failed, and there is nothing to burn.
      await rig.store.updateGroup(s.gid, (cur) => ({ ...cur, phase: 2 }));
      rig.dropGroupItem(`grpm#${s.gid}`);
      out.length = 0;
      expect(await run({ mode: 'fail', group: s.gid, apply: true })).toBe(0);
      expect(kinds()).toEqual(['plan', 'ended', 'burned']);
      expect(out[out.length - 1]).toEqual({ kind: 'burned', group_id: s.gid, members: 0 });
    });
  });
});

describe('the entry point', () => {
  const fakeDeps = (lines: unknown[]): OpsDeps => ({ groups: {} as never, queueDepth: async () => [], out: (l) => lines.push(l) });

  test('main runs a mode with the adapters it is given and returns its exit status', async () => {
    const rig = RIGS[0]![1]();
    const lines: unknown[] = [];
    const code = await main(['--mode=status', '--stage=beta'], () => ({ groups: rig.store, queueDepth: async () => [], out: (l) => lines.push(l) }));
    expect(code).toBe(0);
    expect(lines).toEqual([{ kind: 'verdict', safe_to_revert: true, groups_not_over: 0, queues_not_empty: [] }]);
  });

  test('a mistake in the flags, or an adapter that cannot be built, is a message on stderr and status 1', async () => {
    const err = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    try {
      expect(await main(['--mode=bogus'], () => fakeDeps([]))).toBe(1);
      expect(String(err.mock.calls[0]![0])).toContain('--mode is status or fail');
      expect(await main(['--mode=status'])).toBe(1);
      expect(String(err.mock.calls[1]![0])).toContain('--stage is beta, gamma or prod');
    } finally {
      err.mockRestore();
    }
  });

  test('the real adapters are the stage\'s tables and the six queues of its pipeline, asked for by name over HTTPS', async () => {
    const asked: string[] = [];
    const reply = (status: number, body: unknown) => ({ status, headers: { get: () => null }, text: async () => JSON.stringify(body), arrayBuffer: async () => new ArrayBuffer(0) });
    const fetchSpy = jest.spyOn(globalThis, 'fetch').mockImplementation((async (_url: string, init: { body: string; headers: Record<string, string> }) => {
      const body = JSON.parse(init.body);
      asked.push(`${init.headers['x-amz-target']} ${body.QueueName ?? body.QueueUrl}`);
      return body.QueueName ? reply(200, { QueueUrl: `https://sqs.invalid/${body.QueueName}` }) : reply(200, { Attributes: { ApproximateNumberOfMessages: '0', ApproximateNumberOfMessagesNotVisible: '0' } });
    }) as never);
    const log = jest.spyOn(console, 'log').mockImplementation(() => undefined);
    const saved = { ...process.env };
    process.env.AWS_ACCESS_KEY_ID = 'AKIDEXAMPLE';
    process.env.AWS_SECRET_ACCESS_KEY = 'example-secret';
    try {
      const deps = realDeps({ mode: 'status', apply: false, stage: 'gamma', region: 'us-east-1' });
      expect(deps.groups).toBeInstanceOf(DynamoStore);
      expect(QUEUES).toEqual(['validate', 'index', 'group', 'validate-dlq', 'index-dlq', 'group-dlq']);
      expect(tablesFor('gamma').publishes).toBe('mopm-gamma-publishes');
      const depths = await deps.queueDepth();
      expect(depths.map((d) => d.queue)).toEqual(QUEUES.map((q) => `mopm-gamma-${q}.fifo`));
      expect(depths.every((d) => d.visible === 0 && d.in_flight === 0)).toBe(true);
      expect(asked).toContain('AmazonSQS.GetQueueUrl mopm-gamma-group-dlq.fifo');
      deps.out({ kind: 'verdict' });
      expect(log).toHaveBeenCalledWith('{"kind":"verdict"}');
    } finally {
      fetchSpy.mockRestore();
      log.mockRestore();
      for (const k of ['AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY']) {
        if (saved[k] === undefined) delete process.env[k];
        else process.env[k] = saved[k];
      }
    }
  });

  test('the bundle\'s entry runs main on the process arguments and exits with its status', async () => {
    const exit = jest.spyOn(process, 'exit').mockImplementation((() => undefined) as never);
    const err = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    const argv = process.argv;
    try {
      process.argv = ['node', 'group-ops-bin.js', '--mode=other'];
      await jest.isolateModulesAsync(async () => {
        await import('../../src/ops/group-ops-bin');
        await new Promise((resolve) => setTimeout(resolve, 20));
      });
      expect(exit).toHaveBeenCalledWith(1);
    } finally {
      process.argv = argv;
      exit.mockRestore();
      err.mockRestore();
    }
  });
});
