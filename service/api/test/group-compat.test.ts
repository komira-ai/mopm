import { route } from '../src/http/router';
import { buildPackageIndex, buildTakedowns, indexKey } from '../src/index-files';
import { buildRepodata } from '../src/repodata';
import { SUBDIRS_V1 } from '../src/types';
import { indexPackage, indexSubdir, indexTakedowns, type IndexerDeps } from '../src/publish/indexer';
import { MemoryInvalidator, MemoryObjectStore, MemoryPublishStore, MemoryQueue } from '../src/publish/memory';
import { ALL_FIXTURE_ROWS, FIXTURE_PACKAGES } from './fixtures/index-registry';
import { audit } from './helpers';
import { RIGS, type Rig } from './group-rig';

/**
 * Data written before groups exist must read exactly as it did: the same bytes out of every builder, the same
 * response from every route, and no read of a group item at all. The expected bytes are those of the pure builders
 * over the stored rows, which do not know about groups.
 */

async function seed(r: Rig) {
  for (const name of Object.keys(FIXTURE_PACKAGES)) await r.claim(name);
  for (const row of ALL_FIXTURE_ROWS) await r.store.createVersion(row, audit(row.name, 'seed', row.version));
}

describe.each(RIGS)('rows without a group, over the %s adapter', (_label, makeRig) => {
  test('every builder writes the bytes the pure builders write from the stored rows', async () => {
    const r = makeRig();
    await seed(r);
    const objects = new MemoryObjectStore();
    const d: IndexerDeps = { registry: r.store, publishes: new MemoryPublishStore(), objects, invalidator: new MemoryInvalidator(), indexQueue: new MemoryQueue(), log: () => undefined, ensured: new Set() };

    for (const subdir of SUBDIRS_V1) {
      await indexSubdir(d, { type: 'index', subdir });
      const want = buildRepodata(subdir, ALL_FIXTURE_ROWS);
      expect(objects.objects.get(`${subdir}/repodata.json`)!.body.equals(want.json)).toBe(true);
      expect(objects.objects.get(`${subdir}/repodata.json.zst`)!.body.equals(want.zst)).toBe(true);
    }
    for (const [name, rows] of Object.entries(FIXTURE_PACKAGES)) {
      await indexPackage(d, { type: 'index_pkg', name, rev: 0 });
      expect(objects.objects.get(indexKey(name))!.body.toString('utf8')).toBe(buildPackageIndex(name, rows));
    }
    await indexTakedowns(d);
    expect(objects.objects.get('index/takedowns.json')!.body.toString('utf8')).toBe(buildTakedowns(ALL_FIXTURE_ROWS));
  });

  test('no route says anything about groups, and none reads a group item', async () => {
    const r = makeRig();
    await seed(r);
    const get = async (path: string, query: Record<string, string> = {}) =>
      (await route({ method: 'GET', path, query }, { store: r.store, stage: 'beta', version: 't', commit: 't', readOnly: false }, 'req')).body;
    const bodies = [
      await get('/api/v1/packages', { limit: '100' }),
      await get('/api/v1/packages', { sort: 'updated' }),
      await get('/api/v1/packages/http_client'),
      await get('/api/v1/packages/http_client/versions'),
      await get('/api/v1/packages/http_client/0.4.0'),
      await get('/api/v1/packages/tls/1.0.0'),
    ];
    for (const b of bodies) expect(b).not.toMatch(/group|staged_attempt/);
    expect(JSON.parse(bodies[0]!).packages.map((p: { name: string }) => p.name)).toEqual(['crypto', 'http_client', 'http_core', 'tls']);
    expect(r.groupReads()).toEqual([]);
    expect(r.lines).toEqual([]);
    expect(r.logs).toEqual([]);
  });
});

test('both adapters answer the routes with the same bytes', async () => {
  const bodies: string[][] = [];
  for (const [, makeRig] of RIGS) {
    const r = makeRig();
    await seed(r);
    const out: string[] = [];
    for (const path of ['/api/v1/packages/http_core', '/api/v1/packages/http_core/versions', '/api/v1/packages/http_core/2.0.0', '/api/v1/packages/crypto/2.0.1']) {
      out.push((await route({ method: 'GET', path, query: {} }, { store: r.store, stage: 'beta', version: 't', commit: 't', readOnly: false }, 'req')).body);
    }
    bodies.push(out);
  }
  expect(bodies[0]).toEqual(bodies[1]);
});
