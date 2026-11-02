import { route } from '../src/http/router';
import { API_VIEW, INDEX_VIEW, repodataView } from '../src/group';
import { validateGroup } from '../src/publish/group-validator';
import { allRecords } from '../src/publish/indexer';
import type { VersionRecord } from '../src/types';
import { RIGS, type Rig } from './group-rig';
import { Chain, label } from './publish/group-chain-env';
import { GroupEnv } from './publish/group-env';
import { Scenario } from './publish/group-scenario';

/**
 * The same readers as group-concurrency.test.ts (300 of six kinds, over a group of 24 packages in two subdirs), but the
 * writer is the real thing: the group's validator opens 24 archives, stages each member row, copies the files and commits the
 * group, on the registry adapter itself, while the readers run; and then the chain that follows the commit (a repodata hop for
 * each subdir, an index hop for each member, the flip) runs on the same adapter while a second set of 300 readers runs. The
 * readers are launched while a writer runs and after it ends, so some read before a step, some across it and some after it. A
 * logical clock stamps every read at its start and end, the commit at its start and at its acknowledgement, and each gate of the
 * chain at the start and at the acknowledgement of the header write that set it.
 *
 * What it proves, for each seed and adapter:
 *   - a multi-package API read (versionsOf, search) shows none of the group or all of it, whatever the stage of the job;
 *   - a one-package read shows nothing if it ended before the commit began, and the member if it began after the commit was acknowledged;
 *   - once any API read has shown the group, no read that starts later shows it hidden;
 *   - until the chain runs, the builders (repodata, index) list none of the group;
 *   - during the chain, every API read shows the whole group (it has committed), and a build lists exactly the members released
 *     so far: a repodata build none of a subdir's members before its gate was set and all of them after, an index build a member's
 *     file content only once its gate was set;
 *   - when the chain is done, the group is visible and every reader shows the whole group.
 */

const N = 24;
const NAMES = Array.from({ length: N }, (_, i) => `m${String(i).padStart(2, '0')}`);
const SUBDIRS = ['noarch', 'linux-64'] as const;

function prng(seed: number): () => number {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

type Kind = 'versionsOf' | 'search' | 'getVersion' | 'getPackage' | 'repodata' | 'index';
const KINDS: Kind[] = ['versionsOf', 'search', 'getVersion', 'getPackage', 'repodata', 'index'];
interface Read {
  kind: Kind;
  start: number;
  end: number;
  shown: number;
  /** The member, for a read of one package (an index into NAMES). */
  member?: number;
  /** The subdir, for a repodata build. */
  subdir?: string;
}

async function simulate(makeRig: () => Rig, seed: number) {
  const rnd = prng(seed);
  const rig = makeRig();
  const env = new GroupEnv(rig);
  // Packages that search lists (claimed ones are not "active").
  for (const n of NAMES) await rig.claim(n);
  const s = new Scenario(
    env,
    NAMES.map((name, i) => ({ name, subdir: SUBDIRS[i % 2]! })),
  );
  await s.create();
  await s.upload();
  expect((await s.commit()).statusCode).toBe(202);
  const message = JSON.parse(env.groupQueue.take()!.body); // the validation, run below by hand

  let clock = 0;
  const tick = () => ++clock;
  const hops = async (max: number) => {
    for (let k = Math.floor(rnd() * max); k > 0; k--) await Promise.resolve();
  };
  const marks = { commitStart: Infinity, commitAck: Infinity };
  const commit = rig.store.commitGroup.bind(rig.store);
  rig.store.commitGroup = async (gid, c) => {
    marks.commitStart = tick();
    const out = await commit(gid, c);
    marks.commitAck = tick();
    return out;
  };
  // Each gate of the chain (`r:<subdir>`, `i:<position>`) is stamped when the header write that set it starts and when it is acknowledged.
  const gates = { start: new Map<string, number>(), ack: new Map<string, number>() };
  const update = rig.store.updateGroup.bind(rig.store);
  rig.store.updateGroup = async (gid, fn, audit) => {
    const start = tick();
    const after = await update(gid, fn, audit);
    const ack = tick();
    if (after) {
      for (const k of [...(after.repodata_released ?? []).map((x) => `r:${x}`), ...(after.index_released ?? []).map((p) => `i:${p}`)]) {
        if (!gates.start.has(k)) {
          gates.start.set(k, start);
          gates.ack.set(k, ack);
        }
      }
    }
    return after;
  };

  const shownIn = (vs: VersionRecord[]) => vs.filter((v) => v.state !== 'pending').length;
  const get = async (path: string, query: Record<string, string> = {}) =>
    JSON.parse((await route({ method: 'GET', path, query }, { store: rig.store, stage: 'beta', version: 't', commit: 't', readOnly: false }, 'req')).body);

  const read = async (sink: Read[]) => {
    const kind = KINDS[Math.floor(rnd() * KINDS.length)]!;
    const member = Math.floor(rnd() * N);
    const name = NAMES[member]!;
    const subdir = SUBDIRS[Math.floor(rnd() * 2)]!;
    const start = tick();
    let shown = 0;
    switch (kind) {
      case 'versionsOf':
        shown = [...(await rig.store.versionsOf(NAMES, API_VIEW)).values()].reduce((n, vs) => n + shownIn(vs), 0);
        break;
      case 'search':
        shown = (await get('/api/v1/packages', { limit: '100' })).packages.filter((p: { name: string; latest: string | null }) => NAMES.includes(p.name) && p.latest !== null).length;
        break;
      case 'getVersion':
        shown = (await rig.store.getVersion(name, '1.0.0'))!.state === 'pending' ? 0 : 1;
        break;
      case 'getPackage':
        shown = (await get(`/api/v1/packages/${name}`)).latest === null ? 0 : 1;
        break;
      case 'repodata':
        shown = (await allRecords(rig.store, repodataView(subdir))).filter((v) => v.state !== 'pending' && v.group_id !== undefined && v.files[0]?.subdir === subdir).length;
        break;
      case 'index':
        shown = shownIn((await rig.store.versionsOf([name], INDEX_VIEW)).get(name)!);
        break;
    }
    sink.push({ kind, start, end: tick(), shown, member, subdir });
  };

  // Phase 1: the validator runs, with readers launched while it does and after it.
  const reads: Read[] = [];
  let finished = false;
  const job = validateGroup(env.validatorDeps(), message).then((out) => {
    finished = true;
    return out;
  });
  const readers: Array<Promise<void>> = [];
  while (!finished && readers.length < 200) {
    readers.push(read(reads));
    await hops(25);
  }
  const outcome = await job;
  while (readers.length < 300) readers.push(read(reads));
  await Promise.all(readers);

  // Phase 2: the chain runs one message at a time, with 300 readers each starting after a random number of event-loop hops.
  const chain = new Chain(env);
  const chainReads: Read[] = [];
  const ran: string[] = [];
  let chainDone = false;
  const driver = (async () => {
    // Let the first readers finish before the first gate is set.
    for (let k = 400 + Math.floor(rnd() * 100); k > 0; k--) await Promise.resolve();
    for (;;) {
      await hops(60);
      const step = await chain.step();
      if (!step) break;
      ran.push(label(step));
    }
    chainDone = true;
  })();
  const readers2: Array<Promise<void>> = [];
  while (!chainDone && readers2.length < 200) {
    readers2.push(read(chainReads));
    await hops(25);
  }
  await driver;
  while (readers2.length < 300) readers2.push(read(chainReads));
  await Promise.all(readers2);
  return { rig, reads, chainReads, marks, gates, ran, outcome, s };
}

describe.each(RIGS)('readers against the real validator committing a group of 24: %s', (_label, makeRig) => {
  describe.each([1, 2, 3])('seed %i', (seed) => {
    let run: Awaited<ReturnType<typeof simulate>>;
    beforeAll(async () => {
      run = await simulate(makeRig, seed);
    }, 120_000);
    const of = (...kinds: Kind[]) => run.reads.filter((x) => kinds.includes(x.kind));
    const duringChain = (...kinds: Kind[]) => run.chainReads.filter((x) => kinds.includes(x.kind));

    test('the job committed the group, all 300 reads finished, and the run is not trivial: reads came before and after the commit', () => {
      expect(run.outcome).toBe('committed');
      expect(run.reads).toHaveLength(300);
      expect(run.reads.some((x) => x.end < run.marks.commitStart)).toBe(true);
      expect(run.reads.some((x) => x.start > run.marks.commitAck)).toBe(true);
    });

    test('a multi-package API read shows none of the group or all of it', () => {
      for (const x of of('versionsOf', 'search')) expect([0, N]).toContain(x.shown);
    });

    test('a read that ended before the commit began shows nothing, and one that began after it was acknowledged shows the whole group', () => {
      for (const x of of('versionsOf', 'search', 'getVersion', 'getPackage')) {
        if (x.end < run.marks.commitStart) expect(x.shown).toBe(0);
      }
      for (const x of of('versionsOf', 'search')) if (x.start > run.marks.commitAck) expect(x.shown).toBe(N);
      for (const x of of('getVersion', 'getPackage')) if (x.start > run.marks.commitAck) expect(x.shown).toBe(1);
    });

    test('once any API read has shown the group, no read that starts later shows it hidden', () => {
      const api = of('versionsOf', 'search', 'getVersion', 'getPackage');
      for (const seen of api.filter((x) => x.shown > 0)) {
        for (const later of api.filter((x) => x.start > seen.end)) expect(later.shown).toBeGreaterThan(0);
      }
    });

    test('until the chain runs, a build lists no member of the group: nothing has released it into a file', () => {
      for (const x of of('repodata', 'index')) expect(x.shown).toBe(0);
    });

    test('the chain ran its 27 steps in order (two repodata hops, 24 index hops, the flip) while 300 more readers read, and the readers saw it at work', () => {
      expect(run.ran).toEqual(['repodata linux-64', 'repodata noarch', ...NAMES.map((n) => `index ${n}`), 'flip']);
      expect(run.chainReads).toHaveLength(300);
      // Reads before the first gate, between the gates and after the last one: the interleaving is not trivial.
      const first = run.gates.start.get('r:linux-64')!;
      const lastAck = run.gates.ack.get(`i:${N - 1}`)!;
      expect(run.chainReads.some((x) => x.end < first)).toBe(true);
      expect(run.chainReads.some((x) => x.start > first && x.end < lastAck)).toBe(true);
      expect(run.chainReads.some((x) => x.start > lastAck)).toBe(true);
    });

    test('during the chain every API read shows the whole group, because the group has committed', () => {
      for (const x of duringChain('versionsOf', 'search')) expect(x.shown).toBe(N);
      for (const x of duringChain('getVersion', 'getPackage')) expect(x.shown).toBe(1);
    });

    test('during the chain a repodata build lists a subdir\'s members once the subdir was released, none before, and never part of them', () => {
      for (const x of duringChain('repodata')) {
        const gateStart = run.gates.start.get(`r:${x.subdir}`)!;
        const gateAck = run.gates.ack.get(`r:${x.subdir}`)!;
        expect([0, N / 2]).toContain(x.shown);
        if (x.end < gateStart) expect(x.shown).toBe(0);
        if (x.start > gateAck) expect(x.shown).toBe(N / 2);
      }
    });

    test('during the chain an index build lists a member once its place in the write order was released, and not before', () => {
      for (const x of duringChain('index')) {
        // The members have no dependencies among them, so the write order is the name order: position = member index.
        const gateStart = run.gates.start.get(`i:${x.member}`)!;
        const gateAck = run.gates.ack.get(`i:${x.member}`)!;
        if (x.end < gateStart) expect(x.shown).toBe(0);
        if (x.start > gateAck) expect(x.shown).toBe(1);
      }
    });

    test('an index gate is never set before every repodata gate, nor before the gate of the position before it', () => {
      const lastRepodata = Math.max(...SUBDIRS.map((sd) => run.gates.start.get(`r:${sd}`)!));
      for (let p = 0; p < N; p++) {
        expect(run.gates.start.get(`i:${p}`)!).toBeGreaterThan(lastRepodata);
        if (p > 0) expect(run.gates.start.get(`i:${p}`)!).toBeGreaterThan(run.gates.ack.get(`i:${p - 1}`)!);
      }
    });

    test('when the chain is done the group is visible, every row is published and every reader shows the whole group', async () => {
      const { rig } = run;
      expect([...(await rig.store.versionsOf(NAMES, API_VIEW)).values()].every((vs) => vs[0]!.state === 'published')).toBe(true);
      expect(await rig.store.getGroup(run.s.gid)).toMatchObject({ status: 'visible' });
      for (const n of NAMES) expect((await rig.store.raw.rawGet(n, '1.0.0'))!.state).toBe('published');
      for (const sd of SUBDIRS) expect((await allRecords(rig.store, repodataView(sd))).filter((v) => v.state === 'published' && v.files[0]?.subdir === sd)).toHaveLength(N / 2);
      // And the channel holds all 24 files.
      expect(run.s.channelFiles().filter((k) => k.endsWith('.conda'))).toHaveLength(N);
    });
  });
});
