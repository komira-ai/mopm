// The tutorial gate (src/tutorial/gate.ts) against the contract examples of web-auth.json and tutorial-sandbox.json:
// every valid answer of the three routes it calls decodes or maps to the endpoint table's code; an answer that is not
// one (a malformed 2xx, a code outside the table, a non-JSON 5xx, no answer, the deadline) is tutorial_unavailable; the
// requests are same-origin with the session's CSRF value on each POST and no body; signInHref takes the start route's
// return_to grammar (the same as mopm_core's return_to.rs, held to the site's route vectors).
import { readFileSync } from 'fs';
import { join } from 'path';
import {
  CSRF_HEADER, GATE_ERROR_CODES, GATE_TIMEOUT_MS, type GateFetch, type GateTimers, LOGOUT_PATH, type RecordedAnswer,
  RETURN_TO_MAX, SANDBOX_PATH, SESSION_PATH, START_PATH, decodeGrant, decodeSession, errorCode, httpGate, isReturnPath,
  replayGate, signInHref,
} from '../src/tutorial/gate';
import { internalHref } from '../src/links';
import { type ContractCase, load } from './fixtures';

const OPS = ['getWebSession', 'webLogout', 'createTutorialSandbox'] as const;
const CASES = [...load('web-auth'), ...load('tutorial-sandbox')].filter((c) => (OPS as readonly string[]).includes(c.operationId));
const VALID = CASES.filter((c) => c.expect === undefined);

const answer = (c: ContractCase): RecordedAnswer => ({ status: c.response.status, headers: c.response.headers, body: c.response.body });
const named = (name: string): ContractCase => {
  const c = CASES.find((x) => x.name === name);
  if (c === undefined) throw new Error(`no contract case '${name}'`);
  return c;
};
const codeOf = (c: ContractCase): string => (c.response.body as { error: { code: string } }).error.code;
const rows = (op: string) => VALID.filter((c) => c.operationId === op).map((c) => [c.name, c] as const);

const SIGNED_IN = named('the signed-in user, with the CSRF value of the session');
const SESSION_BODY = SIGNED_IN.response.body as { login: string; csrf: string; expires_at: string };
const GRANT = named('a signed-in user gets a sandbox and what the browser needs to reach it');
const HTML_504: RecordedAnswer = { status: 504, headers: { 'content-type': 'text/html' }, text: '<html><body>504 Gateway Timeout</body></html>' };

test('the contract examples hold every code of the endpoint table, so each mapping below is exercised', () => {
  const codes = new Set(VALID.filter((c) => c.response.status >= 400).map(codeOf));
  expect([...codes].sort()).toEqual([...GATE_ERROR_CODES].sort());
  for (const op of OPS) expect(rows(op).length).toBeGreaterThan(0);
});

describe('session()', () => {
  test.each(rows('getWebSession'))('%s', async (_, c) => {
    const r = await replayGate({ getWebSession: [answer(c)] }).session();
    if (c.response.status === 200) expect(r).toEqual({ signed_in: true, ...(c.response.body as object) });
    else if (codeOf(c) === 'session_required') expect(r).toEqual({ signed_in: false });
    else expect(r).toEqual({ error: codeOf(c) });
  });

  test.each([
    'a session answer without csrf is refused',
    'a session answer whose csrf is not 43 characters is refused',
  ])('%s: tutorial_unavailable', async (name) => {
    expect(await replayGate({ getWebSession: [answer(named(name))] }).session()).toEqual({ error: 'tutorial_unavailable' });
  });

  test('is a same-origin GET with credentials, no CSRF header and no body', async () => {
    const g = replayGate({ getWebSession: [answer(SIGNED_IN)] });
    await g.session();
    expect(g.requests).toEqual([
      {
        operation: 'getWebSession',
        method: 'GET',
        url: SESSION_PATH,
        init: { method: 'GET', mode: 'same-origin', credentials: 'same-origin', cache: 'no-store', signal: expect.any(AbortSignal) },
      },
    ]);
  });
});

describe('sandbox()', () => {
  test.each(rows('createTutorialSandbox'))('%s', async (_, c) => {
    const r = await replayGate({ getWebSession: [answer(SIGNED_IN)], createTutorialSandbox: [answer(c)] }).sandbox();
    expect(r).toEqual(c.response.status === 201 ? c.response.body : { error: codeOf(c) });
  });

  test.each(['a grant without access_token is refused', 'a grant without expires_at is refused'])(
    '%s: tutorial_unavailable',
    async (name) => {
      const g = replayGate({ getWebSession: [answer(SIGNED_IN)], createTutorialSandbox: [answer(named(name))] });
      expect(await g.sandbox()).toEqual({ error: 'tutorial_unavailable' });
    },
  );

  test("asks for the session first, then POSTs with that session's CSRF value, same-origin, and no body", async () => {
    const g = replayGate({ getWebSession: [answer(SIGNED_IN)], createTutorialSandbox: [answer(GRANT)] });
    await g.sandbox();
    expect(g.requests.map((r) => [r.method, r.url])).toEqual([['GET', SESSION_PATH], ['POST', SANDBOX_PATH]]);
    expect(g.requests[1].init).toEqual({
      method: 'POST',
      mode: 'same-origin',
      credentials: 'same-origin',
      cache: 'no-store',
      signal: expect.any(AbortSignal),
      headers: { [CSRF_HEADER]: SESSION_BODY.csrf },
    });
    expect(g.requests[1].init.body).toBeUndefined();
  });

  test('reuses the CSRF value of the last session() answer, and a new answer replaces it', async () => {
    const other = { ...SESSION_BODY, csrf: 'B'.repeat(43) };
    const g = replayGate({
      getWebSession: [answer(SIGNED_IN), { status: 200, body: other }],
      createTutorialSandbox: [{ status: 403, body: named('a sandbox request with a wrong CSRF value is refused as csrf_failed').response.body }, answer(GRANT)],
    });
    expect(await g.sandbox()).toEqual({ error: 'csrf_failed' });
    // What the page does on csrf_failed: ask for the session again, and retry once.
    expect(await g.session()).toEqual({ signed_in: true, ...other });
    expect(await g.sandbox()).toEqual(GRANT.response.body);
    expect(g.requests.map((r) => [r.method, (r.init.headers as Record<string, string> | undefined)?.[CSRF_HEADER]])).toEqual([
      ['GET', undefined],
      ['POST', SESSION_BODY.csrf],
      ['GET', undefined],
      ['POST', 'B'.repeat(43)],
    ]);
  });

  test('signed out: session_required, and no POST is made', async () => {
    const g = replayGate({ getWebSession: [answer(named('the session of a signed-out browser is refused as session_required'))] });
    expect(await g.sandbox()).toEqual({ error: 'session_required' });
    expect(g.requests.map((r) => r.method)).toEqual(['GET']);
  });

  test('a session that cannot be read: its error, and no POST is made', async () => {
    const g = replayGate({ getWebSession: [HTML_504] });
    expect(await g.sandbox()).toEqual({ error: 'tutorial_unavailable' });
    expect(g.requests.map((r) => r.method)).toEqual(['GET']);
  });

  test('a session that expired between the two routes: session_required, and the CSRF value is dropped', async () => {
    const g = replayGate({
      getWebSession: [answer(SIGNED_IN), answer(named('the session of a signed-out browser is refused as session_required'))],
      createTutorialSandbox: [answer(named('a sandbox request from a signed-out browser is refused as session_required'))],
    });
    expect(await g.session()).toEqual({ signed_in: true, ...SESSION_BODY });
    expect(await g.sandbox()).toEqual({ error: 'session_required' });
    expect(await g.sandbox()).toEqual({ error: 'session_required' });
    expect(g.requests.map((r) => r.method)).toEqual(['GET', 'POST', 'GET']);
  });
});

describe('signOut()', () => {
  test.each(rows('webLogout'))('%s', async (_, c) => {
    const r = await replayGate({ getWebSession: [answer(SIGNED_IN)], webLogout: [answer(c)] }).signOut();
    if (c.response.status === 204 || codeOf(c) === 'session_required') expect(r).toEqual({ signed_out: true });
    else expect(r).toEqual({ error: codeOf(c) });
  });

  test('POSTs with the CSRF value and no body, and forgets the value after', async () => {
    const g = replayGate({
      getWebSession: [answer(SIGNED_IN)],
      webLogout: [answer(named('sign out answers 204 and clears the session cookie'))],
      createTutorialSandbox: [answer(GRANT)],
    });
    expect(await g.signOut()).toEqual({ signed_out: true });
    await g.sandbox();
    expect(g.requests.map((r) => [r.method, r.url])).toEqual([
      ['GET', SESSION_PATH],
      ['POST', LOGOUT_PATH],
      ['GET', SESSION_PATH],
      ['POST', SANDBOX_PATH],
    ]);
    expect(g.requests[1].init.headers).toEqual({ [CSRF_HEADER]: SESSION_BODY.csrf });
    expect(g.requests[1].init.body).toBeUndefined();
  });

  test('a browser that is already signed out is signed out, with no POST', async () => {
    const g = replayGate({ getWebSession: [answer(named('the session of a signed-out browser is refused as session_required'))] });
    expect(await g.signOut()).toEqual({ signed_out: true });
    expect(g.requests.map((r) => r.method)).toEqual(['GET']);
  });

  test('a session that cannot be read, or a sign-out with no answer: tutorial_unavailable', async () => {
    expect(await replayGate({ getWebSession: [HTML_504] }).signOut()).toEqual({ error: 'tutorial_unavailable' });
    expect(await replayGate({ getWebSession: [answer(SIGNED_IN)], webLogout: [HTML_504] }).signOut()).toEqual({ error: 'tutorial_unavailable' });
  });
});

describe('what is not an answer of the table is tutorial_unavailable', () => {
  const internal: RecordedAnswer = { status: 500, body: { error: { code: 'internal_error', message: 'x', hint: 'y' } } };
  const notFound: RecordedAnswer = { status: 404, body: { error: { code: 'route_not_found', message: 'x', hint: 'y' } } };
  const empty502: RecordedAnswer = { status: 502, text: '' };
  const htmlOk: RecordedAnswer = { status: 200, text: '<!doctype html><title>mopm</title>' };
  const grantAs200: RecordedAnswer = { status: 200, body: GRANT.response.body };
  const sessionAs201: RecordedAnswer = { status: 201, body: SESSION_BODY };

  test.each([
    ['a non-JSON 5xx (the edge answering for the API)', HTML_504],
    ['an empty 502', empty502],
    ['a code outside the table (internal_error)', internal],
    ['a code outside the table (route_not_found)', notFound],
    ['a 200 that is a page, not JSON', htmlOk],
    ['a session at another 2xx status', sessionAs201],
  ])('session(): %s', async (_, a) => {
    expect(await replayGate({ getWebSession: [a] }).session()).toEqual({ error: 'tutorial_unavailable' });
  });

  test.each([
    ['a non-JSON 5xx (the edge answering for the API)', HTML_504],
    ['an empty 502', empty502],
    ['a code outside the table (internal_error)', internal],
    ['a grant at another 2xx status', grantAs200],
    ['a 201 that is not JSON', { status: 201, text: 'created' }],
  ])('sandbox(): %s', async (_, a) => {
    const g = replayGate({ getWebSession: [answer(SIGNED_IN)], createTutorialSandbox: [a] });
    expect(await g.sandbox()).toEqual({ error: 'tutorial_unavailable' });
  });

  test('a route the fake has no answer for', async () => {
    const g = replayGate({});
    expect(await g.session()).toEqual({ error: 'tutorial_unavailable' });
    expect(await replayGate({ getWebSession: [] }).session()).toEqual({ error: 'tutorial_unavailable' });
    expect(g.requests.map((r) => r.operation)).toEqual(['getWebSession']);
  });

  test('a fetch that fails (offline), and a body that cannot be read', async () => {
    const offline = httpGate(async () => {
      throw new TypeError('Failed to fetch');
    });
    expect(await offline.session()).toEqual({ error: 'tutorial_unavailable' });
    const cut = httpGate(async () => ({ status: 200, text: () => Promise.reject(new TypeError('network error')) }) as unknown as Response);
    expect(await cut.session()).toEqual({ error: 'tutorial_unavailable' });
    // Signed in, then the POST gets no answer.
    const postFails: GateFetch = async (_, init) => {
      if (init.method === 'GET') return new Response(JSON.stringify(SESSION_BODY), { status: 200 });
      throw new TypeError('Failed to fetch');
    };
    expect(await httpGate(postFails).sandbox()).toEqual({ error: 'tutorial_unavailable' });
    expect(await httpGate(postFails).signOut()).toEqual({ error: 'tutorial_unavailable' });
  });

  test('the deadline: the request is aborted when the timer fires, and the timer is cleared after an answer', async () => {
    const timers: { fn: () => void; ms: number }[] = [];
    const cleared: unknown[] = [];
    const manual: GateTimers = {
      set: (fn, ms) => {
        timers.push({ fn, ms });
        return timers.length;
      },
      clear: (h) => cleared.push(h),
    };
    const hang: GateFetch = (_, init) =>
      new Promise((_, reject) => init.signal?.addEventListener('abort', () => reject(new DOMException('aborted', 'AbortError'))));
    const pending = httpGate(hang, GATE_TIMEOUT_MS, manual).session();
    expect(timers.map((t) => t.ms)).toEqual([30_000]);
    timers[0].fn();
    expect(await pending).toEqual({ error: 'tutorial_unavailable' });
    expect(cleared).toEqual([1]);
  });
});

describe('decoding', () => {
  const base = SESSION_BODY as Record<string, unknown>;
  test.each([
    ['not an object', 'alice'],
    ['null', null],
    ['an array', [base]],
    ['an empty login', { ...base, login: '' }],
    ['a login that is not a string', { ...base, login: 7 }],
    ['a CSRF value of 44 characters', { ...base, csrf: `${SESSION_BODY.csrf}x` }],
    ['a CSRF value outside base64url', { ...base, csrf: `${SESSION_BODY.csrf.slice(0, 42)}+` }],
    ['expires_at that is no time', { ...base, expires_at: 'next week' }],
    ['expires_at without a zone', { ...base, expires_at: '2026-11-26T12:00:00' }],
    ['expires_at on no calendar day', { ...base, expires_at: '2026-13-45T12:00:00Z' }],
  ])('a session with %s is refused', (_, v) => {
    expect(decodeSession(v)).toBeNull();
  });

  test('a session time without fractional seconds is read', () => {
    expect(decodeSession({ ...base, expires_at: '2026-11-26T12:00:00Z' })).toEqual({ signed_in: true, ...base, expires_at: '2026-11-26T12:00:00Z' });
  });

  const grant = GRANT.response.body as Record<string, unknown>;
  test.each([
    ['not an object', 'grant'],
    ['a sandbox id that would change the address (a dot)', { ...grant, sandbox_id: 'abc.evil' }],
    ['an empty sandbox id', { ...grant, sandbox_id: '' }],
    ['an empty access token', { ...grant, access_token: '' }],
    ['an access token that is not a string', { ...grant, access_token: 1 }],
    ['an empty envd version', { ...grant, envd_version: '' }],
    ['a null domain (the API resolves it)', { ...grant, domain: null }],
    ['a domain with a path', { ...grant, domain: 'e2b.app/x' }],
    ['a domain of one label', { ...grant, domain: 'localhost' }],
    ['a domain in capitals', { ...grant, domain: 'E2B.APP' }],
    ['no expires_at', { ...grant, expires_at: undefined }],
  ])('a grant with %s is refused', (_, v) => {
    expect(decodeGrant(v)).toBeNull();
  });

  test('a grant keeps exactly its five fields, and drops any other', () => {
    expect(decodeGrant({ ...grant, extra: 'x' })).toEqual(grant);
  });

  test.each([
    ['{"error":{"code":"csrf_failed","message":"m"}}', 'csrf_failed'],
    ['{"error":{"code":"invalid_request"}}', 'invalid_request'],
    ['{"error":{"code":"unavailable"}}', 'tutorial_unavailable'],
    ['{"error":"csrf_failed"}', 'tutorial_unavailable'],
    ['{"code":"csrf_failed"}', 'tutorial_unavailable'],
    ['null', 'tutorial_unavailable'],
    ['[]', 'tutorial_unavailable'],
    ['', 'tutorial_unavailable'],
    ['<html>', 'tutorial_unavailable'],
  ])('errorCode(%j) is %s', (body, code) => {
    expect(errorCode(body)).toBe(code);
  });
});

describe('signInHref', () => {
  test('is the start route with return_to encoded, as a same-site SafeHref', () => {
    const href = signInHref('/tutorial/hello');
    expect(href).toBe('/api/v2/auth/web/start?return_to=%2Ftutorial%2Fhello');
    expect(href.startsWith(`${START_PATH}?`)).toBe(true);
    expect(internalHref(href)).toBe(href);
    expect(replayGate({}).signInHref('/tutorial')).toBe('/api/v2/auth/web/start?return_to=%2Ftutorial');
  });

  test.each([
    '/',
    '/search',
    '/tutorial',
    '/tutorial/hello',
    '/tutorial/hello-world-2',
    '/tutorial/2',
    '/docs',
    '/docs/',
    '/docs/why',
    '/docs/getting-started/',
    '/packages/komira-ai/http_client',
    '/packages/9lives/a1/1.0.0',
    '/packages/komira-ai/http_client/versions',
    '/packages/ab/versions/versions',
  ])('keeps %j', (p) => {
    expect(isReturnPath(p)).toBe(true);
    expect(signInHref(p)).toBe(`${START_PATH}?return_to=${encodeURIComponent(p)}`);
  });

  test.each([
    '',
    'tutorial',
    'https://mopm.dev/tutorial',
    '//evil.example/tutorial',
    '/\\evil.example',
    '/tutorial\\hello',
    '/tutorial/',
    '/tutorial/Hello',
    '/tutorial/hello_world',
    '/tutorial/-hello',
    '/tutorial/hello--world',
    '/tutorial/hello/more',
    '/tutorial/hello?x=1',
    '/tutorial/hello#top',
    '/tutorial/he\tllo',
    '/tutorial/he\u0085llo',
    '/tutorial/%68ello',
    '/account',
    '/search/',
    '/docs/why/x',
    '/docs/Why',
    '/packages/komira-ai',
    '/packages/komira-ai/http__client',
    '/packages/komira-ai/http_client/1.0',
    '/packages/komira-ai/http_client/1.0.0/x',
    '/packages/komira-ai/http_client/Versions',
    '/packages/komira-ai/http_client/versions/',
    '/packages/komira-ai/http_client/versions/1.0.0',
    '/packages/komira-ai/Http_client/versions',
    `/tutorial/${'a'.repeat(RETURN_TO_MAX)}`,
  ])('refuses %j', (p) => {
    expect(isReturnPath(p)).toBe(false);
    expect(() => signInHref(p)).toThrow(`signInHref: '${p}' is not a page of the site`);
  });

  // As mopm_core's tests/return_to_routes.rs: a path is kept exactly when the edge router serves a page for it.
  test("the site's route vectors: a path is kept exactly when the site serves a page for it", () => {
    const doc = JSON.parse(readFileSync(join(__dirname, 'fixtures', 'routes.json'), 'utf8')) as { vectors: { path: string; edge: string }[] };
    const page = (edge: string) => edge === '/index.html' || edge === '/app.html' || (edge.startsWith('/docs/') && edge.endsWith('index.html'));
    const got = doc.vectors.map((v) => [v.path, isReturnPath(v.path)]);
    expect(got).toEqual(doc.vectors.map((v) => [v.path, page(v.edge)]));
    const kept = got.filter(([, k]) => k).length;
    expect(kept > 0 && kept < got.length).toBe(true);
  });
});
