import { route, type HttpResponse } from '../src/http/router';
import { indexKey } from '../src/index-files';
import { indexPackage, indexSubdir, indexTakedowns, type IndexerDeps } from '../src/publish/indexer';
import { DEFAULT_PUBLISH_CONFIG } from '../src/publish/config';
import { MemoryInvalidator, MemoryObjectStore, MemoryPresigner, MemoryPublishStore, MemoryQueue } from '../src/publish/memory';
import { PublishError } from '../src/publish/errors';
import { PublishService } from '../src/publish/service';
import { RegistryError } from '../src/errors';
import type { Principal } from '../src/auth';
import { hex, rec } from './helpers';
import { COMMITTED_AT, flipped, header, reserved, seedGroup, staged, type Rig } from './group-rig';

/**
 * The leak table: what every reader of version rows shows of a fixture that has one group in each state a reader can
 * meet, and which of them must show it. A surface is one way to read: a store method, a route, a builder, quota,
 * yank. It answers with the set of fixture packages whose version it shows.
 *
 * The fixture (every member is `<name> 1.0.0`, one file in linux-64 of 1000 bytes):
 *   plain           a published row with no group (the control)
 *   u1 u2           group gu: staged, the group has not committed
 *   c1 c2           group gc: committed, not flipped; the repodata gate for linux-64 is set and so is the index gate of c1 only
 *   f1 f2           group gf: committed and flipped, header `visible`
 *   r1 r2           group gr: not committed; r1 staged, r2 only reserved (no files, no stamp)
 *   h1              a staged row that names group gh, which has no header
 *   s1              group gs, committed at attempt 2; the row carries attempt 1 (only with `stale`)
 */
export const PLAIN = ['plain'];
export const GROUP_MEMBERS = ['u1', 'u2', 'c1', 'c2', 'f1', 'f2', 'r1', 'r2', 'h1'];
export const STALE_MEMBER = 's1';

export async function seedLeakFixture(r: Rig, opts: { stale?: boolean } = {}): Promise<string[]> {
  const names = [...PLAIN, ...GROUP_MEMBERS, ...(opts.stale ? [STALE_MEMBER] : [])];
  for (const n of names) await r.claim(n);
  r.writeRow(rec({ name: 'plain', version: '1.0.0' }));
  seedGroup(r, 'gu', { status: 'validating', attempt: 1 }, ['u1', 'u2'], [staged('u1', 'gu'), staged('u2', 'gu')]);
  seedGroup(r, 'gc', header({ repodata_released: ['linux-64'], write_order: [0, 1], index_released: [0] }), ['c1', 'c2'], [staged('c1', 'gc'), staged('c2', 'gc')]);
  seedGroup(r, 'gf', header({ status: 'visible' }), ['f1', 'f2'], [flipped('f1', 'gf'), flipped('f2', 'gf')]);
  seedGroup(r, 'gr', { status: 'validating', attempt: 1 }, ['r1', 'r2'], [staged('r1', 'gr'), reserved('r2', 'gr')]);
  seedGroup(r, 'gh', null, ['h1'], [staged('h1', 'gh')]);
  if (opts.stale) seedGroup(r, 'gs', header({ attempt: 2 }), [STALE_MEMBER], [staged(STALE_MEMBER, 'gs', 1)]);
  return names;
}

/** The members every API reader shows: committed groups (flipped or not) and the control. */
export const API_VISIBLE = new Set(['plain', 'c1', 'c2', 'f1', 'f2']);
/** What the repodata of linux-64 lists: the same, because the group's repodata gate is set. */
export const REPODATA_VISIBLE = API_VISIBLE;
/** What the package index files hold: only c1 of the unflipped group, whose index gate is set. */
export const INDEX_VISIBLE = new Set(['plain', 'c1', 'f1', 'f2']);

export type Surface = (r: Rig, names: string[]) => Promise<Set<string>>;

const principal: Principal = { token_id: 'tok1', kind: 'api', github_id: 7, scopes: ['publish', 'yank'], packages: [] };

const shown = (names: string[], flags: boolean[]) => new Set(names.filter((_n, i) => flags[i]));
const notPending = (vs: Array<{ state: string }>) => vs.some((v) => v.state !== 'pending');

async function get(r: Rig, path: string, query: Record<string, string> = {}): Promise<HttpResponse> {
  return route({ method: 'GET', path, query }, { store: r.store, stage: 'beta', version: 't', commit: 't', readOnly: false }, 'req');
}

async function service(r: Rig, names: string[]) {
  for (const n of names) await r.store.addOwner({ name: n, github_id: 7, handle: 'octocat', added_at: COMMITTED_AT });
  const indexQueue = new MemoryQueue();
  const svc = new PublishService({
    registry: r.store,
    publishes: new MemoryPublishStore(),
    objects: new MemoryObjectStore(),
    presigner: new MemoryPresigner(),
    validateQueue: new MemoryQueue(),
    indexQueue,
    // Room for one more of 600 bytes only if the 1000 bytes of the package's own file are not counted.
    config: { ...DEFAULT_PUBLISH_CONFIG, projectQuotaBytes: 1500 },
    now: () => new Date('2026-10-14T10:00:00Z'),
  });
  return { svc, indexQueue };
}

function indexerDeps(r: Rig) {
  const objects = new MemoryObjectStore();
  const deps: IndexerDeps = {
    registry: r.store,
    publishes: new MemoryPublishStore(),
    objects,
    invalidator: new MemoryInvalidator(),
    indexQueue: new MemoryQueue(),
    log: () => undefined,
    ensured: new Set(),
  };
  return { deps, objects };
}

/** Surfaces over the API view: every one of them must show exactly API_VISIBLE. */
export const API_SURFACES: Record<string, Surface> = {
  'store.getVersion': async (r, names) => shown(names, await Promise.all(names.map(async (n) => notPending([(await r.store.getVersion(n, '1.0.0')) ?? { state: 'pending' }])))),
  'store.listVersions': async (r, names) => shown(names, await Promise.all(names.map(async (n) => notPending(await r.store.listVersions(n))))),
  'store.versionsOf(api)': async (r, names) => {
    const m = await r.store.versionsOf(names, { kind: 'api' });
    return shown(names, names.map((n) => notPending(m.get(n)!)));
  },
  'GET /packages/{name}': async (r, names) => shown(names, await Promise.all(names.map(async (n) => JSON.parse((await get(r, `/api/v1/packages/${n}`)).body).latest !== null))),
  'GET /packages/{name}/versions': async (r, names) =>
    shown(names, await Promise.all(names.map(async (n) => JSON.parse((await get(r, `/api/v1/packages/${n}/versions`)).body).versions.length > 0))),
  'GET /packages/{name}/{version}': async (r, names) => shown(names, await Promise.all(names.map(async (n) => (await get(r, `/api/v1/packages/${n}/1.0.0`)).statusCode === 200))),
  'GET /packages': async (r, names) => {
    const body = JSON.parse((await get(r, '/api/v1/packages', { limit: '100' })).body);
    const latest = new Map<string, string | null>(body.packages.map((p: { name: string; latest: string | null }) => [p.name, p.latest]));
    return shown(names, names.map((n) => typeof latest.get(n) === 'string'));
  },
  // A file of 600 bytes does not fit beside the 1000 bytes of a version the registry shows (the quota is 1500).
  'begin: project quota counts the live bytes': async (r, names) => {
    const { svc } = await service(r, names);
    const counted = await Promise.all(
      names.map(async (n) => {
        try {
          await svc.begin(principal, n, '2.0.0', { subdir: 'linux-64', filename: `mojo-${n}-2.0.0-mojo1.0.0_0.conda`, sha256: hex('b'), size: 600 });
          return false;
        } catch (err) {
          if (err instanceof PublishError && err.code === 'limit_exceeded') return true;
          throw err;
        }
      }),
    );
    return shown(names, counted);
  },
  // Only a published version can be yanked: yanking is the probe of whether the row reads `published`.
  'setYanked: only a shown version can be yanked': async (r, names) => {
    const { svc } = await service(r, names);
    const yanked = await Promise.all(
      names.map(async (n) => {
        try {
          await svc.setYanked(principal, n, '1.0.0', { yanked: true, reason: 'probe' });
          return true;
        } catch (err) {
          if (err instanceof RegistryError && err.code === 'invalid_transition') return false;
          throw err;
        }
      }),
    );
    return shown(names, yanked);
  },
};

/** Surfaces over the build view: the repodata of linux-64 lists the gated members, and the package index files hold the index-gated ones. */
export const BUILD_SURFACES: Record<string, { expect: Set<string>; surface: Surface }> = {
  'indexSubdir(linux-64)': {
    expect: REPODATA_VISIBLE,
    surface: async (r, names) => {
      const { deps, objects } = indexerDeps(r);
      await indexSubdir(deps, { type: 'index', subdir: 'linux-64' });
      const listed = new Set(Object.values(JSON.parse(objects.objects.get('linux-64/repodata.json')!.body.toString('utf8'))['packages.conda'] as Record<string, { name: string }>).map((e) => e.name.slice('mojo-'.length)));
      return new Set(names.filter((n) => listed.has(n)));
    },
  },
  'indexPackage': {
    expect: INDEX_VISIBLE,
    surface: async (r, names) => {
      const { deps, objects } = indexerDeps(r);
      for (const n of names) await indexPackage(deps, { type: 'index_pkg', name: n, rev: 0 });
      return new Set(names.filter((n) => objects.objects.has(indexKey(n))));
    },
  },
};

/** The takedown log lists tombstones only: nothing in the fixture is tombstoned, so nothing is in it. */
export async function takedownsOf(r: Rig): Promise<unknown> {
  const { deps, objects } = indexerDeps(r);
  await indexTakedowns(deps);
  return JSON.parse(objects.objects.get('index/takedowns.json')!.body.toString('utf8'));
}

/** The same questions put to the raw port, which is not a reader of the registry. */
export const RAW_SURFACES: Record<string, Surface> = {
  'raw.rawGet': async (r, names) => shown(names, await Promise.all(names.map(async (n) => notPending([(await r.store.raw.rawGet(n, '1.0.0')) ?? { state: 'pending' }])))),
  'raw.rawQuery': async (r, names) => shown(names, await Promise.all(names.map(async (n) => notPending(await r.store.raw.rawQuery(n))))),
};

/** What differs between what a surface showed and what it must show, one line each. */
export function differences(actual: Set<string>, expected: Set<string>, names: string[]): string[] {
  const out: string[] = [];
  for (const n of names) {
    if (actual.has(n) && !expected.has(n)) out.push(`${n} is shown and must not be`);
    if (!actual.has(n) && expected.has(n)) out.push(`${n} is hidden and must be shown`);
  }
  return out;
}

/** The cases that are not a surface over the fixture; publish/group-singles.test.ts runs each under its name. */
export const CASE_TAKEDOWNS = 'takedowns';
export const CASE_SINGLE_BEGIN = 'single begin refuses a number a group holds';
export const CASE_SINGLE_COMMIT = 'single commit refuses a number a group holds';
export const CASE_SINGLE_VALIDATOR = 'single validator refuses a number a group holds';
export const CASE_STATUS = 'the status route answers only for a publish record';

/** Every case name a leak case can have, for the inventories. */
export const CASE_NAMES: readonly string[] = [
  ...Object.keys(API_SURFACES),
  ...Object.keys(BUILD_SURFACES),
  CASE_TAKEDOWNS,
  CASE_SINGLE_BEGIN,
  CASE_SINGLE_COMMIT,
  CASE_SINGLE_VALIDATOR,
  CASE_STATUS,
];
