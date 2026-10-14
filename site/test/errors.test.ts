// T6: error answers map to what a page shows: every errors.json envelope keeps its code and maps to the kind its
// code means; an unknown code, or an answer that is not an envelope, falls back to its status class; a rejected
// fetch is a network error and an aborted one a timeout.
import { client, type FetchFn } from '../src/api';
import { type ErrorKind, fromResponse, kindOfStatus } from '../src/errors';
import { READ_OPS, responseOf, validErrorCases } from './fixtures';

const BASE = 'https://api.mopm.dev/api/v1';

// Every code in errors.json. Read codes map by meaning; codes of other operations (which the site never calls) fall
// back to their status class. A new code in the fixtures fails the first test until it is added here.
const EXPECTED: Record<string, ErrorKind> = {
  invalid_request: 'invalid',
  invalid_name: 'invalid',
  invalid_version: 'invalid',
  package_not_found: 'notFound',
  version_not_found: 'notFound',
  route_not_found: 'notFound',
  rate_limited: 'busy',
  unavailable: 'busy',
  read_only_mode: 'busy',
  internal_error: 'server',
  // status-class fallbacks
  upload_invalid: 'invalid',
  token_missing: 'invalid',
  token_unknown: 'invalid',
  token_expired: 'invalid',
  token_revoked: 'invalid',
  stale_session: 'invalid',
  oidc_token_invalid: 'invalid',
  scope_missing: 'invalid',
  not_owner: 'invalid',
  name_reserved: 'invalid',
  oidc_not_trusted: 'invalid',
  user_not_found: 'notFound',
  invitation_not_found: 'notFound',
  device_code_unknown: 'notFound',
  token_not_found: 'notFound',
  owner_not_found: 'notFound',
  publish_not_found: 'notFound',
  name_taken: 'invalid',
  name_too_similar: 'invalid',
  version_exists: 'invalid',
  already_owner: 'invalid',
  last_owner: 'invalid',
  invalid_transition: 'invalid',
  upload_used: 'invalid',
  invitation_expired: 'invalid',
  payload_too_large: 'invalid',
};

const cases = validErrorCases();
const codeOf = (body: unknown): string => (body as { error: { code: string } }).error.code;

test.each(cases.map((c) => [`${c.response.status} ${codeOf(c.response.body)}`, c] as const))('%s', (_n, c) => {
  const code = codeOf(c.response.body);
  expect(Object.keys(EXPECTED)).toContain(code);
  const e = fromResponse(c.response.status, JSON.stringify(c.response.body), c.response.headers['x-mopm-request-id']);
  expect(e.kind).toBe(EXPECTED[code]);
  expect(e.code).toBe(code);
  const env = (c.response.body as { error: { message: string; hint?: string } }).error;
  expect(e.detail).toBe(env.message);
  // An empty hint carries nothing to show, so it is dropped.
  expect(e.hint).toBe(env.hint ? env.hint : undefined);
  expect(e.requestId).toBe('req-7f3a2c19d0e4');
  expect(e.status).toBe(c.response.status);
});

test('read-operation errors arrive through the client the same way', async () => {
  const reads = cases.filter((c) => (READ_OPS as readonly string[]).includes(c.operationId));
  expect(reads.length).toBeGreaterThanOrEqual(8);
  for (const c of reads) {
    const fetchFn: FetchFn = async () => responseOf(c);
    const api = client(fetchFn, BASE);
    const r = await (c.operationId === 'getHealth'
      ? api.getHealth()
      : c.operationId === 'searchPackages'
        ? api.searchPackages({})
        : c.operationId === 'getPackage'
          ? api.getPackage('nosuch')
          : api.getVersion('http_client', '9.9.9'));
    expect([c.name, r.kind]).toEqual([c.name, EXPECTED[codeOf(c.response.body)]]);
    if (r.kind === 'ok') throw new Error('expected an error');
    expect(r.requestId).toBe(c.response.headers['x-mopm-request-id']);
  }
});

test('the request id is kept on an answer that is not an envelope (a gateway 404, an HTML 502)', async () => {
  for (const [status, body, kind] of [
    [404, '<html>Not Found</html>', 'notFound'],
    [404, '{"message":"Not Found"}', 'notFound'],
    [502, '<html>Bad Gateway</html>', 'server'],
  ] as const) {
    const fetchFn: FetchFn = async () => new Response(body, { status, headers: { 'x-mopm-request-id': 'req-gw-1' } });
    const r = await client(fetchFn, BASE).getPackage('nosuch');
    expect(r).toMatchObject({ kind, status, requestId: 'req-gw-1' });
    expect(r).not.toHaveProperty('code');
  }
});

test('a busy registry says to try again shortly (retry-after is not readable from a page)', () => {
  const e = fromResponse(429, '{"error":{"code":"rate_limited","message":"Too many requests.","hint":"x"}}', null);
  expect(e.message).toBe('The registry is busy; try again shortly.');
});

test.each([
  [400, 'invalid'],
  [401, 'invalid'],
  [403, 'invalid'],
  [404, 'notFound'],
  [409, 'invalid'],
  [418, 'invalid'],
  [429, 'busy'],
  [500, 'server'],
  [502, 'server'],
  [503, 'busy'],
  [504, 'server'],
  [302, 'server'],
] as const)('an unknown code with status %d falls back to %s', (status, kind) => {
  expect(kindOfStatus(status)).toBe(kind);
  const e = fromResponse(status, '{"error":{"code":"brand_new_code","message":"m","hint":""}}', 'r');
  expect(e.kind).toBe(kind);
  expect(e.code).toBe('brand_new_code');
});

test('a known code wins over its status', () => {
  expect(fromResponse(400, '{"error":{"code":"package_not_found","message":"m","hint":""}}', null).kind).toBe('notFound');
});

test.each([
  ['the gateway 404', 404, '{"message":"Not Found"}', 'notFound'],
  ['an HTML 404', 404, '<html>Not Found</html>', 'notFound'],
  ['an empty 404', 404, '', 'notFound'],
  ['an HTML 502', 502, '<html>Bad Gateway</html>', 'server'],
  ['a JSON array 400', 400, '[1]', 'invalid'],
  ['an envelope without a message', 400, '{"error":{"code":"x"}}', 'invalid'],
  ['an inherited key as a code', 400, '{"error":{"code":"constructor","message":"m","hint":""}}', 'invalid'],
] as const)('%s is %s', (_n, status, body, kind) => {
  const e = fromResponse(status, body, null);
  expect(e.kind).toBe(kind);
});

test('a 200 whose body does not decode is a server error, with the request id', async () => {
  const fetchFn: FetchFn = async () => new Response('{"packages":"no"}', { headers: { 'x-mopm-request-id': 'r1' } });
  const r = await client(fetchFn, BASE).searchPackages({});
  expect(r).toMatchObject({ kind: 'server', requestId: 'r1' });
  const r2 = await client(async () => new Response('not json'), BASE).getHealth();
  expect(r2.kind).toBe('server');
});

test('a rejected fetch is a network error', async () => {
  const r = await client(async () => {
    throw new TypeError('Failed to fetch');
  }, BASE).getHealth();
  expect(r).toMatchObject({ kind: 'network', requestId: null });
});

test('an answer that takes longer than the timeout is aborted and reported as a timeout', async () => {
  let signal: AbortSignal | undefined;
  const hang: FetchFn = (_url, init) =>
    new Promise((_resolve, reject) => {
      signal = init.signal ?? undefined;
      init.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError')));
    });
  const r = await client(hang, BASE, 5).getHealth();
  expect(r.kind).toBe('timeout');
  expect(signal?.aborted).toBe(true);
});

test('a body that stalls past the timeout is a timeout too', async () => {
  const stall: FetchFn = async (_url, init) => {
    const body = new ReadableStream({
      start(ctl) {
        init.signal?.addEventListener('abort', () => ctl.error(new DOMException('aborted', 'AbortError')));
      },
    });
    return new Response(body, { status: 200 });
  };
  const r = await client(stall, BASE, 5).getHealth();
  expect(r.kind).toBe('timeout');
});
