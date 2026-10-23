import { createHash } from 'node:crypto';
import { buildTakedowns, indexKey, packageRev, TAKEDOWNS_KEY } from '../../src/index-files';
import { bitmapIndexes } from '../../src/group-store';
import { Metrics } from '../../src/metrics';
import { runOps } from '../../src/ops/group-ops';
import { madeVisible, nextStep, sendStep, stepDedupId, touchedSubdirs } from '../../src/publish/group-chain';
import { CHAIN_STALL_MS, MAX_RESENDS, sweepGroups } from '../../src/publish/group-sweeper';
import { parseIndexMessage } from '../../src/publish/indexer';
import { MemoryQueue } from '../../src/publish/memory';
import type { QueueMessage } from '../../src/publish/ports';
import { RIGS, type Rig } from '../group-rig';
import { audit } from '../helpers';
import { Chain, label } from './group-chain-env';
import { GroupEnv } from './group-env';
import { Scenario } from './group-scenario';
import type { Spec } from '../validate/builder';

/**
 * The chain that follows a group's commit (src/publish/group-chain.ts), on both registry adapters, over real archives: the
 * repodata hops, the index hops in the header's write order, the flip, and the sweeper that resends a step that was lost. Each
 * test says what it proves; the interleaving of readers with the chain is in group-concurrency-job.test.ts.
 *
 * The group most tests use: `app` depends on `lib`, `lib` on `base`; `lib` has its file in linux-64, the others in noarch. The
 * members are listed in name order (app 0, base 1, lib 2) and the write order is base, lib, app. The chain is therefore
 *   repodata linux-64, repodata noarch, index base, index lib, index app, flip.
 */

const MINUTE = 60_000;
const SPECS = [
  { name: 'app', subdir: 'noarch', index: { depends: ['mojo-compiler ==1.0.0', 'mojo-lib'] }, mopm: { deps: [{ name: 'lib' }] } },
  { name: 'base', subdir: 'noarch' },
  { name: 'lib', subdir: 'linux-64', index: { depends: ['mojo-compiler ==1.0.0', 'mojo-base'] }, mopm: { deps: [{ name: 'base' }] } },
];
const NAMES = ['app', 'base', 'lib'];
const STEPS = ['repodata linux-64', 'repodata noarch', 'index base', 'index lib', 'index app', 'flip'];
const DEPENDS_ON: Record<string, string[]> = { app: ['lib'], lib: ['base'], base: [] };
const sha = (b: Buffer) => createHash('sha256').update(b).digest('hex');

describe.each(RIGS)('the chain after a commit: %s', (_label, make) => {
  let rig: Rig;
  let env: GroupEnv;
  let chain: Chain;
  beforeEach(() => {
    rig = make();
    env = new GroupEnv(rig);
    chain = new Chain(env);
  });

  /** A group of the given specs, validated and committed: the first hop of its chain is on the index queue. */
  async function committed(specs: Array<Partial<Spec>> = SPECS): Promise<Scenario> {
    const s = await new Scenario(env, specs).start();
    expect(await s.runAll()).toEqual(['committed']);
    return s;
  }
  const header = async (s: Scenario) => (await s.header())!;
  const stored = (name: string) => rig.store.raw.rawGet(name, '1.0.0');

  /** The package names a subdir's repodata lists. */
  const listed = (subdir: string): string[] => {
    const o = env.objects.objects.get(`${subdir}/repodata.json`);
    if (!o) return [];
    const doc = JSON.parse(o.body.toString('utf8')) as { 'packages.conda': Record<string, { name: string }> };
    return Object.values(doc['packages.conda']).map((p) => p.name.replace(/^mojo-/, '')).sort();
  };
  /** The packages that have a sparse-index file. */
  const indexed = (names: readonly string[] = NAMES): string[] => names.filter((n) => env.objects.objects.has(indexKey(n))).sort();
  /** Every file the chain writes, by key, as a hash of its bytes (the packages' own files and quarantine are not the chain's). */
  const files = (): Map<string, string> => new Map(env.objects.keys().filter((k) => k.startsWith('index/') || k.endsWith('repodata.json') || k.endsWith('repodata.json.zst')).map((k) => [k, sha(env.objects.objects.get(k)!.body)]));

  /** Builds nobody asked for: every subdir's repodata, every member's index file and the takedown log, as a yank or a backfill would send them. */
  async function strays(names: readonly string[] = NAMES, subdirs: readonly string[] = ['linux-64', 'noarch']) {
    const send = (body: object): QueueMessage => ({ body: JSON.stringify(body), groupId: 'stray', dedupId: 'stray' });
    for (const subdir of subdirs) await chain.runIndex(send({ type: 'index', subdir }));
    for (const name of names) await chain.runIndex(send({ type: 'index_pkg', name, rev: 0 }));
    await chain.runIndex(send({ type: 'index_takedowns' }));
  }

  describe('the builds between two hops', () => {
    test('a stray repodata, index or takedown build lists only the members the header has released, at every step of the chain', async () => {
      const s = await committed();
      const trace: string[] = [];
      const check = async () => {
        const h = await header(s);
        const order = h.write_order!;
        const members = (h.index_released ?? []).map((p) => NAMES[order[p]!]!).sort();
        trace.push(`${(h.repodata_released ?? []).length}/${(h.index_released ?? []).length}`);
        // Repodata: a subdir lists its members once the subdir is released, and not before.
        expect(listed('linux-64')).toEqual((h.repodata_released ?? []).includes('linux-64') ? ['lib'] : []);
        expect(listed('noarch')).toEqual((h.repodata_released ?? []).includes('noarch') ? ['app', 'base'] : []);
        // Index: a package has its file once its position is released, and not before.
        expect(indexed()).toEqual(members);
        // The takedown log is of tombstones, and a member of a group is in it only as a tombstone: none of these is.
        expect(env.objects.objects.get(TAKEDOWNS_KEY)!.body.toString('utf8')).toBe(buildTakedowns([]));
      };

      await strays();
      await check();
      await chain.drain(async () => {
        await strays();
        await check();
      });
      // The run is not trivial: the builds were seen with nothing released, with the repodata released and with the index released one package at a time.
      expect(trace).toEqual(expect.arrayContaining(['0/0', '1/0', '2/0', '2/1', '2/2', '2/3']));
      expect((await header(s)).status).toBe('visible');
    });

    test('the same builds after the group is visible list every member, from the rows alone', async () => {
      const s = await committed();
      await chain.drain();
      expect((await header(s)).status).toBe('visible');
      await strays();
      expect(listed('linux-64')).toEqual(['lib']);
      expect(listed('noarch')).toEqual(['app', 'base']);
      expect(indexed()).toEqual(NAMES);
    });
  });

  describe('the order of the hops', () => {
    test('no index file is written before every repodata gate is set, and none before the repodata of every subdir was written', async () => {
      const s = await committed();
      const seen: Array<{ key: string; released: string[] }> = [];
      const put = env.objects.put.bind(env.objects);
      env.objects.put = async (k, body, opts) => {
        if (k.startsWith('index/')) seen.push({ key: k, released: (await rig.store.getGroup(s.gid))!.repodata_released ?? [] });
        return put(k, body, opts);
      };
      await chain.drain();
      expect(seen.map((x) => x.key)).toEqual(['base', 'lib', 'app'].map(indexKey));
      for (const x of seen) expect(x.released.sort()).toEqual(['linux-64', 'noarch']);
      const log = env.objects.log.filter((l) => l.startsWith('put ') && (l.includes('repodata.json') || l.startsWith('put index/')));
      const firstIndex = log.findIndex((l) => l.startsWith('put index/'));
      const lastGroupRepodata = log.map((l, i) => (l.endsWith('/repodata.json.zst') ? i : -1)).filter((i) => i >= 0 && i < firstIndex).pop();
      expect(lastGroupRepodata).toBeDefined();
      // Both subdirs' repodata were written (the second one's last) before the first index file.
      expect(log.slice(0, firstIndex).filter((l) => l === 'put noarch/repodata.json' || l === 'put linux-64/repodata.json').length).toBeGreaterThanOrEqual(2);
    });

    test('an index hop that arrives before the repodata is released writes nothing, releases nothing and adds no second message', async () => {
      const s = await committed();
      expect(env.indexQueue.sent.map((m) => m.groupId)).toEqual(['linux-64']);
      const early = { type: 'index_pkg', name: 'base', rev: 0, group: { group_id: s.gid, attempt: 1, resend: 0, position: 0 } };
      await chain.runIndex({ body: JSON.stringify(early), groupId: 'pkg:base', dedupId: 'early' });
      expect(indexed()).toEqual([]);
      expect(env.objects.keys('index/')).toEqual([]);
      expect((await header(s)).index_released).toBeUndefined();
      // The step that is missing is the repodata hop that is already queued: the queue drops the second one.
      expect(env.indexQueue.sent).toHaveLength(1);
      expect(chain.log.some((l) => String(l.msg).includes('arrived before the steps it follows'))).toBe(true);
      expect(await chain.drain()).toHaveLength(STEPS.length);
      expect((await header(s)).status).toBe('visible');
    });

    test('dependency order holds at every step: a package has its file only after the packages it depends on, and a hop sent out of order releases nothing', async () => {
      const s = await committed();
      const dependenciesFirst = async () => {
        for (const n of indexed()) for (const dep of DEPENDS_ON[n]!) expect(indexed()).toContain(dep);
      };
      // Run the two repodata hops, then offer `app` (the last in the order) while `base` and `lib` are not released.
      await chain.step();
      await chain.step();
      expect((await header(s)).repodata_released!.sort()).toEqual(['linux-64', 'noarch']);
      const out = { type: 'index_pkg', name: 'app', rev: 0, group: { group_id: s.gid, attempt: 1, resend: 0, position: 2 } };
      await chain.runIndex({ body: JSON.stringify(out), groupId: 'pkg:app', dedupId: 'out-of-order' });
      expect((await header(s)).index_released ?? []).toEqual([]);
      expect(indexed()).toEqual([]);
      const seen: string[][] = [];
      await chain.drain(async () => {
        await strays();
        await dependenciesFirst();
        seen.push(indexed());
      });
      expect(seen.map((x) => x.length)).toEqual([1, 2, 3, 3]);
      expect((await header(s)).index_released).toEqual([0, 1, 2]);
    });

    test('a cycle is ordered by name inside itself, after what it depends on', async () => {
      // aa and ab depend on each other; aa also depends on zd, which sorts after both. Members: aa 0, ab 1, zd 2.
      const s = await committed([
        { name: 'aa', subdir: 'noarch', index: { depends: ['mojo-compiler ==1.0.0', 'mojo-ab', 'mojo-zd'] }, mopm: { deps: [{ name: 'ab' }, { name: 'zd' }] } },
        { name: 'ab', subdir: 'noarch', index: { depends: ['mojo-compiler ==1.0.0', 'mojo-aa'] }, mopm: { deps: [{ name: 'aa' }] } },
        { name: 'zd', subdir: 'noarch' },
      ]);
      expect((await header(s)).write_order).toEqual([2, 0, 1]);
      const keys: string[] = [];
      const put = env.objects.put.bind(env.objects);
      env.objects.put = async (k, body, opts) => {
        if (k.startsWith('index/')) keys.push(k);
        return put(k, body, opts);
      };
      await chain.drain();
      expect(keys).toEqual(['zd', 'aa', 'ab'].map(indexKey));
      expect((await header(s)).status).toBe('visible');
    });

    test('the hops come in the order of the steps the header shows undone', async () => {
      const s = await committed();
      const ran = await chain.drain();
      expect(ran.map(label)).toEqual(STEPS);
      const h = await header(s);
      const members = (await rig.store.getGroupMembers(s.gid))!;
      expect(touchedSubdirs(members)).toEqual(['linux-64', 'noarch']);
      expect(nextStep(h, members)).toBeUndefined(); // visible: nothing is next
    });
  });

  describe('a message delivered more than once', () => {
    test('redelivered hops write the same bytes, change no row and queue no second next step', async () => {
      const s = await committed();
      const rows = async () => JSON.stringify(await Promise.all(NAMES.map(stored)));
      await chain.drain(async (ran) => {
        if (ran.queue === 'group') return;
        const before = { files: files(), rows: await rows(), queued: env.indexQueue.sent.length + env.groupQueue.sent.length };
        const again = await chain.runIndex(ran.raw);
        expect(again).toEqual(ran.message);
        expect(files()).toEqual(before.files);
        expect(await rows()).toBe(before.rows);
        // The next step was queued by the first delivery; the second one's identical message is dropped by the queue.
        expect(env.indexQueue.sent.length + env.groupQueue.sent.length).toBe(before.queued);
      });
      expect((await header(s)).status).toBe('visible');
    });

    test('a hop that arrives after the chain has moved on rebuilds from the header as it is and sends the step that is next', async () => {
      const s = await committed();
      const first = env.indexQueue.take()!; // the linux-64 hop
      await chain.runIndex(first);
      await chain.step(); // noarch
      await chain.step(); // index base
      expect((await header(s)).index_released).toEqual([0]);
      const before = files();
      env.indexQueue = new MemoryQueue(); // the queue has forgotten its dedup ids (the five minutes are over); the next step (index lib) was taken by another worker
      await chain.runIndex(first); // the linux-64 hop again, long after
      expect(files()).toEqual(before);
      // It queued what is next now (index lib), not a repeat of the repodata hop.
      expect(env.indexQueue.sent.map((m) => JSON.parse(m.body).name)).toEqual(['lib']);
      expect(await chain.drain()).toHaveLength(3);
      expect((await header(s)).status).toBe('visible');
    });
  });

  describe('the flip', () => {
    test('a member that was yanked before the flip stays yanked, and the flip writes nothing to its row', async () => {
      const s = await committed();
      // Everything but the flip has run: the group is committed, released everywhere and not flipped.
      while (env.indexQueue.sent.length > 0) await chain.step();
      expect(env.groupQueue.sent).toHaveLength(1);
      // The API already shows the members (they are committed); one is yanked by name.
      await rig.store.updateVersion('lib', '1.0.0', { type: 'yank', reason: 'a bad build' }, audit('lib', 'yank', '1.0.0'));
      const yanked = (await stored('lib'))!;
      expect(yanked).toMatchObject({ state: 'yanked', yank_reason: 'a bad build', group_id: s.gid });

      const ran = (await chain.step())!;
      expect(ran).toMatchObject({ queue: 'group', outcome: 'visible' });
      expect(await stored('lib')).toEqual(yanked);
      expect((await stored('app'))!.state).toBe('published');
      expect((await stored('base'))!.state).toBe('published');
      const h = await header(s);
      expect(h.status).toBe('visible');
      // The yanked member counts as flipped: the group is done with it.
      expect(bitmapIndexes(h.flipped)).toEqual([0, 1, 2]);
    });

    test('is content-neutral: the files built after the flip are byte for byte those built before it, and only the revision of each package moved', async () => {
      const s = await committed();
      while (env.indexQueue.sent.length > 0) await chain.step();
      await strays();
      const before = files();
      const revBefore = await Promise.all(NAMES.map(async (n) => packageRev(await rig.store.listVersions(n))));
      expect(bitmapIndexes((await header(s)).flipped)).toEqual([]);

      expect(await chain.step()).toMatchObject({ queue: 'group', outcome: 'visible' });
      for (const n of NAMES) expect((await stored(n))!.state).toBe('published');
      await strays();
      expect(files()).toEqual(before);
      const revAfter = await Promise.all(NAMES.map(async (n) => packageRev(await rig.store.listVersions(n))));
      expect(revAfter).toEqual(revBefore.map((r) => r + 1));
      expect(listed('noarch')).toEqual(['app', 'base']);
    });

    test('is not done early: a flip that arrives before the hops flips nothing and queues the step that is missing', async () => {
      const s = await committed();
      expect(env.indexQueue.sent).toHaveLength(1);
      const flip = { body: JSON.stringify({ type: 'flip_group', group_id: s.gid, attempt: 1, resend: 0 }), groupId: s.gid, dedupId: 'early-flip' };
      expect(await chain.runFlip(flip)).toMatchObject({ outcome: 'redirected' });
      for (const n of NAMES) expect((await stored(n))!.state).toBe('pending');
      expect(bitmapIndexes((await header(s)).flipped)).toEqual([]);
      expect(env.indexQueue.sent).toHaveLength(1); // the repodata hop that was already queued
      expect(await chain.drain()).toHaveLength(STEPS.length);
    });

    test('the last step sets visible once: the header leaves the sweeper\'s index in that write, and a repeat or a second flip changes nothing', async () => {
      const s = await committed();
      expect((await header(s)).sweep_pk).toBe('active');
      while (env.indexQueue.sent.length > 0) await chain.step();
      const flip = env.groupQueue.take()!;

      // The operator's tool says it is not safe to revert while the group is committed, and safe once it is visible.
      const out: Array<Record<string, unknown>> = [];
      const status = () => runOps({ mode: 'status', apply: false }, { groups: rig.store, queueDepth: async () => [], now: env.clock.now, out: (l) => out.push(l) });
      expect(await status()).toBe(3);
      expect(out.at(-1)).toMatchObject({ kind: 'verdict', safe_to_revert: false, groups_not_over: 1 });
      expect(out.find((l) => l.kind === 'group')).toMatchObject({ group_id: s.gid, status: 'committed', unflipped: 3 });

      // Two flips at once: one makes the group visible, the other finds it so.
      const outcomes = (await Promise.all([chain.runFlip(flip), chain.runFlip(flip)])).map((r) => r.outcome).sort();
      expect(outcomes).toEqual(['already', 'visible']);
      const h = await header(s);
      expect(h).toMatchObject({ status: 'visible', resend: 0 });
      expect(h.sweep_pk).toBeUndefined();
      expect(h.sweep_at).toBeUndefined();
      expect(h.committed_at).toBeDefined();
      expect((await rig.store.listActiveGroups()).map((g) => g.group_id)).not.toContain(s.gid);
      expect((await rig.store.listAudit(`grp#${s.gid}`)).filter((a) => a.action === 'group_visible')).toHaveLength(1);

      out.length = 0;
      expect(await status()).toBe(0);
      expect(out.at(-1)).toMatchObject({ kind: 'verdict', safe_to_revert: true, groups_not_over: 0 });

      // A third delivery, long after: nothing is written.
      const rev = h.rev;
      expect(await chain.runFlip(flip)).toMatchObject({ outcome: 'already' });
      expect((await header(s)).rev).toBe(rev);
      expect((await rig.store.listAudit(`grp#${s.gid}`)).filter((a) => a.action === 'group_visible')).toHaveLength(1);
    });

    test('a flip that died after flipping some rows, before it saved them, goes on and writes each member\'s audit row once', async () => {
      const s = await committed();
      while (env.indexQueue.sent.length > 0) await chain.step();
      // The row of `base` was flipped by a worker that died before it saved the bitmap.
      const h = await header(s);
      await rig.store.applyGroupEvent('base', '1.0.0', { type: 'group_publish', group_id: s.gid, attempt: 1, committed_at: h.committed_at! }, audit('base', 'group_flip', '1.0.0'));
      expect(bitmapIndexes((await header(s)).flipped)).toEqual([]);
      expect(await chain.step()).toMatchObject({ outcome: 'visible' });
      expect(bitmapIndexes((await header(s)).flipped)).toEqual([0, 1, 2]);
      for (const n of NAMES) expect((await stored(n))!.state).toBe('published');
      expect((await rig.store.listAudit('base')).filter((a) => a.action === 'group_flip')).toHaveLength(1);
    });

    test('a group of more members than one batch is flipped whole, and the header saves each batch', async () => {
      const specs = Array.from({ length: 18 }, (_x, i) => ({ name: `p${String(i).padStart(2, '0')}`, subdir: 'noarch' }));
      const s = await committed(specs);
      const saves: string[] = [];
      const update = rig.store.updateGroup.bind(rig.store);
      rig.store.updateGroup = async (gid, fn, a) => {
        const after = await update(gid, fn, a);
        if (after) saves.push(after.flipped);
        return after;
      };
      await chain.drain();
      const h = await header(s);
      expect(h.status).toBe('visible');
      expect(bitmapIndexes(h.flipped)).toHaveLength(18);
      // Sixteen members, then two: the bitmap grew in two saves before visible.
      expect(new Set(saves.filter((b) => b !== '')).size).toBeGreaterThanOrEqual(2);
      for (const sp of specs) expect((await stored(sp.name))!.state).toBe('published');
    });
  });

  describe('a flip, or a hop, that finds the group other than it was read', () => {
    const flipOf = (gid: string, attempt = 1): QueueMessage => ({ body: JSON.stringify({ type: 'flip_group', group_id: gid, attempt, resend: 0 }), groupId: gid, dedupId: 'f' });
    /** Make the group visible just before the first header write that follows: the group moved between the read and the write. */
    function visibleBeforeNextWrite(gid: string) {
      const update = rig.store.updateGroup.bind(rig.store);
      let first = true;
      rig.store.updateGroup = async (g, fn, a) => {
        if (first) {
          first = false;
          await update(gid, (cur) => madeVisible(cur, env.clock.now().toISOString()));
        }
        return update(g, fn, a);
      };
    }

    test('a repodata hop whose group became visible between its read and its write sets no gate and builds nothing', async () => {
      const s = await committed();
      const hop = env.indexQueue.take()!;
      visibleBeforeNextWrite(s.gid);
      await chain.runIndex(hop);
      expect([...files().keys()]).toEqual([]);
      expect((await header(s)).repodata_released).toBeUndefined();
      expect(chain.log.some((l) => String(l.msg).includes('no longer in its chain'))).toBe(true);
      expect(env.indexQueue.sent).toEqual([]);
    });

    test('an index hop whose group became visible between its read and its write sets no gate and writes no file', async () => {
      const s = await committed();
      await chain.step();
      await chain.step();
      const hop = env.indexQueue.take()!;
      visibleBeforeNextWrite(s.gid);
      await chain.runIndex(hop);
      expect(env.objects.objects.has(indexKey('base'))).toBe(false);
      expect((await header(s)).index_released).toBeUndefined();
      expect(chain.log.some((l) => String(l.msg).includes('no longer in its chain'))).toBe(true);
    });

    test('a flip whose group became visible while it was flipping stops, having flipped what it had', async () => {
      const s = await committed();
      while (env.indexQueue.sent.length > 0) await chain.step();
      const flip = env.groupQueue.take()!;
      visibleBeforeNextWrite(s.gid);
      expect(await chain.runFlip(flip)).toMatchObject({ outcome: 'already' });
      expect((await header(s)).status).toBe('visible');
      expect((await rig.store.listAudit(`grp#${s.gid}`)).filter((a) => a.action === 'group_visible')).toHaveLength(0);
    });

    test('a flip for a group that has not committed flips nothing', async () => {
      const validating = await new Scenario(env, SPECS).start();
      expect(await chain.runFlip(flipOf(validating.gid))).toMatchObject({ outcome: 'skipped' });
      for (const n of NAMES) expect((await stored(n))!.state).toBe('pending');
    });

    test('a flip for another attempt than the one that committed, or for no group, does nothing', async () => {
      const s = await committed();
      while (env.indexQueue.sent.length > 0) await chain.step();
      expect(await chain.runFlip(flipOf(s.gid, 2))).toMatchObject({ outcome: 'skipped' });
      expect(await chain.runFlip(flipOf('grp_00000000000000000000000000000000'))).toMatchObject({ outcome: 'skipped' });
      for (const n of NAMES) expect((await stored(n))!.state).toBe('pending');
    });

    test('a committed group without its member list is a defect: the flip throws, so the message is retried and then alarms', async () => {
      const s = await committed();
      while (env.indexQueue.sent.length > 0) await chain.step();
      const flip = env.groupQueue.take()!;
      rig.dropGroupItem(`grpm#${s.gid}`);
      await expect(chain.runFlip(flip)).rejects.toThrow('member list is missing');
      expect((await header(s)).status).toBe('committed');
    });
  });

  describe('the start of the chain', () => {
    test('the commit queues the first repodata hop, in the FIFO group of the subdir, with the dedup id of the step', async () => {
      const s = await committed();
      expect(env.indexQueue.sent).toHaveLength(1);
      const m = env.indexQueue.sent[0]!;
      expect(JSON.parse(m.body)).toEqual({ type: 'index', subdir: 'linux-64', then: { group: { group_id: s.gid, attempt: 1, resend: 0 } } });
      expect(m.groupId).toBe('linux-64');
      expect(m.dedupId).toBe(`grp:${s.gid}:1:r-linux-64:0`);
      // A message of the group's validation that comes again after the commit (a redelivery) starts nothing twice: the queue drops the same step.
      await env.groupQueue.send({ body: JSON.stringify({ type: 'validate_group', group_id: s.gid, attempt: 1, n: 0 }), groupId: s.gid, dedupId: 'redelivered' });
      expect(await env.runGroupJob()).toBe('already');
      expect(env.indexQueue.sent).toHaveLength(1);
    });

    test('a validator that sees the group committed again queues the step that is next, and none once it is visible', async () => {
      const s = await committed();
      await chain.step();
      env.indexQueue = new MemoryQueue(); // the next step was lost, and the queue has forgotten the ids it saw
      await env.groupQueue.send({ body: JSON.stringify({ type: 'validate_group', group_id: s.gid, attempt: 1, n: 0 }), groupId: s.gid, dedupId: 'again' });
      expect(await env.runGroupJob()).toBe('already');
      expect(env.indexQueue.sent.map((m) => JSON.parse(m.body).subdir)).toEqual(['noarch']);
      await chain.drain();
      expect((await header(s)).status).toBe('visible');
      await env.groupQueue.send({ body: JSON.stringify({ type: 'validate_group', group_id: s.gid, attempt: 1, n: 0 }), groupId: s.gid, dedupId: 'again-2' });
      expect(await env.runGroupJob()).toBe('already');
      expect(env.indexQueue.sent).toEqual([]);
    });
  });

  describe('hops that are not for a group in its chain', () => {
    const hop = (gid: string, attempt = 1) => ({ group_id: gid, attempt, resend: 0 });
    const repodata = (subdir: string, h: object): QueueMessage => ({ body: JSON.stringify({ type: 'index', subdir, then: { group: h } }), groupId: subdir, dedupId: 'x' });
    const index = (name: string, position: number, h: object): QueueMessage => ({ body: JSON.stringify({ type: 'index_pkg', name, rev: 0, group: { ...h, position } }), groupId: `pkg:${name}`, dedupId: 'x' });

    test('a group that has not committed gets no gate set, no file written and nothing queued', async () => {
      const s = await new Scenario(env, SPECS).start(); // validating
      await chain.runIndex(repodata('noarch', hop(s.gid)));
      await chain.runIndex(index('base', 0, hop(s.gid)));
      expect([...files().keys()]).toEqual([]);
      expect(env.indexQueue.sent).toEqual([]);
      expect((await header(s)).repodata_released).toBeUndefined();
    });

    test('another attempt than the one that committed, a group that is gone and one that is visible do nothing', async () => {
      const s = await committed();
      await chain.runIndex(repodata('noarch', hop(s.gid, 2)));
      await chain.runIndex(repodata('noarch', hop('grp_00000000000000000000000000000000')));
      expect([...files().keys()]).toEqual([]);
      expect((await header(s)).repodata_released).toBeUndefined();

      await chain.drain();
      const done = files();
      const rev = (await header(s)).rev;
      await chain.runIndex(repodata('noarch', hop(s.gid)));
      await chain.runIndex(index('base', 0, hop(s.gid)));
      expect(files()).toEqual(done);
      expect((await header(s)).rev).toBe(rev);
    });

    test('a subdir the group has no file in, and a package that is not at that place of the write order, release nothing', async () => {
      const s = await committed();
      await chain.runIndex(repodata('osx-arm64', hop(s.gid)));
      expect((await header(s)).repodata_released).toBeUndefined();
      expect([...files().keys()]).toEqual([]);

      // Get the repodata out of the way, then name `lib` for position 0 (base's) and a position the order does not have.
      await chain.step();
      await chain.step();
      await chain.runIndex(index('lib', 0, hop(s.gid)));
      await chain.runIndex(index('lib', 7, hop(s.gid)));
      expect((await header(s)).index_released ?? []).toEqual([]);
      expect(indexed()).toEqual([]);
    });

    test('an index writer deployed without the group store or the group queue refuses a hop (it throws, so the message is retried and then alarms)', async () => {
      const s = await committed();
      const first = env.indexQueue.take()!;
      await expect(chain.runIndex(first, { groups: undefined })).rejects.toThrow('no group store');
      expect((await header(s)).repodata_released).toBeUndefined(); // refused before anything was released
      await expect(chain.runIndex(first, { groupQueue: undefined })).rejects.toThrow('no group queue');
      expect(env.indexQueue.sent).toEqual([]);
      // Configured, the same message goes on.
      await chain.runIndex(first);
      expect(env.indexQueue.sent.map((m) => m.groupId)).toEqual(['noarch']);
    });
  });

  describe('the sweeper looks after a committed group', () => {
    const sweep = (lines?: Array<Record<string, unknown>>) =>
      sweepGroups({ groups: rig.store, groupQueue: env.groupQueue, indexQueue: env.indexQueue, now: env.clock.now, metrics: new Metrics((l) => lines?.push(l)), log: (l) => chain.log.push(l) });
    /** The one message on the chain's queues, taken off. */
    const takeNext = () => env.indexQueue.take() ?? env.groupQueue.take();

    test.each(STEPS.map((step, k) => [step, k] as const))('a lost %s hop (message %i) is sent again by the sweeper once the group has been quiet for ten minutes, and the chain finishes', async (_step, k) => {
      const s = await committed();
      for (let i = 0; i < k; i++) await chain.step();
      const lost = takeNext()!;
      expect(lost).toBeDefined();
      expect(env.indexQueue.sent.length + env.groupQueue.sent.length).toBe(0);

      env.clock.advance(CHAIN_STALL_MS - MINUTE);
      expect(await sweep()).toMatchObject({ committed: 1, resent: [], gaveUp: [] });
      expect(env.indexQueue.sent.length + env.groupQueue.sent.length).toBe(0);

      env.clock.advance(2 * MINUTE);
      const r = await sweep();
      expect(r).toMatchObject({ committed: 1, resent: [s.gid], gaveUp: [] });
      expect((await header(s)).resend).toBe(1);
      const again = takeNext()!;
      // The same step, under a dedup id of its own: the queue still remembers the lost message's id and would have dropped a copy of it.
      expect(JSON.parse(again.body)).toEqual(JSON.parse(lost.body.replace(/"resend":0/g, '"resend":1')));
      expect(again.groupId).toBe(lost.groupId);
      expect(again.dedupId).toBe(lost.dedupId.replace(/:0$/, ':1'));

      // It is not sent again before the group has had the time again.
      env.clock.advance(5 * MINUTE);
      expect((await sweep()).resent).toEqual([]);

      (again.groupId === s.gid ? env.groupQueue : env.indexQueue).sent.unshift(again);
      await chain.drain();
      const h = await header(s);
      expect(h).toMatchObject({ status: 'visible', resend: 0 });
      expect(h.sweep_pk).toBeUndefined();
      expect(indexed()).toEqual(NAMES);
    });

    test('a resend with a new counter is not dropped, and a copy of the lost message under its old counter is', async () => {
      const s = await committed();
      const lost = env.indexQueue.take()!;
      const step = { kind: 'repodata' as const, subdir: 'linux-64' };
      // The lost message's id is in the queue's memory: sending the same step with the same counter is dropped...
      await sendStep(env, s.gid, 1, 0, step);
      expect(env.indexQueue.sent).toEqual([]);
      // ...and with the next counter it lands.
      await sendStep(env, s.gid, 1, 1, step);
      expect(env.indexQueue.sent.map((m) => m.dedupId)).toEqual([stepDedupId(s.gid, 1, step, 1)]);
      expect(lost.dedupId).toBe(stepDedupId(s.gid, 1, step, 0));
      expect(stepDedupId(s.gid, 1, step, 1)).not.toBe(lost.dedupId);
    });

    test('a chain that keeps stalling is resent three times and then left to a person, with the alarm metric', async () => {
      const s = await committed();
      const lines: Array<Record<string, unknown>> = [];
      const ids: string[] = [];
      takeNext(); // lost
      for (let k = 1; k <= MAX_RESENDS; k++) {
        env.clock.advance(CHAIN_STALL_MS + MINUTE);
        expect((await sweep(lines)).resent).toEqual([s.gid]);
        ids.push(takeNext()!.dedupId); // lost again
      }
      expect(ids).toEqual([1, 2, 3].map((n) => `grp:${s.gid}:1:r-linux-64:${n}`));
      env.clock.advance(CHAIN_STALL_MS + MINUTE);
      const last = await sweep(lines);
      expect(last).toMatchObject({ resent: [], gaveUp: [s.gid] });
      expect(env.indexQueue.sent).toEqual([]);
      expect(lines.map((l) => l.group_sweeper_gave_up)).toEqual([0, 0, 0, 1]);
      expect(await header(s)).toMatchObject({ status: 'committed', resend: MAX_RESENDS });
      expect(chain.log.some((l) => String(l.msg).includes('as often as it will'))).toBe(true);
    });

    test('a chain that is moving is left alone: each hop is a sign of life, and sets the resend count back', async () => {
      const s = await committed();
      for (let i = 0; i < 3; i++) {
        env.clock.advance(CHAIN_STALL_MS - MINUTE);
        expect((await sweep()).resent).toEqual([]);
        await chain.step();
      }
      expect((await header(s)).resend).toBe(0);
      // A resend, then a hop that makes progress: the count starts again.
      takeNext();
      env.clock.advance(CHAIN_STALL_MS + MINUTE);
      expect((await sweep()).resent).toEqual([s.gid]);
      expect((await header(s)).resend).toBe(1);
      await chain.drain();
      expect((await header(s)).status).toBe('visible');
    });

    test('a hop that saved progress between the sweeper reading the header and writing it is not resent', async () => {
      const s = await committed();
      env.clock.advance(CHAIN_STALL_MS + MINUTE);
      const update = rig.store.updateGroup.bind(rig.store);
      let first = true;
      rig.store.updateGroup = async (gid, fn, a) => {
        if (first) {
          first = false;
          await update(gid, (cur) => ({ ...cur, progress_at: env.clock.now().toISOString(), sweep_at: env.clock.now().toISOString() }));
        }
        return update(gid, fn, a);
      };
      expect((await sweep()).resent).toEqual([]);
      expect(env.indexQueue.sent).toHaveLength(1); // only the commit's own message
      expect((await header(s)).resend).toBe(0);
    });

    test('the oldest age counts a committed group too, and a group whose chain is done is not counted', async () => {
      const a = await committed();
      env.clock.advance(7 * MINUTE);
      const lines: Array<Record<string, unknown>> = [];
      expect((await sweep(lines)).oldestSeconds).toBe(7 * 60);
      expect(lines[0]!.group_oldest_nonterminal_age_seconds).toBe(7 * 60);
      await chain.drain();
      expect((await header(a)).status).toBe('visible');
      expect((await sweep()).oldestSeconds).toBe(0);
    });
  });

  describe('the messages of the chain', () => {
    const gid = `grp_${'a'.repeat(32)}`;
    const repodataMsg = { type: 'index', subdir: 'noarch', then: { group: { group_id: gid, attempt: 1, resend: 2 } } };
    const indexMsg = { type: 'index_pkg', name: 'base', rev: 0, group: { group_id: gid, attempt: 1, resend: 2, position: 4 } };

    test('parse as they were sent', () => {
      expect(parseIndexMessage(repodataMsg)).toEqual(repodataMsg);
      expect(parseIndexMessage(indexMsg)).toEqual(indexMsg);
      expect(parseIndexMessage({ ...indexMsg, group: undefined })).toEqual({ type: 'index_pkg', name: 'base', rev: 0 });
    });

    test.each([
      ['a group id that is not one', { ...repodataMsg, then: { group: { ...repodataMsg.then.group, group_id: 'grp_x' } } }],
      ['a negative attempt', { ...repodataMsg, then: { group: { ...repodataMsg.then.group, attempt: -1 } } }],
      ['a resend that is not a number', { ...repodataMsg, then: { group: { ...repodataMsg.then.group, resend: '1' } } }],
      ['a group that is not an object', { ...repodataMsg, then: { group: 'grp' } }],
      ['a group beside the fields of an unyank chain', { ...repodataMsg, then: { group: repodataMsg.then.group, name: 'demo', rev: 1, next: [] } }],
      ['a then that is not an object', { type: 'index', subdir: 'noarch', then: null }],
      ['an index hop with no position', { ...indexMsg, group: { ...indexMsg.group, position: undefined } }],
      ['an index hop with a position that is not a number', { ...indexMsg, group: { ...indexMsg.group, position: '1' } }],
      ['an index hop with a bad group', { ...indexMsg, group: { ...indexMsg.group, attempt: 1.5 } }],
      ['an index hop for a name that is not a package', { ...indexMsg, name: 'x/y' }],
    ])('are refused when they carry %s', (_what, body) => {
      expect(parseIndexMessage(body)).toBeUndefined();
    });
  });
});
