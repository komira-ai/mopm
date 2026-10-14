import { MemoryStore } from '../../src/memory-store';
import type { Store } from '../../src/store';
import { route, normaliseQuery, type HttpResponse, type RouterDeps } from '../../src/http/router';
import { audit, rec } from '../helpers';

async function get(store: Store, path: string, query: Record<string, string> = {}, over: Partial<RouterDeps> = {}) {
  const deps: RouterDeps = { store, stage: 'beta', version: 'v', commit: 'c', readOnly: false, ...over };
  const res: HttpResponse = await route({ method: 'GET', path, query }, deps, 'req-1');
  return { res, body: JSON.parse(res.body) };
}

async function seed(names: string[]) {
  const s = new MemoryStore();
  for (const [i, n] of names.entries()) await s.createPackage({ name: n, state: 'claimed', created_at: `2026-10-${String(i + 1).padStart(2, '0')}T00:00:00Z` });
  return s;
}

describe('health', () => {
  test('keeps stage, version and commit and adds the contract fields', async () => {
    const { res, body } = await get(new MemoryStore(), '/api/v1/health', {}, { stage: 'gamma', version: 'sha-1', commit: 'abc', readOnly: true });
    expect(res.statusCode).toBe(200);
    expect(res.headers['x-mopm-request-id']).toBe('req-1');
    expect(body).toEqual({ status: 'ok', stage: 'gamma', api_version: 'v1', read_only: true, version: 'sha-1', commit: 'abc' });
  });
});

describe('names', () => {
  test.each(['Http-Client', 'a', '1abc', 'x'.repeat(65), 'a b'])('%s is invalid_name (400), never looked up', async (n) => {
    const { res, body } = await get(new MemoryStore(), `/api/v1/packages/${encodeURIComponent(n)}`);
    expect(res.statusCode).toBe(400);
    expect(body.error.code).toBe('invalid_name');
  });
  test('normaliseQuery collapses runs of - . _', () => {
    expect(normaliseQuery('Http-.Cli')).toBe('http_cli');
  });
});

describe('versions', () => {
  test('pages walk the whole list once, newest first, then end with a null cursor', async () => {
    const s = new MemoryStore();
    await s.createPackage({ name: 'pkg', state: 'active', created_at: '2026-10-01T00:00:00Z' });
    for (const v of ['1.0', '1.1', '1.2', '1.10', '2.0']) await s.createVersion(rec({ name: 'pkg', version: v }), audit('pkg', 'publish', v));
    const seen: string[] = [];
    let cursor: string | undefined;
    for (let i = 0; i < 10; i++) {
      const { body } = await get(s, '/api/v1/packages/pkg/versions', { limit: '2', ...(cursor ? { cursor } : {}) });
      seen.push(...body.versions.map((v: any) => v.version));
      cursor = body.next_cursor ?? undefined;
      if (!cursor) break;
    }
    expect(seen).toEqual(['2.0', '1.10', '1.2', '1.1', '1.0']);
  });

  test('a package cursor is refused on the versions list', async () => {
    const s = await seed(['aa', 'bb']);
    const first = (await get(s, '/api/v1/packages', { limit: '1' })).body.next_cursor;
    const { res, body } = await get(s, '/api/v1/packages/aa/versions', { cursor: first });
    expect(res.statusCode).toBe(400);
    expect(body.error.code).toBe('invalid_request');
  });

  test('a pending version is not listed', async () => {
    const s = new MemoryStore();
    await s.createPackage({ name: 'pkg', state: 'active', created_at: '2026-10-01T00:00:00Z' });
    await s.createVersion(rec({ name: 'pkg', version: '1.0', state: 'pending' }), audit('pkg', 'reserve', '1.0'));
    const { body } = await get(s, '/api/v1/packages/pkg/versions');
    expect(body).toEqual({ versions: [], next_cursor: null });
  });
});

describe('search', () => {
  test('prefix paging by name covers every match once', async () => {
    const s = await seed(['http_a', 'http_b', 'http_c', 'httpx', 'zeta']);
    const seen: string[] = [];
    let cursor: string | undefined;
    for (let i = 0; i < 10; i++) {
      const { body } = await get(s, '/api/v1/packages', { q: 'http_', limit: '2', ...(cursor ? { cursor } : {}) });
      seen.push(...body.packages.map((p: any) => p.name));
      cursor = body.next_cursor ?? undefined;
      if (!cursor) break;
    }
    expect(seen).toEqual(['http_a', 'http_b', 'http_c']);
  });

  test('sort=updated: newest publication first, claim time when nothing is published, ties by name', async () => {
    const s = new MemoryStore();
    await s.createPackage({ name: 'old', state: 'active', created_at: '2026-10-01T00:00:00Z' });
    await s.createVersion(rec({ name: 'old', version: '1.0', published_at: '2026-10-02T00:00:00Z' }), audit('old', 'publish', '1.0'));
    await s.createPackage({ name: 'fresh', state: 'active', created_at: '2026-10-01T00:00:00Z' });
    await s.createVersion(rec({ name: 'fresh', version: '1.0', published_at: '2026-10-09T00:00:00Z' }), audit('fresh', 'publish', '1.0'));
    await s.createPackage({ name: 'claimed_b', state: 'claimed', created_at: '2026-10-05T00:00:00Z' });
    await s.createPackage({ name: 'claimed_a', state: 'claimed', created_at: '2026-10-05T00:00:00Z' });
    const seen: string[] = [];
    let cursor: string | undefined;
    for (let i = 0; i < 10; i++) {
      const { body } = await get(s, '/api/v1/packages', { sort: 'updated', limit: '3', ...(cursor ? { cursor } : {}) });
      seen.push(...body.packages.map((p: any) => p.name));
      cursor = body.next_cursor ?? undefined;
      if (!cursor) break;
    }
    expect(seen).toEqual(['fresh', 'claimed_a', 'claimed_b', 'old']);
  });

  test.each([['limit', '0'], ['limit', '101'], ['limit', 'x'], ['sort', 'random'], ['cursor', 'garbage'], ['q', 'x'.repeat(65)]])(
    'bad %s=%s is invalid_request',
    async (k, v) => {
      const { res, body } = await get(await seed(['aa']), '/api/v1/packages', { [k]: v });
      expect(res.statusCode).toBe(400);
      expect(body.error.code).toBe('invalid_request');
    },
  );

  test('a v1 filter the registry does not have is ignored, not refused', async () => {
    const { res } = await get(await seed(['aa']), '/api/v1/packages', { platform: 'linux-64' });
    expect(res.statusCode).toBe(200);
  });

  test('a name cursor from another query is refused (it would lie outside the index range)', async () => {
    const s = await seed(['http_a', 'http_b', 'zlib']);
    const cursor = (await get(s, '/api/v1/packages', { q: 'zlib', limit: '1' })).body.next_cursor;
    expect(cursor).toBeNull(); // sanity: one match, no next page
    const other = (await get(s, '/api/v1/packages', { limit: '1' })).body.next_cursor; // a cursor after 'http_a'
    const { res, body } = await get(s, '/api/v1/packages', { q: 'zlib', cursor: other });
    expect(res.statusCode).toBe(400);
    expect(body.error.code).toBe('invalid_request');
  });

  test('search asks the store for the prefix, one past the page, after the cursor; it never lists every name', async () => {
    const s = new MemoryStore();
    const calls: unknown[][] = [];
    const real = s.searchPackages.bind(s);
    s.searchPackages = async (...a) => (calls.push(a), real(...a));
    s.listPackageNames = async () => { throw new Error('search must not list every name'); };
    await get(s, '/api/v1/packages', { q: 'Http-Cli', limit: '5' });
    expect(calls).toEqual([['http_cli', undefined, 6]]);
  });

  test('sort=updated over more than 1000 matches is refused with a way out, not slowly answered', async () => {
    const s = new MemoryStore();
    for (let i = 0; i < 1001; i++) await s.createPackage({ name: `p${String(i).padStart(4, '0')}`, state: 'claimed', created_at: '2026-10-01T00:00:00Z' });
    const { res, body } = await get(s, '/api/v1/packages', { sort: 'updated' });
    expect(res.statusCode).toBe(400);
    expect(body.error.message).toContain('longer q');
    expect((await get(s, '/api/v1/packages', { sort: 'updated', q: 'p000' })).res.statusCode).toBe(200);
  });
});

describe('getVersion', () => {
  async function withVersions() {
    const s = new MemoryStore();
    await s.createPackage({ name: 'pkg', state: 'active', created_at: '2026-10-01T00:00:00Z' });
    await s.createVersion(rec({ name: 'pkg', version: '1.0' }), audit('pkg', 'publish', '1.0'));
    await s.createVersion(rec({ name: 'pkg', version: '2.0', state: 'pending' }), audit('pkg', 'reserve', '2.0'));
    return s;
  }
  test('an equivalent spelling finds the version and the answer keeps the published spelling', async () => {
    const s = await withVersions();
    for (const v of ['1.0', '1.0.0', '1']) {
      const { res, body } = await get(s, `/api/v1/packages/pkg/${v}`);
      expect([res.statusCode, body.version]).toEqual([200, '1.0']);
    }
  });
  test('provenance defaults to none; a yanked version keeps files and gives the reason; a non-yanked one has a null reason', async () => {
    const s = await withVersions();
    expect((await get(s, '/api/v1/packages/pkg/1.0')).body).toMatchObject({ state: 'published', yank_reason: null, provenance: { kind: 'none' } });
    await s.updateVersion('pkg', '1.0', { type: 'yank', reason: 'broken' }, audit('pkg', 'yank', '1.0'));
    const { body } = await get(s, '/api/v1/packages/pkg/1.0');
    expect(body).toMatchObject({ state: 'yanked', yank_reason: 'broken' });
    expect(body.files[0].url).toBeDefined();
  });
  test('a tombstoned version has the sha256 of each file and no url', async () => {
    const s = await withVersions();
    await s.updateVersion('pkg', '1.0', { type: 'tombstone', reason_code: 'malware', date: '2026-10-14' }, audit('pkg', 'takedown', '1.0'));
    const { body } = await get(s, '/api/v1/packages/pkg/1.0');
    expect(body.tombstone).toEqual({ reason_code: 'malware', date: '2026-10-14' });
    expect(body.files.map((f: any) => [f.sha256, 'url' in f])).toEqual([['a'.repeat(64), false]]);
  });
  test('a pending version is version_not_found; a missing package is package_not_found; checks run in order name, version, package', async () => {
    const s = await withVersions();
    expect((await get(s, '/api/v1/packages/pkg/2.0')).body.error.code).toBe('version_not_found');
    expect((await get(s, '/api/v1/packages/pkg/9.9')).body.error.code).toBe('version_not_found');
    expect((await get(s, '/api/v1/packages/nosuch/1.0')).body.error.code).toBe('package_not_found');
    expect((await get(s, '/api/v1/packages/Bad-Name/1.0')).body.error.code).toBe('invalid_name');
    const bad = await get(s, '/api/v1/packages/nosuch/1.0.0+local');
    expect([bad.res.statusCode, bad.body.error.code]).toEqual([400, 'invalid_version']);
  });
  test('a store error is a 500 that leaks nothing', async () => {
    const broken: Store = new Proxy({} as Store, { get: () => async () => { throw new Error('secret table name'); } });
    const { res, body } = await get(broken, '/api/v1/packages/pkg/1.0');
    expect([res.statusCode, JSON.stringify(body).includes('secret')]).toEqual([500, false]);
  });
});

describe('listOwners', () => {
  test('owners by github id, only id and handle; unknown package 404; invalid name 400', async () => {
    const s = new MemoryStore();
    await s.createPackage({ name: 'pkg', state: 'active', created_at: '2026-10-01T00:00:00Z' });
    await s.addOwner({ name: 'pkg', github_id: 30, handle: 'zed', added_at: '2026-10-02T00:00:00Z' });
    await s.addOwner({ name: 'pkg', github_id: 4, handle: 'amy', added_at: '2026-10-01T00:00:00Z' });
    const ok = await get(s, '/api/v1/packages/pkg/owners');
    expect(ok.res.statusCode).toBe(200);
    expect(ok.body).toEqual({ owners: [{ github_id: 4, handle: 'amy' }, { github_id: 30, handle: 'zed' }] });
    expect((await get(s, '/api/v1/packages/nosuch/owners')).body.error.code).toBe('package_not_found');
    expect((await get(s, '/api/v1/packages/X/owners')).body.error.code).toBe('invalid_name');
  });
  test('"owners" and "versions" are never taken for a version', async () => {
    const s = new MemoryStore();
    await s.createPackage({ name: 'pkg', state: 'active', created_at: '2026-10-01T00:00:00Z' });
    expect(Object.keys((await get(s, '/api/v1/packages/pkg/owners')).body)).toEqual(['owners']);
    expect(Object.keys((await get(s, '/api/v1/packages/pkg/versions')).body)).toEqual(['versions', 'next_cursor']);
  });
});

describe('route_not_found', () => {
  const none = (method: string, path: string) =>
    route({ method, path, query: {} }, { store: new MemoryStore(), stage: 'beta', version: 'v', commit: 'c', readOnly: false }, 'r');
  test.each([
    ['GET', '/api/v1/nope'],
    ['GET', '/other/v1/packages'],
    ['GET', '/api/v1'],
    ['GET', '/api/v1/packages/pkg/1.0/files'],
    ['GET', '/api/v1/packages/pkg/claim'], // a literal segment of the POST claim operation, not a version
    ['GET', '/api/v1/packages/%E0%A4%A'], // undecodable percent escape
    ['POST', '/api/v1/packages/pkg/claim'],
    ['DELETE', '/api/v1/packages/pkg'],
    ['PUT', '/api/v1/packages/pkg/owners'],
  ])('%s %s is 404 route_not_found', async (method, path) => {
    const res = await none(method, path);
    expect(res.statusCode).toBe(404);
    expect(JSON.parse(res.body).error).toEqual({
      code: 'route_not_found',
      message: 'There is no such operation.',
      hint: 'Check the request against the API documentation; update mopm if it is old.',
    });
    expect(res.headers['x-mopm-request-id']).toBe('r');
  });
  test('a real operation with a bad argument is still its own error, not route_not_found', async () => {
    expect(JSON.parse((await none('GET', '/api/v1/packages/Bad')).body).error.code).toBe('invalid_name');
  });
});

describe('failures', () => {
  test('an unexpected store error is internal_error (500) and leaks nothing', async () => {
    const broken: Store = new Proxy({} as Store, { get: () => async () => { throw new Error('secret table name'); } });
    const { res, body } = await get(broken, '/api/v1/packages/pkg_one');
    expect(res.statusCode).toBe(500);
    expect(JSON.stringify(body)).not.toContain('secret');
    expect(body.error.code).toBe('internal_error');
  });

  test('writes are not served here', async () => {
    const res = await route({ method: 'POST', path: '/api/v1/packages/pkg_one/claim', query: {} }, { store: new MemoryStore(), stage: 'beta', version: 'v', commit: 'c', readOnly: false }, 'r');
    expect(res.statusCode).toBe(404);
  });
});
