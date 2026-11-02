import { route } from '../src/http/router';
import { API_VIEW, INDEX_VIEW, repodataView } from '../src/group';
import { allRecords } from '../src/publish/indexer';
import type { VersionRecord } from '../src/types';
import { hex } from './helpers';
import { header, memberList, reserved, RIGS, staged, type Rig } from './group-rig';

/**
 * Readers of every kind against one group of 24 members (24 packages, two subdirs) while the group is staged,
 * committed and released. The commit and the releases land after a seeded random number of event-loop hops, so they
 * fall between the steps of whichever reads are in flight. Every read is stamped with a logical clock at its start
 * and end, and the writer stamps the clock at each commit and release.
 *
 * What it proves, for each interleaving:
 *   - a multi-package API read (versionsOf, search) shows none of the group or all of it;
 *   - a one-package read (getVersion, GET package) shows the member iff the group had committed: not if the read
 *     ended before the commit, and always if it started after;
 *   - once any read has shown the group, no read that starts later shows it hidden;
 *   - a build shows a member only once its gate is set: none if it ended before the gate, all if it started after,
 *     and a repodata build lists none of a subdir's members or all of them.
 * Both adapters. The two reads paused at a chosen step (after the rows were read, between the package list and the
 * reads) are in group.test.ts, where the pause is exact.
 */

const N = 24;
const NAMES = Array.from({ length: N }, (_, i) => `m${String(i).padStart(2, '0')}`);
const SUBDIRS = ['noarch', 'linux-64'] as const;
const subdirOf = (i: number) => SUBDIRS[i % 2]!;
const WRITE_ORDER = NAMES.map((_n, i) => i);

const fileOf = (i: number) => ({
  subdir: subdirOf(i),
  filename: `mojo-${NAMES[i]}-1.0.0-mojo1.0.0_0.conda`,
  sha256: hex('a'),
  size: 10,
  url: `https://conda.example.invalid/${subdirOf(i)}/mojo-${NAMES[i]}-1.0.0-mojo1.0.0_0.conda`,
});
const stagedRow = (i: number) => staged(NAMES[i]!, 'g1', 1, { files: [fileOf(i)] });

/** A small seeded generator (mulberry32), so a failing interleaving can be replayed from its seed. */
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

type Mode = 'fully staged' | 'staged while the readers run' | 'committed right after the last stage';
type Kind = 'versionsOf' | 'search' | 'getVersion' | 'getPackage' | 'repodata' | 'index';
const KINDS: Kind[] = ['versionsOf', 'search', 'getVersion', 'getPackage', 'repodata', 'index'];

interface Read {
  kind: Kind;
  start: number;
  end: number;
  /** How many of the group's members (of the subdir, for repodata) the read showed. */
  shown: number;
  /** The member, for a one-package read. */
  member?: number;
  subdir?: string;
}

async function simulate(makeRig: () => Rig, seed: number, mode: Mode) {
  const rnd = prng(seed);
  const r = makeRig();
  for (const n of NAMES) await r.claim(n);
  r.putGroupItem('grpm#g1', memberList(...NAMES));
  r.putGroupItem('grp#g1', { status: 'validating', attempt: 1 });
  NAMES.forEach((n, i) => r.writeRow(mode === 'fully staged' ? stagedRow(i) : reserved(n, 'g1')));

  let clock = 0;
  const tick = () => ++clock;
  // Hops of the event loop (microtasks), so a write can land between the steps of a read that is in flight.
  const hops = async (max: number) => {
    for (let k = Math.floor(rnd() * max); k > 0; k--) await Promise.resolve();
  };
  const marks = { committed: Infinity, repodata: Infinity, index: NAMES.map(() => Infinity) };

  const writer = (async () => {
    await hops(800);
    if (mode !== 'fully staged') {
      for (let i = 0; i < N; i++) {
        r.writeRow(stagedRow(i));
        await hops(40);
      }
    }
    if (mode !== 'committed right after the last stage') await hops(800);
    marks.committed = tick();
    r.putGroupItem('grp#g1', header({ write_order: WRITE_ORDER }));
    await hops(800);
    marks.repodata = tick();
    r.putGroupItem('grp#g1', header({ write_order: WRITE_ORDER, repodata_released: [...SUBDIRS] }));
    for (let i = 0; i < N; i++) {
      await hops(60);
      marks.index[i] = tick();
      r.putGroupItem('grp#g1', header({ write_order: WRITE_ORDER, repodata_released: [...SUBDIRS], index_released: WRITE_ORDER.slice(0, i + 1) }));
    }
  })();

  const shownIn = (vs: VersionRecord[]) => vs.filter((v) => v.state !== 'pending').length;
  const get = async (path: string, query: Record<string, string> = {}) =>
    JSON.parse((await route({ method: 'GET', path, query }, { store: r.store, stage: 'beta', version: 't', commit: 't', readOnly: false }, 'req')).body);

  const reads: Read[] = [];
  const readers = Array.from({ length: 300 }, () =>
    (async () => {
      await hops(2400);
      const kind = KINDS[Math.floor(rnd() * KINDS.length)]!;
      const member = Math.floor(rnd() * N);
      const subdir = SUBDIRS[Math.floor(rnd() * 2)]!;
      const start = tick();
      let shown = 0;
      switch (kind) {
        case 'versionsOf':
          shown = [...(await r.store.versionsOf(NAMES, API_VIEW)).values()].reduce((n, vs) => n + shownIn(vs), 0);
          break;
        case 'search':
          shown = (await get('/api/v1/packages', { limit: '100' })).packages.filter((p: { latest: string | null }) => p.latest !== null).length;
          break;
        case 'getVersion':
          shown = (await r.store.getVersion(NAMES[member]!, '1.0.0'))!.state === 'pending' ? 0 : 1;
          break;
        case 'getPackage':
          shown = (await get(`/api/v1/packages/${NAMES[member]}`)).latest === null ? 0 : 1;
          break;
        case 'repodata':
          shown = (await allRecords(r.store, repodataView(subdir))).filter((v) => v.state !== 'pending' && v.files[0]?.subdir === subdir).length;
          break;
        case 'index':
          shown = shownIn((await r.store.versionsOf([NAMES[member]!], INDEX_VIEW)).get(NAMES[member]!)!);
          break;
      }
      reads.push({ kind, start, end: tick(), shown, ...(kind === 'getVersion' || kind === 'getPackage' || kind === 'index' ? { member } : {}), ...(kind === 'repodata' ? { subdir } : {}) });
    })(),
  );
  await Promise.all([writer, ...readers]);
  return { r, reads, marks };
}

describe.each(RIGS)('readers against a group of 24 that is staged, committed and released: %s', (_label, makeRig) => {
  describe.each<Mode>(['fully staged', 'staged while the readers run', 'committed right after the last stage'])('%s', (mode) => {
    describe.each([1, 2, 3])('seed %i', (seed) => {
      let run: Awaited<ReturnType<typeof simulate>>;
      beforeAll(async () => {
        run = await simulate(makeRig, seed, mode);
      }, 60_000);

      const of = (...kinds: Kind[]) => run.reads.filter((x) => kinds.includes(x.kind));

      test('all 300 reads finished, and the run is not trivial: reads came before and after the commit', () => {
        expect(run.reads).toHaveLength(300);
        expect(run.reads.some((x) => x.end < run.marks.committed)).toBe(true);
        expect(run.reads.some((x) => x.start > run.marks.committed)).toBe(true);
      });

      test('a multi-package API read shows none of the group or all of it', () => {
        for (const x of of('versionsOf', 'search')) expect([0, N]).toContain(x.shown);
      });

      test('a one-package read shows the member iff the group had committed', () => {
        for (const x of of('getVersion', 'getPackage')) {
          if (x.end < run.marks.committed) expect(x.shown).toBe(0);
          if (x.start > run.marks.committed) expect(x.shown).toBe(1);
        }
        for (const x of of('versionsOf', 'search')) {
          if (x.end < run.marks.committed) expect(x.shown).toBe(0);
          if (x.start > run.marks.committed) expect(x.shown).toBe(N);
        }
      });

      test('once any read has shown the group, no read that starts later shows it hidden', () => {
        const api = of('versionsOf', 'search', 'getVersion', 'getPackage');
        for (const seen of api.filter((x) => x.shown > 0)) {
          for (const later of api.filter((x) => x.start > seen.end)) expect(later.shown).toBeGreaterThan(0);
        }
      });

      test('a build lists a member only once its gate is set', () => {
        for (const x of of('repodata')) {
          expect([0, N / 2]).toContain(x.shown);
          if (x.end < run.marks.repodata) expect(x.shown).toBe(0);
          if (x.start > run.marks.repodata) expect(x.shown).toBe(N / 2);
        }
        for (const x of of('index')) {
          if (x.end < run.marks.index[x.member!]!) expect(x.shown).toBe(0);
          if (x.start > run.marks.index[x.member!]!) expect(x.shown).toBe(1);
        }
      });

      test('when everything has landed, every reader shows the whole group', async () => {
        const { r } = run;
        expect([...(await r.store.versionsOf(NAMES, API_VIEW)).values()].every((vs) => vs[0]!.state === 'published')).toBe(true);
        for (const sub of SUBDIRS) {
          expect((await allRecords(r.store, repodataView(sub))).filter((v) => v.state === 'published' && v.files[0]?.subdir === sub)).toHaveLength(N / 2);
        }
        for (const n of NAMES) expect((await r.store.versionsOf([n], INDEX_VIEW)).get(n)![0]!.state).toBe('published');
      });
    });
  });
});
