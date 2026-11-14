import { generateKeyPairSync, verify } from 'node:crypto';
import { APP_JWT_LIFETIME_SECONDS, GITHUB_CALL_TIMEOUT_MS, GitHubUnavailable, HttpGitHubAppApi, INSTALLATION_TOKEN_MARGIN_MS, type FetchLike } from '../src/auth';
import { TestClock } from './auth-helpers';
import { APP_ID, APP_PRIVATE_KEY, APP_PUBLIC_KEY, fakeGitHubApp } from './github-app-fake';

// The registry's GitHub App client (src/auth/github-app.ts) against the fake GitHub: how it authenticates, what it asks,
// and how it reads each answer. What the answers mean for a write is test/auth-org-membership.test.ts.

function rig() {
  const clock = new TestClock();
  const gh = fakeGitHubApp(clock.now);
  gh.install(5555, { id: 77, login: 'komira-ai' }).user(4242, 'alice').member('komira-ai', 'alice', 4242, 'admin');
  const app = new HttpGitHubAppApi({ appId: APP_ID, privateKey: APP_PRIVATE_KEY }, clock.now, gh.fetchFn);
  return { clock, gh, app };
}

const unavailable = (message: string) => expect.objectContaining({ name: 'GitHubUnavailable', message });

describe('credentials', () => {
  test.each([
    ['an App id that is not a number', { appId: 'mopm', privateKey: APP_PRIVATE_KEY }, 'the GitHub App id must be a positive number'],
    ['an App id of 0', { appId: '0', privateKey: APP_PRIVATE_KEY }, 'the GitHub App id must be a positive number'],
    ['an empty App id', { appId: '', privateKey: APP_PRIVATE_KEY }, 'the GitHub App id must be a positive number'],
  ])('%s is refused when the client is made', (_label, creds, message) => {
    expect(() => new HttpGitHubAppApi(creds)).toThrow(message);
  });

  test('a key that is not PEM is refused when the client is made', () => {
    expect(() => new HttpGitHubAppApi({ appId: APP_ID, privateKey: 'not a key' })).toThrow();
  });

  test('a private key that is not RSA is refused (GitHub signs App keys RS256)', () => {
    const ec = generateKeyPairSync('ec', { namedCurve: 'P-256' }).privateKey.export({ format: 'pem', type: 'pkcs8' }).toString();
    expect(() => new HttpGitHubAppApi({ appId: APP_ID, privateKey: ec })).toThrow('the GitHub App private key must be an RSA key');
  });
});

describe('the App JWT', () => {
  test('RS256, issuer the App id, dated a minute back, under 10 minutes long, signed with the App key', () => {
    const { app, clock } = rig();
    const [h, p, sig] = app.appJwt().split('.');
    expect(JSON.parse(Buffer.from(h!, 'base64url').toString())).toEqual({ alg: 'RS256', typ: 'JWT' });
    const iat = clock.seconds - 60;
    expect(JSON.parse(Buffer.from(p!, 'base64url').toString())).toEqual({ iat, exp: iat + APP_JWT_LIFETIME_SECONDS, iss: APP_ID });
    expect(APP_JWT_LIFETIME_SECONDS).toBeLessThan(600);
    expect(verify('RSA-SHA256', Buffer.from(`${h}.${p}`), APP_PUBLIC_KEY, Buffer.from(sig!, 'base64url'))).toBe(true);
  });

  test('with no clock given, the JWT is dated by the system clock', () => {
    jest.useFakeTimers({ now: new Date('2026-10-14T12:00:00Z') });
    try {
      const claims = JSON.parse(Buffer.from(new HttpGitHubAppApi({ appId: APP_ID, privateKey: APP_PRIVATE_KEY }).appJwt().split('.')[1]!, 'base64url').toString());
      expect(claims).toEqual({ iat: 1791979140, exp: 1791979140 + APP_JWT_LIFETIME_SECONDS, iss: APP_ID });
    } finally {
      jest.useRealTimers();
    }
  });

  test('a new JWT for each App call, dated by the clock: an hour later the fake GitHub still accepts it', async () => {
    const { app, clock } = rig();
    const first = app.appJwt();
    clock.advance(3600 * 1000);
    expect(app.appJwt()).not.toBe(first);
    expect(await app.getInstallation(5555)).toBeDefined();
  });

  test('the fake GitHub refuses a JWT signed with another key: the client is not trusted on its own word', async () => {
    const clock = new TestClock();
    const gh = fakeGitHubApp(clock.now).install(5555, { id: 77, login: 'komira-ai' });
    const other = generateKeyPairSync('rsa', { modulusLength: 2048 }).privateKey.export({ format: 'pem', type: 'pkcs8' }).toString();
    const app = new HttpGitHubAppApi({ appId: APP_ID, privateKey: other }, clock.now, gh.fetchFn);
    await expect(app.getInstallation(5555)).rejects.toEqual(unavailable('GitHub answered 401 for the installation'));
  });

  test('the App calls carry the JWT and GitHub\'s headers', async () => {
    const { gh, clock } = rig();
    const seen: Array<Record<string, string>> = [];
    const spy: FetchLike = async (url, init) => (seen.push(init.headers), gh.fetchFn(url, init));
    await new HttpGitHubAppApi({ appId: APP_ID, privateKey: APP_PRIVATE_KEY }, clock.now, spy).getOrgInstallation('komira-ai');
    expect(seen[0]).toEqual({
      accept: 'application/vnd.github+json',
      authorization: expect.stringMatching(/^Bearer [\w-]+\.[\w-]+\.[\w-]+$/),
      'user-agent': 'mopm-registry',
      'x-github-api-version': '2022-11-28',
    });
  });
});

describe('the reads', () => {
  test('an installation by id and by organization login: id, account id and login, not suspended', async () => {
    const { app } = rig();
    const want = { id: 5555, account: { id: 77, login: 'komira-ai' }, suspended: false };
    expect(await app.getInstallation(5555)).toEqual(want);
    expect(await app.getOrgInstallation('Komira-AI')).toEqual(want);
  });

  test('a suspended installation reads as suspended', async () => {
    const { app, gh } = rig();
    gh.state.installations.get(5555)!.suspended = true;
    expect(await app.getInstallation(5555)).toEqual({ id: 5555, account: { id: 77, login: 'komira-ai' }, suspended: true });
  });

  test('a user by id and a membership by logins, with the installation token', async () => {
    const { app, gh } = rig();
    expect(await app.getUserById(5555, 4242)).toEqual({ id: 4242, login: 'alice' });
    expect(await app.getOrgMembership(5555, 'komira-ai', 'alice')).toEqual({ user_id: 4242, state: 'active', role: 'admin' });
    const userCall = gh.state.calls.find((c) => c.path === '/user/4242')!;
    expect(userCall.auth).toBe('Bearer ghs_fake1');
  });

  test.each([
    ['getInstallation', (a: HttpGitHubAppApi) => a.getInstallation(1)],
    ['getOrgInstallation', (a: HttpGitHubAppApi) => a.getOrgInstallation('nobody')],
    ['getUserById', (a: HttpGitHubAppApi) => a.getUserById(5555, 1)],
    ['getOrgMembership', (a: HttpGitHubAppApi) => a.getOrgMembership(5555, 'komira-ai', 'bob')],
  ])('%s answers undefined for GitHub\'s 404', async (_m, call) => {
    expect(await call(rig().app)).toBeUndefined();
  });

  test('logins are sent encoded: a login is never a path of its own', async () => {
    const { gh, clock } = rig();
    const raw: string[] = [];
    const spy: FetchLike = async (url, init) => (raw.push(url), gh.fetchFn(url, init));
    const app = new HttpGitHubAppApi({ appId: APP_ID, privateKey: APP_PRIVATE_KEY }, clock.now, spy);
    await app.getOrgInstallation('a/b');
    await app.getOrgMembership(5555, 'komira-ai', '../x?y');
    expect(raw.filter((u) => !u.endsWith('/access_tokens'))).toEqual([
      'https://api.github.com/orgs/a%2Fb/installation',
      'https://api.github.com/orgs/komira-ai/memberships/..%2Fx%3Fy',
    ]);
  });
});

describe('the installation token', () => {
  test('minted once and reused until 5 minutes before GitHub says it expires, then minted again', async () => {
    const { app, gh, clock } = rig();
    await app.getUserById(5555, 4242);
    await app.getOrgMembership(5555, 'komira-ai', 'alice');
    clock.advance(3600 * 1000 - INSTALLATION_TOKEN_MARGIN_MS - 1000);
    await app.getUserById(5555, 4242);
    expect(gh.state.calls.filter((c) => c.path.endsWith('/access_tokens'))).toHaveLength(1);
    clock.advance(1000);
    await app.getUserById(5555, 4242);
    const mints = gh.state.calls.filter((c) => c.path.endsWith('/access_tokens'));
    expect(mints.map((c) => c.method)).toEqual(['POST', 'POST']);
    expect(gh.state.calls[gh.state.calls.length - 1]!.auth).toBe('Bearer ghs_fake2');
  });

  test('one token per installation', async () => {
    const { app, gh } = rig();
    gh.install(6666, { id: 88, login: 'other' });
    await app.getUserById(5555, 4242);
    await app.getUserById(6666, 4242);
    expect(gh.state.calls.filter((c) => c.path.endsWith('/access_tokens')).map((c) => c.path)).toEqual([
      '/app/installations/5555/access_tokens',
      '/app/installations/6666/access_tokens',
    ]);
  });

  test('a token GitHub revoked early (401) is dropped and minted again, and the call made once more', async () => {
    const { app, gh } = rig();
    await app.getUserById(5555, 4242);
    gh.revokeTokens();
    expect(await app.getOrgMembership(5555, 'komira-ai', 'alice')).toEqual({ user_id: 4242, state: 'active', role: 'admin' });
    expect(gh.state.calls.map((c) => `${c.method} ${c.path} ${c.auth.startsWith('Bearer ghs_') ? c.auth.slice(7) : 'jwt'}`)).toEqual([
      'POST /app/installations/5555/access_tokens jwt',
      'GET /user/4242 ghs_fake1',
      'GET /orgs/komira-ai/memberships/alice ghs_fake1',
      'POST /app/installations/5555/access_tokens jwt',
      'GET /orgs/komira-ai/memberships/alice ghs_fake2',
    ]);
    await app.getUserById(5555, 4242);
    expect(gh.state.calls[gh.state.calls.length - 1]!.auth).toBe('Bearer ghs_fake2');
  });

  test('a 401 that persists with a new token is unavailable after one more try, not a loop', async () => {
    const { app, gh } = rig();
    gh.state.faults.push({ path: /^\/user\//, status: 401 });
    await expect(app.getUserById(5555, 4242)).rejects.toEqual(unavailable('GitHub answered 401 for the user lookup'));
    expect(gh.state.calls.map((c) => c.path)).toEqual(['/app/installations/5555/access_tokens', '/user/4242', '/app/installations/5555/access_tokens', '/user/4242']);
  });

  test.each([403, 500])('a %s with the token keeps it: only a 401 says the token is bad', async (status) => {
    const { app, gh } = rig();
    gh.state.faults.push({ path: /^\/user\//, status });
    await expect(app.getUserById(5555, 4242)).rejects.toEqual(unavailable(`GitHub answered ${status} for the user lookup`));
    expect(gh.state.calls.filter((c) => c.path.endsWith('/access_tokens'))).toHaveLength(1);
  });

  test('an installation gone when its token is asked for is GitHub unavailable (there is nothing to ask with)', async () => {
    const { app } = rig();
    await expect(app.getUserById(1, 4242)).rejects.toEqual(unavailable('GitHub answered 404 for the installation token'));
  });

  test('a suspended installation gets no token: unavailable', async () => {
    const { app, gh } = rig();
    gh.state.installations.get(5555)!.suspended = true;
    await expect(app.getUserById(5555, 4242)).rejects.toEqual(unavailable('GitHub answered 403 for the installation token'));
  });

  test.each([
    ['no token', { expires_at: '2026-10-14T13:00:00Z' }],
    ['an empty token', { token: '', expires_at: '2026-10-14T13:00:00Z' }],
    ['no expiry', { token: 'ghs_x' }],
    ['an expiry that is not a time', { token: 'ghs_x', expires_at: 'soon' }],
  ])('a token answer with %s is unusable', async (_label, body) => {
    const { app, gh } = rig();
    gh.state.faults.push({ path: /access_tokens$/, body });
    await expect(app.getUserById(5555, 4242)).rejects.toEqual(unavailable('GitHub answered an unusable installation token'));
  });
});

describe('unusable answers are GitHub unavailable, never a guess', () => {
  test.each([
    ['an installation with no account', /^\/app\/installations\/\d+$/, { id: 5555 }, 'GitHub answered an unusable installation'],
    ['an installation with a null account', /^\/app\/installations\/\d+$/, { id: 5555, account: null }, 'GitHub answered an unusable installation'],
    ['an installation id of 0', /^\/app\/installations\/\d+$/, { id: 0, account: { id: 77, login: 'x' } }, 'GitHub answered an unusable installation'],
    ['an account with no login', /^\/app\/installations\/\d+$/, { id: 5555, account: { id: 77 } }, 'GitHub answered an unusable installation'],
    ['an account id that is not a number', /^\/app\/installations\/\d+$/, { id: 5555, account: { id: '77', login: 'x' } }, 'GitHub answered an unusable installation'],
    ['an installation as a list', /^\/app\/installations\/\d+$/, [], 'GitHub answered an unusable installation'],
    ['an installation as null', /^\/app\/installations\/\d+$/, null, 'GitHub answered an unusable installation'],
  ])('%s', async (_label, path, body, message) => {
    const { app, gh } = rig();
    gh.state.faults.push({ path, body });
    await expect(app.getInstallation(5555)).rejects.toEqual(unavailable(message));
  });

  test.each([
    ['no login', { id: 4242 }],
    ['an empty login', { id: 4242, login: '' }],
    ['no id', { login: 'alice' }],
  ])('a user with %s', async (_label, body) => {
    const { app, gh } = rig();
    gh.state.faults.push({ path: /^\/user\//, body });
    await expect(app.getUserById(5555, 4242)).rejects.toEqual(unavailable('GitHub answered an unusable user'));
  });

  test.each([
    ['no user', { state: 'active', role: 'admin' }],
    ['a null user', { state: 'active', role: 'admin', user: null }],
    ['a user with no id', { state: 'active', role: 'admin', user: { login: 'alice' } }],
    ['no state', { role: 'admin', user: { id: 4242 } }],
    ['a role that is not a string', { state: 'active', role: 1, user: { id: 4242 } }],
  ])('a membership with %s', async (_label, body) => {
    const { app, gh } = rig();
    gh.state.faults.push({ path: /^\/orgs\/[^/]+\/memberships\//, body });
    await expect(app.getOrgMembership(5555, 'komira-ai', 'alice')).rejects.toEqual(unavailable('GitHub answered an unusable membership'));
  });

  test('every call carries a time limit; a call abandoned at it is unavailable', async () => {
    const signals: unknown[] = [];
    const app = new HttpGitHubAppApi({ appId: APP_ID, privateKey: APP_PRIVATE_KEY }, () => new Date(), async (_url, init) => {
      signals.push(init.signal);
      throw new DOMException('The operation was aborted due to timeout', 'TimeoutError');
    });
    await expect(app.getInstallation(5555)).rejects.toEqual(unavailable('GitHub could not be read for the installation: TimeoutError'));
    expect(signals).toHaveLength(1);
    expect(signals[0]).toBeInstanceOf(AbortSignal);
    expect((signals[0] as AbortSignal).aborted).toBe(false);
    expect(GITHUB_CALL_TIMEOUT_MS).toBe(5000);
  });

  test('a rejected fetch with no error name still says unreachable', async () => {
    const app = new HttpGitHubAppApi({ appId: APP_ID, privateKey: APP_PRIVATE_KEY }, () => new Date(), async () => {
      throw undefined; // eslint-disable-line no-throw-literal
    });
    await expect(app.getInstallation(5555)).rejects.toEqual(unavailable('GitHub could not be read for the installation: undefined'));
    await expect(app.getInstallation(5555)).rejects.toBeInstanceOf(GitHubUnavailable);
  });
});
