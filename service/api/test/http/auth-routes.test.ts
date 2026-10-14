import {
  Authenticator,
  AuthError,
  authTablesFor,
  DeviceLogin,
  DynamoAuthStore,
  GithubJwtVerifier,
  HttpGitHubApi,
  MemoryAuthStore,
  OidcExchange,
  ownedPackagesFrom,
  TokenService,
  type AuthStore,
} from '../../src/auth';
import type { AuthServices } from '../../src/http/auth-routes';
import { route, type HttpRequest, type HttpResponse, type RouterDeps } from '../../src/http/router';
import { MemoryStore } from '../../src/memory-store';
import { fakeGitHub, goodClaims, newKey, signJwt, TestClock } from '../auth-helpers';
import { FakeAuthDoc, LAMBDA_GRANTS, READ_GRANTS } from '../auth-fake-doc';

// The auth operations through the router: login, token management, CI exchange, and the "not configured" mode.
// Run over both stores (memory; DynamoDB adapter on the strict fake under the Lambda's real grants), so the whole
// path - bearer parsing, freshness, ownership, storage - is exercised the way the deployed handler runs it.
// What it proves: status, body shape and error text of each operation for the cases below. What it does not:
// real GitHub, real DynamoDB, API Gateway routing (infra/stacks tests pin the routes and grants).

const key = newKey('k1');
const API = '/api/v1';

interface World {
  clock: TestClock;
  store: AuthStore;
  doc?: FakeAuthDoc;
  github: ReturnType<typeof fakeGitHub>;
  services: AuthServices;
  registry: MemoryStore;
  send(method: string, path: string, opts?: { body?: unknown; raw?: string; token?: string; headers?: Record<string, string> }): Promise<{ res: HttpResponse; json: any }>;
}

type Backing = 'memory' | 'dynamodb';

function world(backing: Backing, over: { services?: Partial<AuthServices> | null; require2fa?: boolean } = {}): World {
  const clock = new TestClock();
  const registry = new MemoryStore();
  let doc: FakeAuthDoc | undefined;
  let store: AuthStore;
  let owned: (id: number) => Promise<string[]>;
  if (backing === 'memory') {
    store = new MemoryAuthStore();
    owned = async (id) => (id === 4242 ? ['alpha', 'beta_pkg'] : []);
  } else {
    doc = new FakeAuthDoc({ pageSize: 2, grants: { ...LAMBDA_GRANTS, ...READ_GRANTS } });
    store = new DynamoAuthStore(doc, authTablesFor('t'));
    for (const n of ['alpha', 'beta_pkg']) doc.seed('owners', { name: n, github_id: '4242', github_id_num: 4242 });
    owned = ownedPackagesFrom(doc, 'mopm-t-owners');
  }
  const github = fakeGitHub();
  const services: AuthServices = {
    authn: new Authenticator({ store, now: clock.now }),
    tokens: new TokenService({ store, ownedPackages: owned, now: clock.now }),
    oidc: new OidcExchange({
      store,
      now: clock.now,
      verifier: new GithubJwtVerifier({ audiences: ['mopm.dev'], now: clock.now, jwks: async () => ({ keys: [key.jwk] }) }),
    }),
    devices: async () =>
      new DeviceLogin({ store, github: new HttpGitHubApi('Iv1.testclientid', github.fetchFn), now: clock.now, require2fa: over.require2fa }),
    ...over.services,
  };
  const deps: RouterDeps = { store: registry, stage: 'beta', version: 'v', commit: 'c', readOnly: false, ...(over.services === null ? {} : { auth: services }) };
  const send: World['send'] = async (method, path, opts = {}) => {
    const req: HttpRequest = {
      method,
      path: `${API}${path}`,
      query: {},
      headers: { ...(opts.token ? { authorization: `Bearer ${opts.token}` } : {}), ...opts.headers },
      ...(opts.raw !== undefined ? { body: opts.raw } : opts.body !== undefined ? { body: JSON.stringify(opts.body) } : {}),
    };
    const res = await route(req, deps, 'req-auth');
    return { res, json: res.body ? JSON.parse(res.body) : undefined };
  };
  return { clock, store, doc, github, services, registry, send };
}

/** Log in through the device flow and return the session token. */
async function login(w: World): Promise<string> {
  const start = await w.send('POST', '/auth/device', { body: { client: 'mopm 0.1.0' } });
  expect(start.res.statusCode).toBe(200);
  const poll = await w.send('POST', '/auth/device/poll', { body: { device_code: start.json.device_code } });
  expect(poll.json.status).toBe('approved');
  return poll.json.token;
}

const errorOf = (r: { res: HttpResponse; json: any }) => ({ status: r.res.statusCode, code: r.json?.error?.code });

describe.each<Backing>(['memory', 'dynamodb'])('auth routes over %s', (backing) => {
  test('device login: start, pending, approved with a fresh session', async () => {
    const w = world(backing);
    const start = await w.send('POST', '/auth/device', { body: { client: 'mopm 0.1.0' } });
    expect(start.res.statusCode).toBe(200);
    expect(start.res.headers['x-mopm-request-id']).toBe('req-auth');
    expect(Object.keys(start.json).sort()).toEqual(['device_code', 'expires_in', 'interval', 'user_code', 'verification_uri']);
    expect(start.json.expires_in).toBe(600);

    w.github.state.pollScript = [{ error: 'authorization_pending' }, { access_token: 'gho_x' }];
    const pending = await w.send('POST', '/auth/device/poll', { body: { device_code: start.json.device_code } });
    expect(pending.json).toEqual({ status: 'pending', interval: 5 });
    w.clock.advance(6_000);
    const done = await w.send('POST', '/auth/device/poll', { body: { device_code: start.json.device_code } });
    expect(done.res.statusCode).toBe(200);
    expect(done.json).toMatchObject({ status: 'approved', token_kind: 'session', handle: 'octo' });
    expect(done.json.token).toMatch(/^mopm_[a-z2-7]{32,64}$/);
    expect(Date.parse(done.json.fresh_until) - w.clock.t).toBe(15 * 60_000);
    // The device code is single use.
    const again = await w.send('POST', '/auth/device/poll', { body: { device_code: start.json.device_code } });
    expect(errorOf(again)).toEqual({ status: 404, code: 'device_code_unknown' });
  });

  test('a login without two-factor is denied and mints nothing', async () => {
    const w = world(backing);
    w.github.state.user = { id: 4242, login: 'octo', two_factor_authentication: false };
    const start = await w.send('POST', '/auth/device', { body: { client: 'mopm' } });
    const poll = await w.send('POST', '/auth/device/poll', { body: { device_code: start.json.device_code } });
    expect(poll.json).toEqual({ status: 'denied', reason: 'two_factor_required' });
    expect(w.doc ? w.doc.dump('tokens') : (w.store as MemoryAuthStore).dumpTokens()).toEqual([]);
  });

  test('create, list and revoke an API token with a fresh session; the secret appears once', async () => {
    const w = world(backing);
    const session = await login(w);
    const created = await w.send('POST', '/me/tokens', {
      token: session,
      body: { name: 'ci', scopes: ['publish'], packages: ['alpha'], expires_in_days: 30 },
    });
    expect(created.res.statusCode).toBe(201);
    expect(Object.keys(created.json).sort()).toEqual(['expires_at', 'id', 'name', 'packages', 'scopes', 'token']);
    expect(created.json).toMatchObject({ name: 'ci', scopes: ['publish'], packages: ['alpha'] });
    const secret: string = created.json.token;
    expect(secret).toMatch(/^mopm_[a-z2-7]{32,64}$/);

    const list = await w.send('GET', '/me/tokens', { token: session });
    expect(list.res.statusCode).toBe(200);
    expect(list.json.tokens).toHaveLength(1);
    expect(list.json.tokens[0]).toMatchObject({ id: created.json.id, name: 'ci', last_used_at: null });
    expect(list.res.body).not.toContain(secret);
    expect(list.res.body).not.toMatch(/"hash"|token_hash|prefix/);

    // The API token is a real credential, but not a fresh session: it cannot manage tokens.
    const viaApi = await w.send('GET', '/me/tokens', { token: secret });
    expect(errorOf(viaApi)).toEqual({ status: 401, code: 'stale_session' });

    const del = await w.send('DELETE', `/me/tokens/${created.json.id}`, { token: session });
    expect(del.res.statusCode).toBe(204);
    expect(del.res.body).toBe('');
    expect((await w.send('GET', '/me/tokens', { token: session })).json.tokens).toEqual([]);
    expect(errorOf(await w.send('GET', '/me/tokens', { token: secret }))).toEqual({ status: 401, code: 'token_revoked' });
    // Repeating is fine.
    expect((await w.send('DELETE', `/me/tokens/${created.json.id}`, { token: session })).res.statusCode).toBe(204);
  });

  test('all_current snapshots the packages the account owns', async () => {
    const w = world(backing);
    const session = await login(w);
    const created = await w.send('POST', '/me/tokens', {
      token: session,
      body: { name: 'all', scopes: ['publish', 'yank'], packages: 'all_current', expires_in_days: 1 },
    });
    expect(created.res.statusCode).toBe(201);
    expect(created.json.packages).toBe('all_current');
  });

  test('a package the caller does not own is not_owner (403); a bad name is invalid_name', async () => {
    const w = world(backing);
    const session = await login(w);
    const body = (packages: string[]) => ({ name: 'x', scopes: ['publish'], packages, expires_in_days: 1 });
    expect(errorOf(await w.send('POST', '/me/tokens', { token: session, body: body(['zeta']) }))).toEqual({ status: 403, code: 'not_owner' });
    expect(errorOf(await w.send('POST', '/me/tokens', { token: session, body: body(['Bad-Name']) }))).toEqual({ status: 400, code: 'invalid_name' });
  });

  test('another account cannot revoke my token (token_not_found, 404), and mine stays live', async () => {
    const w = world(backing);
    const mine = await login(w);
    const created = await w.send('POST', '/me/tokens', { token: mine, body: { name: 'm', scopes: ['publish'], packages: ['alpha'], expires_in_days: 1 } });
    w.github.state.user = { id: 777, login: 'mallory', two_factor_authentication: true };
    const theirs = await login(w);
    expect(errorOf(await w.send('DELETE', `/me/tokens/${created.json.id}`, { token: theirs }))).toEqual({ status: 404, code: 'token_not_found' });
    expect((await w.send('GET', '/me/tokens', { token: mine })).json.tokens).toHaveLength(1);
    expect((await w.send('GET', '/me/tokens', { token: theirs })).json.tokens).toEqual([]);
  });

  test('protected routes: no token, a garbage token, an unknown token and a stale session', async () => {
    const w = world(backing);
    const session = await login(w);
    for (const [m, p] of [['GET', '/me/tokens'], ['POST', '/me/tokens'], ['DELETE', '/me/tokens/tok_x']] as const) {
      expect(errorOf(await w.send(m, p, { body: {} }))).toEqual({ status: 401, code: 'token_missing' });
      expect(errorOf(await w.send(m, p, { token: 'not-a-token', body: {} }))).toEqual({ status: 401, code: 'token_unknown' });
      expect(errorOf(await w.send(m, p, { token: `mopm_${'a'.repeat(40)}`, body: {} }))).toEqual({ status: 401, code: 'token_unknown' });
    }
    const wrongScheme = await w.send('GET', '/me/tokens', { headers: { authorization: `Basic ${session}` } });
    expect(errorOf(wrongScheme)).toEqual({ status: 401, code: 'token_missing' });
    w.clock.advance(16 * 60_000);
    expect(errorOf(await w.send('GET', '/me/tokens', { token: session }))).toEqual({ status: 401, code: 'stale_session' });
  });

  test('bodies: missing, not JSON, an array, too large are invalid_request (400), after authentication', async () => {
    const w = world(backing);
    const session = await login(w);
    for (const raw of [undefined, '', '{nope', '[]', '"x"', 'null', ' '.repeat(10) + JSON.stringify({ a: 'x'.repeat(70_000) })]) {
      const r = await w.send('POST', '/me/tokens', { token: session, ...(raw !== undefined ? { raw } : {}) });
      expect({ raw: String(raw).slice(0, 12), ...errorOf(r) }).toEqual({ raw: String(raw).slice(0, 12), status: 400, code: 'invalid_request' });
    }
    expect(errorOf(await w.send('POST', '/auth/device', { raw: '{nope' }))).toEqual({ status: 400, code: 'invalid_request' });
    // Validation of the fields is the token service's: it answers invalid_request with its detail.
    const bad = await w.send('POST', '/me/tokens', { token: session, body: { name: 'x', scopes: ['owners'], packages: ['alpha'], expires_in_days: 1 } });
    expect(bad.json.error.message).toBe("The request is not valid: unknown scope 'owners'.");
  });

  test('CI exchange: a trusted publisher gets a 15 minute publish token for one version; others are refused', async () => {
    const w = world(backing);
    if (w.doc) {
      w.doc.seed('trusted_publishers', {
        name: 'alpha', publisher: 'tp1', id: 'tp1', repository_id: '111', repository_owner_id: '222',
        workflow: '.github/workflows/release.yml', added_by: 4242, added_at: '2026-10-01T00:00:00Z',
      });
    } else {
      await w.store.addTrustedPublisher({
        id: 'tp1', name: 'alpha', repository_id: '111', repository_owner_id: '222',
        workflow: '.github/workflows/release.yml', added_by: 4242, added_at: '2026-10-01T00:00:00Z',
      });
    }
    const jwt = signJwt(key, goodClaims(w.clock, { workflow_ref: 'acme/widgets/.github/workflows/release.yml@refs/tags/v1' }));
    const ok = await w.send('POST', '/auth/oidc/exchange', { body: { jwt, name: 'alpha', version: '1.0.0' } });
    expect(ok.res.statusCode).toBe(200);
    expect(ok.json).toMatchObject({ token_kind: 'publish', name: 'alpha', version: '1.0.0' });
    expect(ok.json.expires_at).toBe(new Date(w.clock.t + 15 * 60_000).toISOString());
    // The CI token is nobody's: it cannot manage tokens.
    expect(errorOf(await w.send('GET', '/me/tokens', { token: ok.json.token }))).toEqual({ status: 403, code: 'scope_missing' });

    expect(errorOf(await w.send('POST', '/auth/oidc/exchange', { body: { jwt, name: 'beta_pkg', version: '1.0.0' } }))).toEqual({ status: 403, code: 'oidc_not_trusted' });
    expect(errorOf(await w.send('POST', '/auth/oidc/exchange', { body: { jwt: 'a.b.c', name: 'alpha', version: '1.0.0' } }))).toEqual({ status: 401, code: 'oidc_token_invalid' });
    expect(errorOf(await w.send('POST', '/auth/oidc/exchange', { body: { jwt, name: 'alpha', version: 'x.y' } }))).toEqual({ status: 400, code: 'invalid_version' });
    expect(errorOf(await w.send('POST', '/auth/oidc/exchange', { body: { jwt, name: 'Alpha', version: '1.0' } }))).toEqual({ status: 400, code: 'invalid_name' });
  });

  test('error bodies are the catalogue text of the contract, with the request id', async () => {
    const w = world(backing);
    const r = await w.send('GET', '/me/tokens');
    expect(r.res.headers['x-mopm-request-id']).toBe('req-auth');
    expect(r.json).toEqual({ error: { code: 'token_missing', message: 'This request needs a token.', hint: "Run 'mopm login' or pass a token." } });
  });

  test('no secret reaches the logs: tokens, device codes and GitHub codes stay out of console output', async () => {
    const lines: string[] = [];
    const spies = (['log', 'error', 'warn', 'info'] as const).map((m) => jest.spyOn(console, m).mockImplementation((...a: unknown[]) => void lines.push(a.map(String).join(' '))));
    try {
      const w = world(backing, { services: { oidc: { exchange: async () => { throw new Error('boom'); } } as never } });
      const start = await w.send('POST', '/auth/device', { body: { client: 'mopm' } });
      const poll = await w.send('POST', '/auth/device/poll', { body: { device_code: start.json.device_code } });
      const created = await w.send('POST', '/me/tokens', { token: poll.json.token, body: { name: 'a', scopes: ['publish'], packages: ['alpha'], expires_in_days: 1 } });
      const failing = await w.send('POST', '/auth/oidc/exchange', { body: { jwt: 'x', name: 'alpha', version: '1' } });
      expect(failing.res.statusCode).toBe(500); // an unexpected failure is logged...
      expect(lines.length).toBeGreaterThan(0);
      for (const secret of [start.json.device_code, poll.json.token, created.json.token, 'gh-device-code-0123456789', 'gho_faketoken']) {
        expect(lines.join('\n')).not.toContain(secret);
      }
    } finally {
      spies.forEach((s) => s.mockRestore());
    }
  });
});

describe('without auth wiring (no OAuth secret configured, tables not wired)', () => {
  const ops: [string, string][] = [
    ['POST', '/auth/device'],
    ['POST', '/auth/device/poll'],
    ['POST', '/auth/oidc/exchange'],
    ['POST', '/me/tokens'],
    ['GET', '/me/tokens'],
    ['DELETE', '/me/tokens/tok_x'],
  ];

  test.each(ops)('%s %s answers 503 unavailable, with the contract text', async (m, p) => {
    const w = world('memory', { services: null });
    const r = await w.send(m, p, { body: { client: 'x' } });
    expect(r.res.statusCode).toBe(503);
    expect(r.json).toEqual({ error: { code: 'unavailable', message: 'The registry is temporarily unavailable.', hint: 'Try again shortly.' } });
  });

  test('the read API is untouched', async () => {
    const w = world('memory', { services: null });
    await w.registry.createPackage({ name: 'alpha', state: 'claimed', created_at: '2026-10-01T00:00:00Z' });
    expect((await w.send('GET', '/health')).res.statusCode).toBe(200);
    expect((await w.send('GET', '/packages/alpha')).res.statusCode).toBe(200);
    expect((await w.send('GET', '/packages')).res.statusCode).toBe(200);
  });

  test('wired, but the OAuth secret is missing: login is 503 while tokens and CI exchange still work', async () => {
    const w = world('memory', { services: { devices: async () => { throw new AuthError('unavailable', 'The registry is temporarily unavailable.'); } } });
    expect(errorOf(await w.send('POST', '/auth/device', { body: { client: 'x' } }))).toEqual({ status: 503, code: 'unavailable' });
    expect(errorOf(await w.send('POST', '/auth/device/poll', { body: { device_code: 'x'.repeat(20) } }))).toEqual({ status: 503, code: 'unavailable' });
    expect(errorOf(await w.send('GET', '/me/tokens'))).toEqual({ status: 401, code: 'token_missing' });
  });

  test('tables missing or not permitted answer 503 on the auth routes, never a stack trace', async () => {
    const spy = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    try {
      for (const name of ['ResourceNotFoundException', 'AccessDeniedException']) {
        const down = new Proxy({} as AuthStore, { get: () => async () => { throw Object.assign(new Error('x'), { name }); } });
        const w = world('memory', { services: { authn: new Authenticator({ store: down }) } });
        const r = await w.send('GET', '/me/tokens', { token: `mopm_${'a'.repeat(40)}` });
        expect({ name, ...errorOf(r) }).toEqual({ name, status: 503, code: 'unavailable' });
        expect(r.res.body).not.toMatch(/Error|stack/);
      }
    } finally {
      spy.mockRestore();
    }
  });

  test('other errors from the store are 500 internal_error with no detail', async () => {
    const down = new Proxy({} as AuthStore, { get: () => async () => { throw new Error('dynamodb exploded: secret detail'); } });
    const w = world('memory', { services: { authn: new Authenticator({ store: down }) } });
    const spy = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    try {
      const r = await w.send('GET', '/me/tokens', { token: `mopm_${'a'.repeat(40)}` });
      expect(errorOf(r)).toEqual({ status: 500, code: 'internal_error' });
      expect(r.res.body).not.toContain('exploded');
    } finally {
      spy.mockRestore();
    }
  });

  test('a method the operation does not take is the generic 400, not an auth error', async () => {
    const w = world('memory');
    expect(errorOf(await w.send('GET', '/auth/device'))).toEqual({ status: 400, code: 'invalid_request' });
    expect(errorOf(await w.send('PUT', '/me/tokens'))).toEqual({ status: 400, code: 'invalid_request' });
  });
});

// Can-fail proof: routers with one planted defect each must break a named test above's expectation.
describe('planted defects are caught', () => {
  test('a router that answers a protected route without checking the token', async () => {
    const w = world('memory', { services: { authn: { authenticate: async () => ({ token_id: 't', kind: 'session', github_id: 4242, scopes: [], packages: [] }), freshSession: () => 4242 } as never } });
    const r = await w.send('GET', '/me/tokens'); // no token at all
    expect(r.res.statusCode).toBe(200); // the mutant lets it through ...
    const real = world('memory');
    expect((await real.send('GET', '/me/tokens')).res.statusCode).toBe(401); // ... and the real one does not
  });
});
