import { AuthError, Authenticator, DeviceLogin, HttpGitHubApi, MemoryAuthStore, hashToken } from '../src/auth';
import { fakeGitHub, TestClock } from './auth-helpers';

function setup(opts: { require2fa?: boolean; gh?: Parameters<typeof fakeGitHub>[0] } = {}) {
  const clock = new TestClock();
  const store = new MemoryAuthStore();
  const fake = fakeGitHub(opts.gh);
  const github = new HttpGitHubApi('Iv1.testclientid', fake.fetchFn);
  const login = new DeviceLogin({ store, github, now: clock.now, require2fa: opts.require2fa });
  const auth = new Authenticator({ store, now: clock.now });
  return { clock, store, fake, login, auth };
}

async function err(p: Promise<unknown>): Promise<AuthError> {
  try {
    await p;
  } catch (e) {
    expect(e).toBeInstanceOf(AuthError);
    return e as AuthError;
  }
  throw new Error('expected an AuthError, got success');
}

describe('start', () => {
  test('returns our own device code plus GitHub\'s user code and verification URL; GitHub\'s device code is not handed out', async () => {
    const { login, fake, store } = setup();
    const s = await login.start({ client: 'mopm 0.1.0' });
    expect(s.user_code).toBe('WDJB-MJHT');
    expect(s.verification_uri).toBe('https://github.com/login/device');
    expect(s.device_code.length).toBeGreaterThanOrEqual(16);
    expect(s.device_code).not.toBe('gh-device-code-0123456789');
    expect(s.expires_in).toBe(600); // ten minutes, although GitHub allows fifteen
    expect(s.interval).toBe(5);
    // stored under the hash only
    const row = await store.getDeviceLogin(hashToken(s.device_code));
    expect(row?.github_device_code).toBe('gh-device-code-0123456789');
    expect(await store.getDeviceLogin(s.device_code)).toBeUndefined();
    expect(JSON.stringify(row)).not.toContain(s.device_code);
    // the request to GitHub carried the client id and the scope, and nothing secret
    const call = fake.state.calls[0]!;
    expect(call.url).toBe('https://github.com/login/device/code');
    expect(new URLSearchParams(call.body).get('client_id')).toBe('Iv1.testclientid');
    expect(new URLSearchParams(call.body).get('scope')).toBe('read:user');
    expect(new URLSearchParams(call.body).has('client_secret')).toBe(false);
  });

  test('a missing or oversize client is invalid_request', async () => {
    const { login } = setup();
    expect((await err(login.start({ client: '' }))).code).toBe('invalid_request');
    expect((await err(login.start({ client: 'x'.repeat(81) }))).code).toBe('invalid_request');
    expect((await err(login.start({} as never))).code).toBe('invalid_request');
  });

  test('GitHub failing is unavailable (503)', async () => {
    const { login, fake } = setup();
    const orig = fake.fetchFn;
    const down = new DeviceLogin({
      store: new MemoryAuthStore(),
      github: new HttpGitHubApi('cid', async (u, i) => ({ ...(await orig(u, i)), ok: false, status: 502 })),
    });
    const e = await err(down.start({ client: 'mopm' }));
    expect({ code: e.code, status: e.status }).toEqual({ code: 'unavailable', status: 503 });
    void login;
  });
});

describe('poll', () => {
  test('pending while the person has not decided, and GitHub is not asked again before the interval', async () => {
    const { login, fake, clock } = setup({ gh: { pollScript: [{ error: 'authorization_pending' }] } });
    const s = await login.start({ client: 'mopm' });
    expect(await login.poll({ device_code: s.device_code })).toEqual({ status: 'pending', interval: 5 });
    const githubPolls = () => fake.state.calls.filter((c) => c.url.endsWith('/access_token')).length;
    expect(githubPolls()).toBe(1);
    clock.advance(1000);
    // too fast: answered locally, interval grows
    expect(await login.poll({ device_code: s.device_code })).toEqual({ status: 'pending', interval: 10 });
    expect(githubPolls()).toBe(1);
    clock.advance(10_000);
    await login.poll({ device_code: s.device_code });
    expect(githubPolls()).toBe(2);
  });

  test('GitHub slow_down raises the interval', async () => {
    const { login } = setup({ gh: { pollScript: [{ error: 'slow_down', interval: 15 }] } });
    const s = await login.start({ client: 'mopm' });
    expect(await login.poll({ device_code: s.device_code })).toEqual({ status: 'pending', interval: 15 });
  });

  test('approved: user upserted by numeric id, a session token that is fresh for 15 minutes, handle returned', async () => {
    const { login, store, auth, clock, fake } = setup();
    const s = await login.start({ client: 'mopm 0.1.0' });
    const r = await login.poll({ device_code: s.device_code });
    if (r.status !== 'approved') throw new Error(`expected approved, got ${r.status}`);
    expect(r.handle).toBe('octo');
    expect(r.token_kind).toBe('session');
    expect(r.token).toMatch(/^mopm_[a-z2-7]{32,64}$/);
    expect(r.fresh_until).toBe(new Date(clock.t + 15 * 60_000).toISOString());
    expect(r.expires_at).toBe(new Date(clock.t + 30 * 86_400_000).toISOString());
    expect(await store.getUser(4242)).toMatchObject({ github_id: 4242, handle: 'octo', two_factor: true });
    const p = await auth.authenticate(`Bearer ${r.token}`);
    expect(p).toMatchObject({ kind: 'session', github_id: 4242 });
    expect(auth.freshSession(p)).toBe(4242);
    // GitHub's access token was used for the user lookup once, as a bearer, and is stored nowhere
    const userCall = fake.state.calls.find((c) => c.url === 'https://api.github.com/user')!;
    expect(userCall.headers.authorization).toBe('Bearer gho_faketoken');
    expect(JSON.stringify(store.dumpTokens())).not.toContain('gho_faketoken');
    expect(JSON.stringify(store.dumpTokens())).not.toContain(r.token);
  });

  test('the device code works once: a replay after approval is device_code_unknown', async () => {
    const { login } = setup();
    const s = await login.start({ client: 'mopm' });
    expect((await login.poll({ device_code: s.device_code })).status).toBe('approved');
    expect((await err(login.poll({ device_code: s.device_code }))).code).toBe('device_code_unknown');
  });

  test('logging in again as the same account keeps one user, keeps created_at and follows a renamed handle', async () => {
    const { login, store, clock, fake } = setup();
    await login.poll({ device_code: (await login.start({ client: 'mopm' })).device_code });
    const first = (await store.getUser(4242))!;
    clock.advance(86_400_000);
    fake.state.user = { id: 4242, login: 'octo-renamed', two_factor_authentication: true };
    const r = await login.poll({ device_code: (await login.start({ client: 'mopm' })).device_code });
    expect(r).toMatchObject({ status: 'approved', handle: 'octo-renamed' });
    const second = (await store.getUser(4242))!;
    expect(second.created_at).toBe(first.created_at);
    expect(second.handle).toBe('octo-renamed');
    expect(second.last_login_at).toBe(clock.now().toISOString());
  });

  test('a different account with the same login text is a different user (identity is the id)', async () => {
    const { login, store, fake } = setup();
    await login.poll({ device_code: (await login.start({ client: 'mopm' })).device_code });
    fake.state.user = { id: 9999, login: 'octo', two_factor_authentication: true };
    await login.poll({ device_code: (await login.start({ client: 'mopm' })).device_code });
    expect((await store.getUser(4242))?.github_id).toBe(4242);
    expect((await store.getUser(9999))?.github_id).toBe(9999);
  });

  test('the person denies on GitHub: denied, no user, no token; the code is spent', async () => {
    const { login, store } = setup({ gh: { pollScript: [{ error: 'access_denied' }] } });
    const s = await login.start({ client: 'mopm' });
    expect(await login.poll({ device_code: s.device_code })).toEqual({ status: 'denied', reason: 'github_denied' });
    expect(await store.getUser(4242)).toBeUndefined();
    expect(store.dumpTokens()).toHaveLength(0);
    expect((await err(login.poll({ device_code: s.device_code }))).code).toBe('device_code_unknown');
  });

  test('GitHub says the code expired: expired', async () => {
    const { login } = setup({ gh: { pollScript: [{ error: 'expired_token' }] } });
    const s = await login.start({ client: 'mopm' });
    expect(await login.poll({ device_code: s.device_code })).toEqual({ status: 'expired' });
  });

  test('our ten minutes pass: expired, without asking GitHub', async () => {
    const { login, clock, fake } = setup({ gh: { pollScript: [{ error: 'authorization_pending' }] } });
    const s = await login.start({ client: 'mopm' });
    clock.advance(600_000);
    expect(await login.poll({ device_code: s.device_code })).toEqual({ status: 'expired' });
    expect(fake.state.calls.some((c) => c.url.endsWith('/access_token'))).toBe(false);
  });

  test('unknown, short and non-string device codes are device_code_unknown', async () => {
    const { login } = setup();
    for (const device_code of ['x'.repeat(40), 'short', undefined as never]) {
      expect((await err(login.poll({ device_code }))).code).toBe('device_code_unknown');
    }
  });

  test('a GitHub error we do not understand is unavailable, not a login', async () => {
    const { login, store } = setup({ gh: { pollScript: [{ error: 'device_flow_disabled' }] } });
    const s = await login.start({ client: 'mopm' });
    expect((await err(login.poll({ device_code: s.device_code }))).code).toBe('unavailable');
    expect(store.dumpTokens()).toHaveLength(0);
  });

  test('a user lookup that fails or returns junk is unavailable and creates nothing', async () => {
    for (const gh of [{ userStatus: 500 }, { user: { id: 'abc', login: 'x' } }, { user: { id: 5, login: '' } }]) {
      const { login, store } = setup({ gh });
      const s = await login.start({ client: 'mopm' });
      expect((await err(login.poll({ device_code: s.device_code }))).code).toBe('unavailable');
      expect(store.dumpTokens()).toHaveLength(0);
    }
  });
});

describe('the two-factor requirement (a lean pending the CEO; defaults ON)', () => {
  test('on by default: an account GitHub says has 2FA off is denied, with no user and no token', async () => {
    const { login, store } = setup({ gh: { user: { id: 4242, login: 'octo', two_factor_authentication: false } } });
    const r = await login.poll({ device_code: (await login.start({ client: 'mopm' })).device_code });
    expect(r).toEqual({ status: 'denied', reason: 'two_factor_required' });
    expect(await store.getUser(4242)).toBeUndefined();
    expect(store.dumpTokens()).toHaveLength(0);
  });

  test('fails closed: when GitHub does not show the field, the login is denied', async () => {
    const { login, store } = setup({ gh: { user: { id: 4242, login: 'octo' } } });
    const r = await login.poll({ device_code: (await login.start({ client: 'mopm' })).device_code });
    expect(r).toEqual({ status: 'denied', reason: 'two_factor_required' });
    expect(store.dumpTokens()).toHaveLength(0);
  });

  test('switched off: the same accounts log in', async () => {
    for (const user of [{ id: 4242, login: 'octo', two_factor_authentication: false }, { id: 4242, login: 'octo' }]) {
      const { login, store } = setup({ require2fa: false, gh: { user } });
      const r = await login.poll({ device_code: (await login.start({ client: 'mopm' })).device_code });
      expect(r.status).toBe('approved');
      expect(await store.getUser(4242)).toBeDefined();
    }
  });
});
