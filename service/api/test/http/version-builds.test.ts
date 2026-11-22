import { MemoryAuthStore, MemoryNamespaceStore, NamespaceAccess } from '../../src/auth';
import { route, type HttpResponse, type RouterDeps } from '../../src/http/router';
import { MemoryStore } from '../../src/memory-store';
import type { VersionRecord } from '../../src/types';
import { audit, buildFile, buildRow, rec } from '../helpers';

// getVersion shows a version as one record whose builds are folded in: `requires_mojo` and `files` are the primary build's
// (what a client that predates builds understands), and `/api/v2` also lists every build in `builds`. Over memory stores.

const NOW = '2026-10-14T12:00:00Z';
const FULL = 'komira-ai/json';

async function world() {
  const store = new MemoryStore();
  const namespaces = new MemoryNamespaceStore();
  await namespaces.createNamespace({ namespace: 'komira-ai', kind: 'org', github_id: 100, created_at: NOW });
  const access = new NamespaceAccess({ namespaces, users: new MemoryAuthStore() });
  const deps: RouterDeps = { store, stage: 'beta', version: 'v', commit: 'c', readOnly: false, v2: { access, namespaces } };
  await store.createPackage({ name: FULL, state: 'active', created_at: '2026-10-01T00:00:00Z' });
  await store.createPackage({ name: 'json', state: 'active', created_at: '2026-10-01T00:00:00Z' });
  return { store, deps };
}

async function get(deps: RouterDeps, path: string) {
  const res: HttpResponse = await route({ method: 'GET', path, query: {} }, deps, 'req-1');
  return { res, body: JSON.parse(res.body) };
}

const v1 = (deps: RouterDeps, version = '1.0.0') => get(deps, `/api/v1/packages/json/${version}`);
const v2 = (deps: RouterDeps, version = '1.0.0') => get(deps, `/api/v2/packages/komira-ai/json/${version}`);
const put = (store: MemoryStore, r: VersionRecord) => store.createVersion(r, audit(r.name, 'publish', r.version));
const own = (name: string, over: Partial<VersionRecord> = {}, build = 'mojo1.0.0_0') =>
  rec({ name, version: '1.0.0', build, requires_mojo: `==${build.slice(4, -2)}`, files: [buildFile(name, '1.0.0', build, 'linux-64', 'a')], rev: 1, ...over });

describe('a version with one build', () => {
  test('/api/v2 serves the top-level requires_mojo and files as before and lists that build in builds', async () => {
    const { store, deps } = await world();
    await put(store, own(FULL));
    const { res, body } = await v2(deps);
    expect(res.statusCode).toBe(200);
    expect(body.requires_mojo).toBe('==1.0.0');
    expect(body.files).toHaveLength(1);
    expect(body.builds).toEqual([{ build: 'mojo1.0.0_0', requires_mojo: '==1.0.0', files: body.files }]);
  });

  test('/api/v1 has no builds key', async () => {
    const { store, deps } = await world();
    await put(store, own('json'));
    const { body } = await v1(deps);
    expect(body).not.toHaveProperty('builds');
    expect(body).toMatchObject({ requires_mojo: '==1.0.0', files: [{ subdir: 'linux-64', filename: 'mojo-json-1.0.0-mojo1.0.0_0.conda' }] });
  });
});

describe('a version with a build added later', () => {
  const setup = async (name: string, base = 'mojo1.2.0_0', added = 'mojo1.0.0_0') => {
    const w = await world();
    await put(w.store, own(name, {}, base));
    await put(w.store, buildRow(name, '1.0.0', added));
    return w;
  };

  test('/api/v2: the top-level requires_mojo and files are the primary build\'s, builds lists both sorted by compiler', async () => {
    const { deps } = await setup(FULL);
    const { body } = await v2(deps);
    expect(body.requires_mojo).toBe('==1.0.0');
    expect(body.files.map((f: any) => f.filename)).toEqual(['mojo-komira-ai.json-1.0.0-mojo1.0.0_0.conda']);
    expect(body.builds.map((b: any) => [b.build, b.requires_mojo, b.files.map((f: any) => f.filename)])).toEqual([
      ['mojo1.0.0_0', '==1.0.0', ['mojo-komira-ai.json-1.0.0-mojo1.0.0_0.conda']],
      ['mojo1.2.0_0', '==1.2.0', ['mojo-komira-ai.json-1.0.0-mojo1.2.0_0.conda']],
    ]);
    expect(body.builds.every((b: any) => b.files.every((f: any) => typeof f.url === 'string'))).toBe(true);
  });

  test('/api/v1 shows exactly the one build an older client understands, and no builds key', async () => {
    const { deps } = await setup('json');
    const { body } = await v1(deps);
    expect(body).not.toHaveProperty('builds');
    expect(body.requires_mojo).toBe('==1.0.0');
    expect(body.files.map((f: any) => f.filename)).toEqual(['mojo-json-1.0.0-mojo1.0.0_0.conda']);
  });

  test('the added build is the version\'s second build when its compiler is the higher: the version\'s own stays primary', async () => {
    const { deps } = await setup(FULL, 'mojo1.0.0_0', 'mojo1.10.0_0');
    const { body } = await v2(deps);
    expect(body.requires_mojo).toBe('==1.0.0');
    expect(body.builds.map((b: any) => b.build)).toEqual(['mojo1.0.0_0', 'mojo1.10.0_0']);
  });

  test('what the builds share is the version\'s: one record, one state, one manifest, one published_at', async () => {
    const { deps } = await setup(FULL);
    const { body } = await v2(deps);
    expect(body).toMatchObject({ name: FULL, version: '1.0.0', state: 'published', manifest_sha256: 'f'.repeat(64), published_at: '2026-10-13T12:00:00Z', deps: [], native: [] });
  });

  test('an added build that is not published (a pending reservation) is not shown', async () => {
    const { store, deps } = await world();
    await put(store, own(FULL));
    await put(store, buildRow(FULL, '1.0.0', 'mojo1.1.0_0', { state: 'pending', files: [], rev: 0 }));
    const { body } = await v2(deps);
    expect(body.builds.map((b: any) => b.build)).toEqual(['mojo1.0.0_0']);
  });

  test('a yanked version shows every build with its urls, and says why', async () => {
    const { store, deps } = await setup(FULL);
    await store.updateVersion(FULL, '1.0.0', { type: 'yank', reason: 'broken' }, audit(FULL, 'yank', '1.0.0'));
    const { body } = await v2(deps);
    expect(body).toMatchObject({ state: 'yanked', yank_reason: 'broken' });
    expect(body.builds.flatMap((b: any) => b.files).every((f: any) => typeof f.url === 'string')).toBe(true);
  });

  test('a taken-down version shows the sha256 of every file of every build and no url', async () => {
    const { store, deps } = await setup(FULL);
    await store.updateVersion(FULL, '1.0.0', { type: 'tombstone', reason_code: 'malware', date: '2026-11-12' }, audit(FULL, 'takedown', '1.0.0'));
    const { body } = await v2(deps);
    expect(body.state).toBe('tombstoned');
    const files = [...body.files, ...body.builds.flatMap((b: any) => b.files)];
    expect(files).toHaveLength(3);
    expect(files.some((f: any) => 'url' in f)).toBe(false);
    expect(body.builds.flatMap((b: any) => b.files.map((f: any) => f.sha256))).toEqual(['b'.repeat(64), 'a'.repeat(64)]);
  });

  test('the versions of the package are still listed once each, in both APIs', async () => {
    const { deps } = await setup(FULL);
    const listed = await get(deps, '/api/v2/packages/komira-ai/json/versions');
    expect(listed.body.versions.map((v: any) => v.version)).toEqual(['1.0.0']);
    const info = await get(deps, '/api/v2/packages/komira-ai/json');
    expect(info.body.versions.map((v: any) => v.version)).toEqual(['1.0.0']);
    expect(info.body.latest).toBe('1.0.0');
  });
});

describe('a build row key is not a version', () => {
  test('/api/v1 refuses 1.0.0+mojo1.1.0_0 as invalid_version, before anything is read', async () => {
    const { store, deps } = await world();
    await put(store, own('json'));
    await put(store, buildRow('json', '1.0.0', 'mojo1.1.0_0'));
    const { res, body } = await get(deps, `/api/v1/packages/json/${encodeURIComponent('1.0.0+mojo1.1.0_0')}`);
    expect(res.statusCode).toBe(400);
    expect(body.error.code).toBe('invalid_version');
  });

  test('/api/v2 refuses 1.0.0+mojo1.1.0_0 as invalid_version, before anything is read', async () => {
    const { store, deps } = await world();
    await put(store, own(FULL));
    await put(store, buildRow(FULL, '1.0.0', 'mojo1.1.0_0'));
    const { res, body } = await get(deps, `/api/v2/packages/komira-ai/json/${encodeURIComponent('1.0.0+mojo1.1.0_0')}`);
    expect(res.statusCode).toBe(400);
    expect(body.error.code).toBe('invalid_version');
  });
});

describe('a version that does not show', () => {
  test('a pending version is version_not_found, and so is one that does not exist, with or without added builds', async () => {
    const { store, deps } = await world();
    await put(store, own(FULL, { state: 'pending', files: [], build: '', requires_mojo: '', rev: 0 }));
    expect((await v2(deps)).body.error.code).toBe('version_not_found');
    expect((await v2(deps, '2.0.0')).body.error.code).toBe('version_not_found');
    await put(store, buildRow(FULL, '2.0.0', 'mojo1.1.0_0'));
    expect((await v2(deps, '2.0.0')).body.error.code).toBe('version_not_found');
  });

  test('a rejected publish (tombstoned, no files) still answers with its own requires_mojo and no files', async () => {
    const { store, deps } = await world();
    await put(store, own(FULL, { state: 'tombstoned', tombstone: { reason_code: 'rejected', date: '2026-11-12' }, files: [], build: '', requires_mojo: '==1.0.0' }));
    const { body } = await v2(deps);
    expect(body).toMatchObject({ state: 'tombstoned', requires_mojo: '==1.0.0', files: [], builds: [] });
  });
});
