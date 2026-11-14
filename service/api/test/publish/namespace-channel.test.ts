import { MemoryNamespaceStore, NamespaceAccess, type NamespaceRecord } from '../../src/auth';
import { channelFileKey } from '../../src/channel-paths';
import { indexKey, TAKEDOWNS_KEY, TAKEDOWNS_V2_KEY } from '../../src/index-files';
import { condaNameOf } from '../../src/names';
import { indexSubdir, parseIndexMessage } from '../../src/publish/indexer';
import { queueTakedownIndex } from '../../src/publish/takedown';
import { SUBDIRS_V1 } from '../../src/types';
import { Harness, pkg, type Pkg } from './harness';

// One package published, yanked and taken down in a namespace: the files, the repodata and the index file land in that namespace's
// channel (docs/design/namespaces.md section 5, spec/channel.md) and nowhere else; a flat package lands where it always did.

const ALICE = 1;
const BOB = 2;
const body = (r: { body: string }) => JSON.parse(r.body);
const lines = (text: string | undefined) => text!.trim().split('\n').map((l) => JSON.parse(l));

async function rig() {
  const h = new Harness();
  const store = new MemoryNamespaceStore();
  const at = h.clock.now().toISOString();
  const rows: NamespaceRecord[] = [
    { namespace: 'alice', kind: 'user', github_id: ALICE, created_at: at },
    { namespace: 'bob', kind: 'user', github_id: BOB, created_at: at },
  ];
  for (const r of rows) await store.createNamespace(r);
  const access = new NamespaceAccess({ namespaces: store, users: h.authStore });
  h.namespaces = access;
  h.v2 = { access, namespaces: store };
  h.build();
  for (const [id, handle] of [[ALICE, 'alice'], [BOB, 'bob']] as const) await h.authStore.upsertUser(id, handle, at);
  return h;
}

/** begin, PUT and commit of full-name files under /api/v2, then the validator and the index writer. */
async function publishFull(h: Harness, token: string, ...files: Pkg[]): Promise<string> {
  const ids: string[] = [];
  for (const f of files) {
    const res = await h.call('POST', `/api/v2/packages/${f.name}/${f.version}/files`, token, { subdir: f.subdir, filename: f.filename, sha256: f.sha256, size: f.bytes.length });
    expect(res.statusCode).toBe(200);
    const up = (await h.publishes.getUpload(body(res).upload_id))!;
    await h.objects.put(up.key, f.bytes, { contentType: 'application/octet-stream' });
    ids.push(up.upload_id);
  }
  const first = files[0]!;
  const done = await h.call('POST', `/api/v2/packages/${first.name}/${first.version}/publish`, token, { upload_ids: ids, manifest_sha256: first.manifest });
  expect(done.statusCode).toBe(202);
  await h.runValidator();
  await h.runIndexer();
  return body(done).publish_id as string;
}

async function publishFlat(h: Harness, p: Pkg): Promise<void> {
  const me = await h.account(9, 'flat', [p.name]);
  await h.publish(me.token, p);
  await h.runValidator();
  await h.runIndexer();
}

const makePkg = (h: Harness, full: string) => h.registry.createPackage({ name: full, state: 'active', created_at: h.clock.now().toISOString() });

describe('a full-name package published end to end', () => {
  test('its file, repodata and index file are in its namespace channel; the root and another namespace are untouched', async () => {
    const h = await rig();
    await makePkg(h, 'alice/json');
    await makePkg(h, 'bob/other');
    const token = await h.token(ALICE, ['alice/json'], ['publish']);
    const p = pkg({ name: 'alice/json', version: '1.0.0', subdir: 'linux-64' });
    expect(p.filename.startsWith(`${condaNameOf('alice/json')}-1.0.0-`)).toBe(true);

    const id = await publishFull(h, token, p);
    expect((await h.publishes.getPublish(id))!.status).toBe('published');

    const key = channelFileKey('alice/json', 'linux-64', p.filename);
    expect(key).toBe(`alice/linux-64/${p.filename}`);
    expect(h.objects.objects.get(key)!.body.equals(p.bytes)).toBe(true);
    const version = (await h.registry.getVersion('alice/json', '1.0.0'))!;
    expect(version.files[0]!.url).toBe(`https://conda.example.invalid/${key}`);

    const repodata = h.objects.objects.get('alice/linux-64/repodata.json')!;
    const listed = JSON.parse(repodata.body.toString('utf8'))['packages.conda'] as Record<string, { name: string }>;
    expect(Object.keys(listed)).toEqual([p.filename]);
    expect(listed[p.filename]!.name).toBe('mojo-alice.json');
    expect(h.objects.objects.has('alice/linux-64/repodata.json.zst')).toBe(true);
    // The other three subdirs of the namespace exist, empty.
    for (const s of SUBDIRS_V1.filter((x) => x !== 'linux-64')) expect(Object.keys(JSON.parse(h.objects.objects.get(`alice/${s}/repodata.json`)!.body.toString('utf8'))['packages.conda'])).toEqual([]);

    // Nothing at the root (no file, no repodata), nothing in bob's channel, and the index file is the v2 one.
    expect(h.objects.keys('linux-64/')).toEqual([]);
    expect(h.objects.keys('bob/')).toEqual([]);
    expect(h.objects.keys('noarch/')).toEqual([]);
    expect(h.objects.keys('index/')).toEqual([indexKey('alice/json')]);
    expect(indexKey('alice/json').startsWith('index/v2/')).toBe(true);
    expect(lines(h.indexFile('alice/json'))[0]).toMatchObject({ v: 2, version: '1.0.0', state: 'published' });
    // The writer ran only in alice's directories; the CDN was told about those paths only.
    for (const b of h.invalidator.batches) for (const path of b.paths) expect(path.startsWith('/alice/')).toBe(true);
  });

  test('the publish message, its group and its dedup id carry the repodata directory, and remaining_subdirs holds it', async () => {
    const h = await rig();
    await makePkg(h, 'alice/json');
    const token = await h.token(ALICE, ['alice/json'], ['publish']);
    const a = pkg({ name: 'alice/json', version: '1.0.0', subdir: 'linux-64' });
    const b = pkg({ name: 'alice/json', version: '1.0.0', subdir: 'noarch' });
    const ids: string[] = [];
    for (const f of [a, b]) {
      const res = await h.call('POST', `/api/v2/packages/${f.name}/${f.version}/files`, token, { subdir: f.subdir, filename: f.filename, sha256: f.sha256, size: f.bytes.length });
      const up = (await h.publishes.getUpload(body(res).upload_id))!;
      await h.objects.put(up.key, f.bytes, { contentType: 'application/octet-stream' });
      ids.push(up.upload_id);
    }
    const done = await h.call('POST', `/api/v2/packages/alice/json/1.0.0/publish`, token, { upload_ids: ids, manifest_sha256: a.manifest });
    const publishId = body(done).publish_id as string;
    await h.runValidator();
    expect((await h.publishes.getPublish(publishId))!.remaining_subdirs).toEqual(['alice/linux-64', 'alice/noarch']);
    expect(h.indexQueue.sent.map((m) => [m.groupId, m.dedupId, JSON.parse(m.body).subdir])).toEqual([
      ['alice/linux-64', `${publishId}:alice/linux-64`, 'alice/linux-64'],
      ['alice/noarch', `${publishId}:alice/noarch`, 'alice/noarch'],
    ]);
    await h.runIndexer();
    expect((await h.publishes.getPublish(publishId))!.status).toBe('published');
  });

  test('a flat package still lands at the root with a v1 index, and no namespace channel lists it', async () => {
    const h = await rig();
    await makePkg(h, 'alice/json');
    const token = await h.token(ALICE, ['alice/json'], ['publish']);
    await publishFull(h, token, pkg({ name: 'alice/json', version: '1.0.0', subdir: 'noarch' }));
    const flat = pkg({ name: 'demo', version: '1.0.0', subdir: 'noarch' });
    await publishFlat(h, flat);

    expect(h.objects.objects.has(`noarch/${flat.filename}`)).toBe(true);
    expect(Object.keys(h.repodata('noarch')['packages.conda'])).toEqual([flat.filename]);
    expect(indexKey('demo').startsWith('index/v2/')).toBe(false);
    expect(lines(h.indexFile('demo'))[0]).toMatchObject({ v: 1 });
    expect(Object.values(h.repodata('alice/noarch' as 'noarch')['packages.conda']).map((r) => r.name)).toEqual(['mojo-alice.json']);
    expect(JSON.stringify(h.repodata('alice/noarch' as 'noarch'))).not.toContain(flat.filename);
  });
});

describe('yank, unyank and takedown of a full-name package', () => {
  async function published() {
    const h = await rig();
    await makePkg(h, 'alice/json');
    await makePkg(h, 'bob/other');
    const token = await h.token(ALICE, ['alice/json'], ['publish', 'yank']);
    const p = pkg({ name: 'alice/json', version: '1.0.0', subdir: 'noarch' });
    await publishFull(h, token, p);
    const q = pkg({ name: 'bob/other', version: '1.0.0', subdir: 'noarch' });
    await publishFull(h, await h.token(BOB, ['bob/other'], ['publish']), q);
    await publishFlat(h, pkg({ name: 'demo', version: '1.0.0', subdir: 'noarch' }));
    h.invalidator.batches.length = 0;
    h.indexQueue.sent.length = 0;
    return { h, token, p, q };
  }

  test('a yank and an unyank queue and rewrite only the namespace directory, with a dedup id of the directory', async () => {
    const { h, token, p, q } = await published();
    const bobBefore = h.objects.objects.get('bob/noarch/repodata.json')!.body.toString('utf8');
    const rootBefore = h.objects.objects.get('noarch/repodata.json')!.body.toString('utf8');
    const res = await h.call('PUT', '/api/v2/packages/alice/json/1.0.0/yank', token, { yanked: true, reason: 'broken' });
    expect(res.statusCode).toBe(200);
    expect(h.indexQueue.sent.map((m) => [m.groupId, JSON.parse(m.body)])).toEqual([
      ['alice/noarch', { type: 'index', subdir: 'alice/noarch' }],
      ['pkg:alice/json', { type: 'index_pkg', name: 'alice/json', rev: expect.any(Number) }],
    ]);
    expect(h.indexQueue.sent[0]!.dedupId).toContain(':alice/json:');
    expect(h.indexQueue.sent[0]!.dedupId.endsWith(':alice/noarch')).toBe(true);
    await h.runIndexer();
    const alice = JSON.parse(h.objects.objects.get('alice/noarch/repodata.json')!.body.toString('utf8'));
    expect(alice['packages.conda']).toEqual({});
    expect(alice.removed).toEqual([p.filename]);
    expect(lines(h.indexFile('alice/json'))[0]).toMatchObject({ state: 'yanked' });
    expect(h.objects.objects.get('bob/noarch/repodata.json')!.body.toString('utf8')).toBe(bobBefore);
    expect(h.objects.objects.get('noarch/repodata.json')!.body.toString('utf8')).toBe(rootBefore);
    expect(Object.keys(JSON.parse(bobBefore)['packages.conda'])).toEqual([q.filename]);

    h.indexQueue.sent.length = 0;
    await h.call('PUT', '/api/v2/packages/alice/json/1.0.0/yank', token, { yanked: false });
    expect(h.indexQueue.sent.map((m) => [m.groupId, JSON.parse(m.body)])).toEqual([
      ['alice/noarch', { type: 'index', subdir: 'alice/noarch', then: { name: 'alice/json', rev: expect.any(Number), next: [] } }],
    ]);
    await h.runIndexer();
    expect(Object.keys(JSON.parse(h.objects.objects.get('alice/noarch/repodata.json')!.body.toString('utf8'))['packages.conda'])).toEqual([p.filename]);
    expect(lines(h.indexFile('alice/json'))[0]).toMatchObject({ state: 'published' });
    for (const b of h.invalidator.batches) for (const path of b.paths) expect(path.startsWith('/alice/')).toBe(true);
  });

  test('a takedown queues the namespace directory, the package job and the takedown job, and writes both logs with the name only in v2', async () => {
    const { h, p } = await published();
    await h.registry.updateVersion('alice/json', '1.0.0', { type: 'tombstone', reason_code: 'malware', date: '2026-10-02' }, { name: 'alice/json', ts: '2026-10-02T00:00:00.000Z', id: 'a_takedown', actor: 'ops', action: 'takedown', version: '1.0.0' });
    await queueTakedownIndex({ registry: h.registry, indexQueue: h.indexQueue }, 'alice/json');
    expect(h.indexQueue.sent.map((m) => m.groupId).sort()).toEqual(['alice/noarch', 'pkg:alice/json', 'takedowns']);
    await h.runIndexer();

    expect(JSON.parse(h.objects.objects.get('alice/noarch/repodata.json')!.body.toString('utf8')).removed).toEqual([p.filename]);
    expect(lines(h.indexFile('alice/json'))[0]).toMatchObject({ state: 'tombstoned' });
    const v1 = JSON.parse(h.objects.objects.get(TAKEDOWNS_KEY)!.body.toString('utf8'));
    const v2 = JSON.parse(h.objects.objects.get(TAKEDOWNS_V2_KEY)!.body.toString('utf8'));
    expect(v1.takedowns).toEqual([]);
    expect(v2.takedowns).toEqual([{ name: 'alice/json', version: '1.0.0', reason_code: 'malware', sha256: [p.sha256], date: '2026-10-02' }]);
  });
});

describe('index messages of namespace channels', () => {
  test('a namespace directory and full names parse; a bad full name or a bad chain is refused', () => {
    expect(parseIndexMessage({ type: 'index', subdir: 'alice/noarch', publish_id: 'p' })).toEqual({ type: 'index', subdir: 'alice/noarch', publish_id: 'p' });
    expect(parseIndexMessage({ type: 'index', subdir: 'alice/noarch', then: { name: 'alice/json', rev: 2, next: ['alice/linux-64'] } })).toEqual({
      type: 'index',
      subdir: 'alice/noarch',
      then: { name: 'alice/json', rev: 2, next: ['alice/linux-64'] },
    });
    expect(parseIndexMessage({ type: 'index_pkg', name: 'alice/json', rev: 3, publish_id: 'p' })).toEqual({ type: 'index_pkg', name: 'alice/json', rev: 3, publish_id: 'p' });
    for (const name of ['alice/', '/json', 'Alice/json', 'alice/json/x', 'alice/../json']) expect(parseIndexMessage({ type: 'index_pkg', name, rev: 1 })).toBeUndefined();
    expect(parseIndexMessage({ type: 'index', subdir: 'alice/noarch', then: { name: 'alice/Json', rev: 1, next: [] } })).toBeUndefined();
  });

  test.each(['alice/amiga', 'alice/', '/noarch', 'alice/noarch/x', 'A_B/noarch', '../noarch', 'alice\\noarch'])('an index message for the directory %j is dropped and logged, nothing written', async (subdir) => {
    const h = new Harness();
    await indexSubdir(h.indexerDeps, { type: 'index', subdir });
    expect(h.objects.keys()).toEqual([]);
    expect(h.invalidator.batches).toEqual([]);
    expect(h.logs).toEqual([{ level: 'error', msg: 'index message for an unknown subdir', subdir }]);
  });

  test('a message for an unseen namespace writes that namespace\'s four empty subdirs, and nothing at the root', async () => {
    const h = new Harness();
    await indexSubdir(h.indexerDeps, { type: 'index', subdir: 'carol/osx-arm64' });
    expect(h.objects.keys()).toEqual(SUBDIRS_V1.flatMap((s) => [`carol/${s}/repodata.json`, `carol/${s}/repodata.json.zst`]).sort());
  });
});
