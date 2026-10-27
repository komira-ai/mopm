// T4: every valid read fixture replays through the client: the URL is built from the request, the body decodes to
// exactly the fields that were sent (less the spec-only ones the site never reads), and the request id is kept.
// T5: the request is a simple CORS GET: no headers (so no preflight), no credentials.
import { client, type FetchFn } from '../src/api';
import { type ContractCase, responseOf, validReadCases } from './fixtures';

const BASE = 'https://api.mopm.dev/api/v1';

function recorder(res: () => Response): { fetchFn: FetchFn; calls: { url: string; init: RequestInit }[] } {
  const calls: { url: string; init: RequestInit }[] = [];
  return {
    calls,
    fetchFn: async (url, init) => {
      calls.push({ url, init });
      return res();
    },
  };
}

function call(c: ContractCase & { operationId: string }, fetchFn: FetchFn) {
  const api = client(fetchFn, BASE);
  const p = c.request.path ?? {};
  const q = c.request.query ?? {};
  switch (c.operationId) {
    case 'getHealth':
      return { result: api.getHealth(), path: '/health' };
    case 'searchPackages':
      return {
        result: api.searchPackages({
          q: q.q === undefined ? undefined : String(q.q),
          sort: q.sort === undefined ? undefined : (String(q.sort) as 'name' | 'updated'),
          cursor: q.cursor === undefined ? undefined : String(q.cursor),
          limit: q.limit === undefined ? undefined : Number(q.limit),
        }),
        path: '/packages',
      };
    case 'getPackage':
      return { result: api.getPackage(String(p.name)), path: `/packages/${p.name}` };
    case 'getVersion':
      return { result: api.getVersion(String(p.name), String(p.version)), path: `/packages/${p.name}/${p.version}` };
    default:
      throw new Error(`not a read operation: ${c.operationId}`);
  }
}

const cases = validReadCases();

test('the fixtures hold read cases of every kind the pages rely on', () => {
  const ops = new Set(cases.map((c) => c.operationId));
  expect([...ops].sort()).toEqual(['getHealth', 'getPackage', 'getVersion', 'searchPackages']);
  // A claimed package with no version (latest null), and yanked and tombstoned versions.
  expect(cases.some((c) => c.operationId === 'searchPackages' && JSON.stringify(c.response.body).includes('"latest":null'))).toBe(true);
  for (const s of ['yanked', 'tombstoned']) {
    expect(cases.some((c) => c.operationId === 'getVersion' && (c.response.body as { state: string }).state === s)).toBe(true);
  }
});

test.each(cases.map((c) => [`${c.operationId}: ${c.name}`, c] as const))('%s', async (_n, c) => {
  const { fetchFn, calls } = recorder(() => responseOf(c));
  const { result, path } = call(c, fetchFn);
  const r = await result;

  expect(calls).toHaveLength(1);
  const url = new URL(calls[0].url);
  expect(url.origin + url.pathname).toBe(BASE + path);
  const sent = Object.fromEntries(url.searchParams);
  const want = Object.fromEntries(Object.entries(c.request.query ?? {}).map(([k, v]) => [k, String(v)]));
  expect(sent).toEqual(want);

  if (r.kind !== 'ok') throw new Error(`expected ok, got ${JSON.stringify(r)}`);
  expect(r.requestId).toBe(c.response.headers['x-mopm-request-id']);
  // The decoded value is the body, field for field, minus the spec-only fields the site never reads. A decoder that
  // drops a field (a file's url, a tombstone, a yank reason) or alters one fails here; a field new to the fixtures
  // fails here too, until it is decoded or added to UNREAD.
  expect(r.value).toEqual(withoutUnread(c.operationId, c.response.body));
});

/** Fields the server sends that the site deliberately does not decode (spec-only; readme_html is never read, and the site shows no group or source commit). */
const UNREAD: Record<string, readonly string[]> = { getVersion: ['readme_html', 'group_id', 'source_commit'], getHealth: ['impl'] };

function withoutUnread(op: string, body: unknown): unknown {
  const b = { ...(body as Record<string, unknown>) };
  for (const k of UNREAD[op] ?? []) delete b[k];
  return b;
}

test('a claimed package (latest null, no versions) replays through getPackage', async () => {
  // No contract fixture holds one yet, so it is derived from the active package.
  const c = cases.find((x) => x.operationId === 'getPackage')!;
  const body = { ...(c.response.body as Record<string, unknown>), state: 'claimed', latest: null, versions: [] };
  const fetchFn: FetchFn = async () => new Response(JSON.stringify(body), { headers: c.response.headers });
  const r = await client(fetchFn, BASE).getPackage(String(c.request.path?.name));
  if (r.kind !== 'ok') throw new Error(`expected ok, got ${JSON.stringify(r)}`);
  expect(r.value).toEqual(body);
});

test('spec-only fields the server never sends are not decoded (readme_html is never read)', async () => {
  const c = cases.find((x) => x.operationId === 'getVersion' && (x.response.body as { readme_html?: unknown }).readme_html)!;
  const { fetchFn } = recorder(() => responseOf(c));
  const r = await call(c, fetchFn).result;
  if (r.kind !== 'ok') throw new Error('expected ok');
  expect(r.value).not.toHaveProperty('readme_html');
  expect(r.value).not.toHaveProperty('manifest');
});

describe('T5 request shape', () => {
  test('a GET with mode cors, credentials omit, no headers and an abort signal', async () => {
    const c = cases.find((x) => x.operationId === 'getPackage')!;
    const { fetchFn, calls } = recorder(() => responseOf(c));
    await client(fetchFn, BASE).getPackage('http_client');
    const init = calls[0].init;
    expect(init.method).toBe('GET');
    expect(init.mode).toBe('cors');
    expect(init.credentials).toBe('omit');
    expect(init.headers).toBeUndefined();
    expect(init.body).toBeUndefined();
    expect(init.signal).toBeInstanceOf(AbortSignal);
    expect(Object.keys(init).sort()).toEqual(['credentials', 'method', 'mode', 'signal']);
  });

  test('path segments are encoded', async () => {
    const { fetchFn, calls } = recorder(() => new Response('{}', { status: 404 }));
    await client(fetchFn, BASE).getVersion('a/b', '1.0?x');
    expect(calls[0].url).toBe(`${BASE}/packages/a%2Fb/1.0%3Fx`);
  });

  test('an empty search sends no query string', async () => {
    const { fetchFn, calls } = recorder(() => new Response('{"packages":[],"next_cursor":null}'));
    await client(fetchFn, BASE).searchPackages({});
    expect(calls[0].url).toBe(`${BASE}/packages`);
  });
});
