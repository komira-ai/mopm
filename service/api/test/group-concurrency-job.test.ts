import { route } from '../src/http/router';
import { API_VIEW, INDEX_VIEW, repodataView } from '../src/group';
import { validateGroup } from '../src/publish/group-validator';
import { allRecords } from '../src/publish/indexer';
import type { VersionRecord } from '../src/types';
import { RIGS, type Rig } from './group-rig';
import { GroupEnv } from './publish/group-env';
import { Scenario } from './publish/group-scenario';

/**
 * The same readers as group-concurrency.test.ts (300 of six kinds, over a group of 24 packages in two subdirs), but the
 * writer is the real thing: the group's validator opens 24 archives, stages each member row, copies the files and commits the
 * group, on the registry adapter itself, while the readers run. The readers are launched while the job runs and after it ends,
 * so some read before the commit, some across it and some after it. A logical clock stamps every read at its start and end, and
 * the commit at its start and at its acknowledgement.
 *
 * What it proves, for each seed and adapter:
 *   - a multi-package API read (versionsOf, search) shows none of the group or all of it, whatever the stage of the job;
 *   - a one-package read shows nothing if it ended before the commit began, and the member if it began after the commit was acknowledged;
 *   - once any API read has shown the group, no read that starts later shows it hidden;
 *   - the builders (repodata, index) list none of the group: its release gates are set by the chain that follows a commit, which is
 *     a later change, so a committed group is in no file yet;
 *   - when the job is done, every reader shows the whole group.
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
  const message = JSON.parse(env.groupQueue.sent[0]!.body);

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

  const shownIn = (vs: VersionRecord[]) => vs.filter((v) => v.state !== 'pending').length;
  const get = async (path: string, query: Record<string, string> = {}) =>
    JSON.parse((await route({ method: 'GET', path, query }, { store: rig.store, stage: 'beta', version: 't', commit: 't', readOnly: false }, 'req')).body);

  const reads: Read[] = [];
  const read = async () => {
    const kind = KINDS[Math.floor(rnd() * KINDS.length)]!;
    const member = NAMES[Math.floor(rnd() * N)]!;
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
        shown = (await rig.store.getVersion(member, '1.0.0'))!.state === 'pending' ? 0 : 1;
        break;
      case 'getPackage':
        shown = (await get(`/api/v1/packages/${member}`)).latest === null ? 0 : 1;
        break;
      case 'repodata':
        shown = (await allRecords(rig.store, repodataView(subdir))).filter((v) => v.state !== 'pending' && v.group_id !== undefined).length;
        break;
      case 'index':
        shown = shownIn((await rig.store.versionsOf([member], INDEX_VIEW)).get(member)!);
        break;
    }
    reads.push({ kind, start, end: tick(), shown });
  };

  let finished = false;
  const job = validateGroup(env.validatorDeps(), message).then((out) => {
    finished = true;
    return out;
  });
  const readers: Array<Promise<void>> = [];
  while (!finished && readers.length < 200) {
    readers.push(read());
    await hops(25);
  }
  const outcome = await job;
  while (readers.length < 300) readers.push(read());
  await Promise.all(readers);
  return { rig, reads, marks, outcome, s };
}

describe.each(RIGS)('readers against the real validator committing a group of 24: %s', (_label, makeRig) => {
  describe.each([1, 2, 3])('seed %i', (seed) => {
    let run: Awaited<ReturnType<typeof simulate>>;
    beforeAll(async () => {
      run = await simulate(makeRig, seed);
    }, 120_000);
    const of = (...kinds: Kind[]) => run.reads.filter((x) => kinds.includes(x.kind));

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

    test('a build lists no member of the group: nothing has released it into a file', () => {
      for (const x of of('repodata', 'index')) expect(x.shown).toBe(0);
    });

    test('when the job is done every reader shows the whole group', async () => {
      const { rig } = run;
      expect([...(await rig.store.versionsOf(NAMES, API_VIEW)).values()].every((vs) => vs[0]!.state === 'published')).toBe(true);
      expect((await rig.store.getGroup(run.s.gid))!.status).toBe('committed');
      // And the channel holds all 24 files.
      expect(run.s.channelFiles()).toHaveLength(N);
    });
  });
});
