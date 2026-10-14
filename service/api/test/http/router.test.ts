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

  test('a role without Scan gets 503 unavailable, not 500', async () => {
    const denied: Store = new Proxy({} as Store, {
      get: () => async () => { throw Object.assign(new Error('not authorized'), { name: 'AccessDeniedException' }); },
    });
    const { res, body } = await get(denied, '/api/v1/packages');
    expect(res.statusCode).toBe(503);
    expect(body.error.code).toBe('unavailable');
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
    expect(res.statusCode).toBe(400);
  });
});
