import { MemoryAuthStore, MemoryNamespaceStore, NamespaceAccess, type NamespaceRecord } from '../../src/auth';
import { route, type HttpResponse, type RouterDeps } from '../../src/http/router';
import { MAX_SCAN_ROWS } from '../../src/http/v2-reads';
import { MemoryStore } from '../../src/memory-store';
import { audit, rec } from '../helpers';

// The read operations of /api/v2 through route(), over memory stores: packages are rows named by their full name;
// the namespaces and their accounts are in the namespace and auth memory stores.

const NOW = '2026-10-14T12:00:00Z';
const ns = (namespace: string, github_id: number, over: Partial<NamespaceRecord> = {}): NamespaceRecord => ({
  namespace,
  kind: 'user',
  github_id,
  created_at: NOW,
  ...over,
});

async function world() {
  const store = new MemoryStore();
  const namespaces = new MemoryNamespaceStore();
  const users = new MemoryAuthStore();
  // alice: a user namespace for the login 'Alice'. octo: renamed on GitHub to 'octo-new'; the namespace stays 'octo'.
  await users.upsertUser(400, 'Alice', NOW);
  await users.upsertUser(300, 'octo-new', NOW);
  await namespaces.createNamespace(ns('alice', 400));
  await namespaces.createNamespace(ns('octo', 300));
  await namespaces.createNamespace(ns('komira-ai', 100, { kind: 'org' }));
  await namespaces.createNamespace(ns('acme', 200, { kind: 'org' }));
  const access = new NamespaceAccess({ namespaces, users });
  const deps: RouterDeps = { store, stage: 'beta', version: 'v', commit: 'c', readOnly: false, v2: { access, namespaces } };
  return { store, namespaces, users, deps };
}

async function call(deps: RouterDeps, path: string, query: Record<string, string> = {}) {
  const res: HttpResponse = await route({ method: 'GET', path, query }, deps, 'req-1');
  return { res, body: JSON.parse(res.body) };
}

const newPackage = (store: MemoryStore, name: string, created_at = '2026-10-01T00:00:00Z', description?: string) =>
  store.createPackage({ name, state: 'active', created_at, ...(description === undefined ? {} : { description }) });
const publish = (store: MemoryStore, name: string, version: string, over: Partial<Parameters<typeof rec>[0]> = {}) =>
  store.createVersion(rec({ name, version, ...over }), audit(name, 'publish', version));

describe('getNamespace', () => {
  test('a user namespace: the login is the handle of the last login, in its own case', async () => {
    const { deps } = await world();
    const { res, body } = await call(deps, '/api/v2/namespaces/alice');
    expect(res.statusCode).toBe(200);
    expect(body).toEqual({ namespace: 'alice', kind: 'user', github_id: 400, login: 'Alice' });
  });

  test('a renamed user: the namespace keeps its name while the login is the new one', async () => {
    const { deps } = await world();
    const { body } = await call(deps, '/api/v2/namespaces/octo');
    expect(body).toEqual({ namespace: 'octo', kind: 'user', github_id: 300, login: 'octo-new' });
  });

  test('an organization: its login is the namespace, and nothing else is said about who may publish', async () => {
    const { deps } = await world();
    const { body } = await call(deps, '/api/v2/namespaces/komira-ai');
    expect(body).toEqual({ namespace: 'komira-ai', kind: 'org', github_id: 100, login: 'komira-ai' });
  });

  test.each([
    ['Not_Valid', 400, 'invalid_namespace'],
    ['index', 403, 'namespace_reserved'],
    ['nobody', 404, 'namespace_not_found'],
  ])('%s answers %i %s', async (n, status, code) => {
    const { deps } = await world();
    const { res, body } = await call(deps, `/api/v2/namespaces/${n}`);
    expect(res.statusCode).toBe(status);
    expect(body.error.code).toBe(code);
  });

  test('is public: no authorization is read', async () => {
    const { deps } = await world();
    const res = await route({ method: 'GET', path: '/api/v2/namespaces/alice', query: {}, headers: {} }, deps, 'r');
    expect(res.statusCode).toBe(200);
  });
});

describe('getPackage', () => {
  test('is the v1 body with the namespace instead of the owners, and the full name', async () => {
    const { store, deps } = await world();
    await store.createPackage({ name: 'komira-ai/json', state: 'active', created_at: '2026-10-01T00:00:00Z', description: 'JSON', license: 'MIT', keywords: ['json'] });
    await publish(store, 'komira-ai/json', '1.0.0', { readme: '# json' });
    await publish(store, 'komira-ai/json', '1.1.0', { state: 'yanked', yank_reason: 'bad' });
    await publish(store, 'komira-ai/json', '1.2.0', { state: 'pending' });
    const { res, body } = await call(deps, '/api/v2/packages/komira-ai/json');
    expect(res.statusCode).toBe(200);
    expect(body).toEqual({
      name: 'komira-ai/json',
      state: 'active',
      namespace: { namespace: 'komira-ai', kind: 'org', github_id: 100, login: 'komira-ai' },
      latest: '1.0.0',
      repository: null,
      license: 'MIT',
      description: 'JSON',
      keywords: ['json'],
      readme: '# json',
      created_at: '2026-10-01T00:00:00Z',
      versions: [
        { version: '1.1.0', state: 'yanked', published_at: '2026-10-13T12:00:00Z', yank_reason: 'bad' },
        { version: '1.0.0', state: 'published', published_at: '2026-10-13T12:00:00Z' },
      ],
    });
    expect(body).not.toHaveProperty('owners');
    expect(Object.keys(body).slice(0, 3)).toEqual(['name', 'state', 'namespace']);
  });

  test('a package with no version yet is readable and has no latest', async () => {
    const { store, deps } = await world();
    await newPackage(store, 'acme/http');
    const { res, body } = await call(deps, '/api/v2/packages/acme/http');
    expect(res.statusCode).toBe(200);
    expect(body.namespace).toEqual({ namespace: 'acme', kind: 'org', github_id: 200, login: 'acme' });
    expect(body.latest).toBeNull();
  });

  test('a package of a renamed user shows the login the registry knows', async () => {
    const { store, deps } = await world();
    await newPackage(store, 'octo/jq');
    const { body } = await call(deps, '/api/v2/packages/octo/jq');
    expect(body.namespace).toMatchObject({ namespace: 'octo', login: 'octo-new' });
  });

  test.each([
    ['/api/v2/packages/komira-ai/nothing', 404, 'package_not_found'],
    ['/api/v2/packages/nobody/json', 404, 'package_not_found'],
    ['/api/v2/packages/komira-ai/Bad-Name', 400, 'invalid_name'],
    ['/api/v2/packages/Bad_NS/json', 400, 'invalid_namespace'],
    ['/api/v2/packages/index/json', 403, 'namespace_reserved'],
    ['/api/v2/packages/komira-ai/http_client', 404, 'package_not_found'],
  ])('%s answers %i %s', async (path, status, code) => {
    const { store, deps } = await world();
    await newPackage(store, 'komira-ai/json');
    await newPackage(store, 'http_client');
    const { res, body } = await call(deps, path);
    expect(res.statusCode).toBe(status);
    expect(body.error.code).toBe(code);
  });

  test('a package whose namespace has no row is internal_error, not an answer', async () => {
    const { store, deps } = await world();
    await newPackage(store, 'ghost/json');
    const log = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    try {
      const { res, body } = await call(deps, '/api/v2/packages/ghost/json');
      expect(res.statusCode).toBe(500);
      expect(body.error.code).toBe('internal_error');
    } finally {
      log.mockRestore();
    }
  });

  test('without the v2 services every v2 read of a package is unavailable', async () => {
    const { store, deps } = await world();
    await newPackage(store, 'komira-ai/json');
    const { res, body } = await call({ ...deps, v2: undefined }, '/api/v2/packages/komira-ai/json');
    expect(res.statusCode).toBe(503);
    expect(body.error.code).toBe('unavailable');
  });

  test('v1 does not see a full name: it is an invalid name there', async () => {
    const { store, deps } = await world();
    await newPackage(store, 'komira-ai/json');
    const { res, body } = await call(deps, `/api/v1/packages/${encodeURIComponent('komira-ai/json')}`);
    expect(res.statusCode).toBe(400);
    expect(body.error.code).toBe('invalid_name');
  });
});

describe('listVersions and getVersion', () => {
  test('pages walk the versions of a full name newest first, pending never listed', async () => {
    const { store, deps } = await world();
    await newPackage(store, 'komira-ai/json');
    for (const v of ['1.0.0', '1.1.0', '1.2.0']) await publish(store, 'komira-ai/json', v);
    await publish(store, 'komira-ai/json', '2.0.0', { state: 'pending' });
    const first = await call(deps, '/api/v2/packages/komira-ai/json/versions', { limit: '2' });
    expect(first.body.versions.map((v: any) => v.version)).toEqual(['1.2.0', '1.1.0']);
    const second = await call(deps, '/api/v2/packages/komira-ai/json/versions', { limit: '2', cursor: first.body.next_cursor });
    expect(second.body.versions.map((v: any) => v.version)).toEqual(['1.0.0']);
    expect(second.body.next_cursor).toBeNull();
  });

  test.each([
    ['/api/v2/packages/komira-ai/nothing/versions', {}, 404, 'package_not_found'],
    ['/api/v2/packages/komira-ai/json/versions', { limit: '0' }, 400, 'invalid_request'],
    ['/api/v2/packages/komira-ai/json/versions', { cursor: 'x' }, 400, 'invalid_request'],
    ['/api/v2/packages/Bad_NS/json/versions', {}, 400, 'invalid_namespace'],
    ['/api/v2/packages/komira-ai/BAD/versions', {}, 400, 'invalid_name'],
  ])('%s %j answers %i %s', async (path, query, status, code) => {
    const { store, deps } = await world();
    await newPackage(store, 'komira-ai/json');
    const { res, body } = await call(deps, path, query);
    expect(res.statusCode).toBe(status);
    expect(body.error.code).toBe(code);
  });

  test('getVersion is VersionDetail with the full name', async () => {
    const { store, deps } = await world();
    await newPackage(store, 'komira-ai/json');
    await publish(store, 'komira-ai/json', '1.0.0');
    const { res, body } = await call(deps, '/api/v2/packages/komira-ai/json/1.0.0');
    expect(res.statusCode).toBe(200);
    expect(body).toMatchObject({ name: 'komira-ai/json', version: '1.0.0', state: 'published', provenance: { kind: 'none' } });
  });

  test.each([
    ['/api/v2/packages/komira-ai/json/9.9.9', 404, 'version_not_found'],
    ['/api/v2/packages/komira-ai/json/2.0.0', 404, 'version_not_found'], // pending
    ['/api/v2/packages/komira-ai/json/not-a-version', 400, 'invalid_version'],
    ['/api/v2/packages/komira-ai/nothing/1.0.0', 404, 'package_not_found'],
    ['/api/v2/packages/Bad_NS/json/1.0.0', 400, 'invalid_namespace'],
    ['/api/v2/packages/komira-ai/BAD/1.0.0', 400, 'invalid_name'],
  ])('%s answers %i %s', async (path, status, code) => {
    const { store, deps } = await world();
    await newPackage(store, 'komira-ai/json');
    await publish(store, 'komira-ai/json', '1.0.0');
    await publish(store, 'komira-ai/json', '2.0.0', { state: 'pending' });
    const { res, body } = await call(deps, path);
    expect(res.statusCode).toBe(status);
    expect(body.error.code).toBe(code);
  });
});

describe('searchPackages', () => {
  async function seeded() {
    const w = await world();
    await newPackage(w.store, 'komira-ai/json', '2026-10-01T00:00:00Z', 'JSON for Mojo');
    await newPackage(w.store, 'komira-ai/jsonrpc', '2026-10-02T00:00:00Z');
    await newPackage(w.store, 'komira-ai/http', '2026-10-03T00:00:00Z');
    await newPackage(w.store, 'acme/json', '2026-10-04T00:00:00Z');
    await newPackage(w.store, 'octo/jq', '2026-10-05T00:00:00Z');
    await newPackage(w.store, 'json_flat', '2026-10-06T00:00:00Z'); // a flat name: v1's
    await newPackage(w.store, 'http_client', '2026-10-07T00:00:00Z');
    await publish(w.store, 'komira-ai/json', '1.0.0', { published_at: '2026-10-20T00:00:00Z' });
    return w;
  }
  const names = (body: any) => body.packages.map((p: any) => p.name);

  test('a bare q is a name prefix in every namespace, results are full names, flat names never appear', async () => {
    const { deps } = await seeded();
    const { res, body } = await call(deps, '/api/v2/packages', { q: 'json' });
    expect(res.statusCode).toBe(200);
    expect(names(body)).toEqual(['acme/json', 'komira-ai/json', 'komira-ai/jsonrpc']);
    expect(body.next_cursor).toBeNull();
    expect(body.packages[1]).toEqual({ name: 'komira-ai/json', latest: '1.0.0', description: 'JSON for Mojo', updated_at: '2026-10-20T00:00:00Z' });
  });

  test('a bare q is matched on the name part, not the namespace', async () => {
    const { deps } = await seeded();
    expect(names((await call(deps, '/api/v2/packages', { q: 'komira' })).body)).toEqual([]);
    expect(names((await call(deps, '/api/v2/packages', { q: 'http' })).body)).toEqual(['komira-ai/http']);
  });

  test('a q with no value lists every full name and none of the flat ones', async () => {
    const { deps } = await seeded();
    expect(names((await call(deps, '/api/v2/packages')).body)).toEqual(['acme/json', 'komira-ai/http', 'komira-ai/json', 'komira-ai/jsonrpc', 'octo/jq']);
  });

  test('the name part is normalised like v1 (- . _ collapse to _), the namespace part is not', async () => {
    const { store, deps } = await seeded();
    await newPackage(store, 'komira-ai/http_client');
    expect(names((await call(deps, '/api/v2/packages', { q: 'HTTP-cli' })).body)).toEqual(['komira-ai/http_client']);
    expect(names((await call(deps, '/api/v2/packages', { q: 'komira-ai/http.cl' })).body)).toEqual(['komira-ai/http_client']);
  });

  test('<namespace>/ lists that namespace only, <namespace>/<prefix> narrows it', async () => {
    const { deps } = await seeded();
    expect(names((await call(deps, '/api/v2/packages', { q: 'komira-ai/' })).body)).toEqual(['komira-ai/http', 'komira-ai/json', 'komira-ai/jsonrpc']);
    expect(names((await call(deps, '/api/v2/packages', { q: 'komira-ai/json' })).body)).toEqual(['komira-ai/json', 'komira-ai/jsonrpc']);
    expect(names((await call(deps, '/api/v2/packages', { q: 'acme/json' })).body)).toEqual(['acme/json']);
    expect(names((await call(deps, '/api/v2/packages', { q: 'komira-ai/zzz' })).body)).toEqual([]);
  });

  test('the slash may be sent as %2F in any case', async () => {
    const { deps } = await seeded();
    expect(names((await call(deps, '/api/v2/packages', { q: 'komira-ai%2Fjsonrpc' })).body)).toEqual(['komira-ai/jsonrpc']);
    expect(names((await call(deps, '/api/v2/packages', { q: 'acme%2fjson' })).body)).toEqual(['acme/json']);
  });

  test('a namespace that is not a namespace is invalid_namespace; a reserved or unknown one matches nothing', async () => {
    const { deps } = await seeded();
    const bad = await call(deps, '/api/v2/packages', { q: 'Bad_NS/json' });
    expect(bad.res.statusCode).toBe(400);
    expect(bad.body.error.code).toBe('invalid_namespace');
    expect(names((await call(deps, '/api/v2/packages', { q: 'index/' })).body)).toEqual([]);
    expect(names((await call(deps, '/api/v2/packages', { q: 'nobody/' })).body)).toEqual([]);
  });

  test('a q longer than 104 characters, or a name part longer than 64, is invalid_request', async () => {
    const { deps } = await seeded();
    const long = await call(deps, '/api/v2/packages', { q: `${'a'.repeat(39)}/${'b'.repeat(65)}` });
    expect(long.res.statusCode).toBe(400);
    expect(long.body.error).toMatchObject({ code: 'invalid_request' });
    expect(long.body.error.message).toContain('104');
    const bare = await call(deps, '/api/v2/packages', { q: 'b'.repeat(65) });
    expect(bare.body.error.code).toBe('invalid_request');
    expect(bare.body.error.message).toContain('64');
    const exact = await call(deps, '/api/v2/packages', { q: `${'a'.repeat(39)}/${'b'.repeat(64)}` });
    expect(exact.res.statusCode).toBe(200);
  });

  test('limit and sort are checked as in v1', async () => {
    const { deps } = await seeded();
    expect((await call(deps, '/api/v2/packages', { limit: '101' })).body.error.code).toBe('invalid_request');
    expect((await call(deps, '/api/v2/packages', { sort: 'size' })).body.error.code).toBe('invalid_request');
  });

  test.each([{ q: 'json' }, { q: 'komira-ai/' }])('pages with cursors walk %j once, then end with a null cursor', async (query) => {
    const { deps } = await seeded();
    const seen: string[] = [];
    let cursor: string | undefined;
    for (let i = 0; i < 10; i++) {
      const { body } = await call(deps, '/api/v2/packages', { ...query, limit: '1', ...(cursor ? { cursor } : {}) });
      seen.push(...names(body));
      cursor = body.next_cursor ?? undefined;
      if (!cursor) break;
    }
    const all = (await call(deps, '/api/v2/packages', query)).body;
    expect(seen).toEqual(names(all));
    expect(seen.length).toBeGreaterThan(1);
  });

  test('a name cursor of another query is refused, in both forms', async () => {
    const { deps } = await seeded();
    const bare = (await call(deps, '/api/v2/packages', { q: 'json', limit: '1' })).body.next_cursor;
    expect((await call(deps, '/api/v2/packages', { q: 'http', cursor: bare })).body.error.code).toBe('invalid_request');
    const scoped = (await call(deps, '/api/v2/packages', { q: 'komira-ai/', limit: '1' })).body.next_cursor;
    expect((await call(deps, '/api/v2/packages', { q: 'acme/', cursor: scoped })).body.error.code).toBe('invalid_request');
    expect((await call(deps, '/api/v2/packages', { q: 'h', cursor: scoped })).res.statusCode).toBe(200);
    expect((await call(deps, '/api/v2/packages', { q: 'zzz', cursor: scoped })).body.error.code).toBe('invalid_request');
    // A flat name is no cursor of a bare v2 query.
    const flat = Buffer.from(JSON.stringify({ k: 'name', after: 'json_flat' })).toString('base64url');
    expect((await call(deps, '/api/v2/packages', { q: 'json', cursor: flat })).body.error.code).toBe('invalid_request');
  });

  test('sort=updated is newest publication first across namespaces, with a cursor that continues it', async () => {
    const { deps } = await seeded();
    const first = await call(deps, '/api/v2/packages', { q: 'json', sort: 'updated', limit: '2' });
    // komira-ai/json was published 2026-10-20; acme/json created 10-04; komira-ai/jsonrpc 10-02.
    expect(names(first.body)).toEqual(['komira-ai/json', 'acme/json']);
    const second = await call(deps, '/api/v2/packages', { q: 'json', sort: 'updated', limit: '2', cursor: first.body.next_cursor });
    expect(names(second.body)).toEqual(['komira-ai/jsonrpc']);
    expect(second.body.next_cursor).toBeNull();
    const scoped = await call(deps, '/api/v2/packages', { q: 'komira-ai/', sort: 'updated' });
    expect(names(scoped.body)).toEqual(['komira-ai/json', 'komira-ai/http', 'komira-ai/jsonrpc']);
  });

  test('sort=updated breaks a tie of times by full name', async () => {
    const { store, deps } = await world();
    for (const n of ['octo/cc', 'acme/aa', 'octo/bb', 'komira-ai/zz']) await newPackage(store, n, '2026-10-01T00:00:00Z');
    const { body } = await call(deps, '/api/v2/packages', { q: '', sort: 'updated' });
    expect(names(body)).toEqual(['acme/aa', 'komira-ai/zz', 'octo/bb', 'octo/cc']);
  });

  test('sort=updated with more than 1000 matches asks for a longer q', async () => {
    const { store, deps } = await world();
    for (let i = 0; i < 1001; i++) await newPackage(store, `acme/p${String(i).padStart(4, '0')}`);
    const { res, body } = await call(deps, '/api/v2/packages', { q: 'acme/', sort: 'updated' });
    expect(res.statusCode).toBe(400);
    expect(body.error.code).toBe('invalid_request');
    expect(body.error.message).toContain('1000');
  });

  test('a bare q reads the index in pages: matches beyond the first page are found', async () => {
    const { store, deps } = await world();
    for (let i = 0; i < 150; i++) await newPackage(store, `acme/a${String(i).padStart(3, '0')}`);
    await newPackage(store, 'komira-ai/zeta');
    const { body } = await call(deps, '/api/v2/packages', { q: 'zeta' });
    expect(names(body)).toEqual(['komira-ai/zeta']);
  });

  test('a bare q that would have to read more rows than the bound is refused, naming the bound; <namespace>/ still works', async () => {
    const { store, deps } = await world();
    for (let i = 0; i < MAX_SCAN_ROWS + 1; i++) await newPackage(store, `a${String(i).padStart(5, '0')}`); // flat rows sort before 'zeta/'
    await newPackage(store, 'komira-ai/zeta');
    for (const sort of ['name', 'updated']) {
      const { res, body } = await call(deps, '/api/v2/packages', { q: 'zeta', sort });
      expect(res.statusCode).toBe(400);
      expect(body.error.code).toBe('invalid_request');
      expect(body.error.message).toContain(String(MAX_SCAN_ROWS));
    }
    expect(names((await call(deps, '/api/v2/packages', { q: 'komira-ai/zeta' })).body)).toEqual(['komira-ai/zeta']);
  });
});

describe('/api/v1 never lists a full name', () => {
  test('a search by name, by prefix, and with no q lists flat names only', async () => {
    const { store, deps } = await world();
    await newPackage(store, 'json_flat');
    await newPackage(store, 'komira-ai/json');
    await newPackage(store, 'acme/json');
    await newPackage(store, 'zebra');
    expect(((await call(deps, '/api/v1/packages')).body.packages as any[]).map((p) => p.name)).toEqual(['json_flat', 'zebra']);
    expect(((await call(deps, '/api/v1/packages', { q: 'a' })).body.packages as any[]).map((p) => p.name)).toEqual([]);
    expect(((await call(deps, '/api/v1/packages', { q: 'komira-ai/' })).body.packages as any[]).map((p) => p.name)).toEqual([]);
    expect(((await call(deps, '/api/v1/packages', { q: 'json', sort: 'updated' })).body.packages as any[]).map((p) => p.name)).toEqual(['json_flat']);
  });

  test('a page is filled past full names: 150 full names between two flat ones do not shorten or end the list', async () => {
    const { store, deps } = await world();
    await newPackage(store, 'a_one');
    for (let i = 0; i < 150; i++) await newPackage(store, `acme/p${String(i).padStart(3, '0')}`);
    await newPackage(store, 'azure');
    const seen: string[] = [];
    let cursor: string | undefined;
    for (let i = 0; i < 5; i++) {
      const { body } = await call(deps, '/api/v1/packages', { q: 'a', limit: '1', ...(cursor ? { cursor } : {}) });
      seen.push(...body.packages.map((p: any) => p.name));
      cursor = body.next_cursor ?? undefined;
      if (!cursor) break;
    }
    expect(seen).toEqual(['a_one', 'azure']);
    const updated = await call(deps, '/api/v1/packages', { q: 'a', sort: 'updated' });
    expect(updated.body.packages.map((p: any) => p.name).sort()).toEqual(['a_one', 'azure']);
  });

  test('v2 and v1 each see only their own rows by name', async () => {
    const { store, deps } = await world();
    await newPackage(store, 'komira-ai/json');
    await newPackage(store, 'json');
    expect(((await call(deps, '/api/v1/packages', { q: 'json' })).body.packages as any[]).map((p) => p.name)).toEqual(['json']);
    expect(((await call(deps, '/api/v2/packages', { q: 'json' })).body.packages as any[]).map((p) => p.name)).toEqual(['komira-ai/json']);
    expect((await call(deps, '/api/v1/packages/json')).res.statusCode).toBe(200);
    expect((await call(deps, '/api/v2/packages/komira-ai/json')).res.statusCode).toBe(200);
  });
});
