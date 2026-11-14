import {
  Authenticator,
  DeviceLogin,
  HttpGitHubApi,
  MemoryAuthStore,
  MemoryNamespaceStore,
} from '../src/auth';
import { fakeGitHub, orgMembership, TestClock } from './auth-helpers';

// Login and namespaces (docs/design/namespaces.md 2.1 to 2.3): the user namespace made at login, renames, reserved and
// out-of-grammar logins, and the login's scope.

function setup(gh: Parameters<typeof fakeGitHub>[0] = {}, require2fa?: boolean) {
  const clock = new TestClock();
  const store = new MemoryAuthStore();
  const namespaces = new MemoryNamespaceStore();
  const fake = fakeGitHub(gh);
  const login = new DeviceLogin({ store, namespaces, github: new HttpGitHubApi('Iv1.testclientid', fake.fetchFn), now: clock.now, require2fa });
  const auth = new Authenticator({ store, now: clock.now });
  const as = async (user: Record<string, unknown>) => {
    fake.state.user = { two_factor_authentication: true, ...user };
    const r = await login.poll({ device_code: (await login.start({ client: 'mopm' })).device_code });
    if (r.status !== 'approved') throw new Error(`expected approved, got ${r.status}`);
    // The session works: logging in never depends on getting a namespace.
    expect(await auth.authenticate(`Bearer ${r.token}`)).toMatchObject({ kind: 'session', github_id: user.id });
    return r;
  };
  return { clock, store, namespaces, fake, login, as };
}

const orgCalls = <C extends { url: string }>(calls: C[]) => calls.filter((c) => c.url.includes('/user/memberships/orgs'));

describe('the user namespace at login', () => {
  test('the first login creates the user namespace, bound to the account id; the next one changes nothing', async () => {
    const { as, namespaces, clock } = setup();
    const first = clock.now().toISOString();
    await as({ id: 4242, login: 'octo' });
    expect(await namespaces.listNamespaces(4242)).toEqual([{ namespace: 'octo', kind: 'user', github_id: 4242, created_at: first }]);
    clock.advance(86_400_000);
    await as({ id: 4242, login: 'octo' });
    expect(await namespaces.listNamespaces(4242)).toEqual([{ namespace: 'octo', kind: 'user', github_id: 4242, created_at: first }]);
  });

  test('a login in mixed case makes the lower-case namespace; the handle keeps GitHub spelling', async () => {
    const { as, namespaces, store } = setup();
    const r = await as({ id: 4242, login: 'Octo-Cat' });
    expect(r.handle).toBe('Octo-Cat');
    expect((await namespaces.listNamespaces(4242)).map((n) => n.namespace)).toEqual(['octo-cat']);
    expect((await store.getUser(4242))?.handle).toBe('Octo-Cat');
  });

  test('the approved answer names the user namespace the login made, then the one it holds', async () => {
    const { as, clock } = setup();
    expect((await as({ id: 4242, login: 'Octo-Cat' })).namespace).toBe('octo-cat');
    clock.advance(86_400_000);
    expect((await as({ id: 4242, login: 'Octo-Cat' })).namespace).toBe('octo-cat');
  });

  test.each([
    ['linux-64', 'reserved'],
    ['alice_corp', 'outside the grammar'],
  ])('the approved answer has no namespace key for a login that is %s (%s)', async (login) => {
    const { as } = setup();
    expect(Object.keys(await as({ id: 4242, login }))).toEqual(['status', 'token', 'token_kind', 'expires_at', 'fresh_until', 'handle']);
  });

  test('the approved answer has no namespace key for a login another account holds', async () => {
    const { as } = setup();
    await as({ id: 4242, login: 'octo' });
    const r = await as({ id: 9999, login: 'octo' });
    expect(r).not.toHaveProperty('namespace');
  });

  test('a renamed account keeps the old namespace and gains the new one', async () => {
    const { as, namespaces, clock } = setup();
    const first = clock.now().toISOString();
    await as({ id: 4242, login: 'octo' });
    clock.advance(86_400_000);
    const second = clock.now().toISOString();
    const r = await as({ id: 4242, login: 'octo-renamed' });
    expect(r.handle).toBe('octo-renamed');
    expect(await namespaces.listNamespaces(4242)).toEqual([
      { namespace: 'octo', kind: 'user', github_id: 4242, created_at: first },
      { namespace: 'octo-renamed', kind: 'user', github_id: 4242, created_at: second },
    ]);
  });

  test('a new holder of an old login gets none, and logs in', async () => {
    const { as, namespaces } = setup();
    await as({ id: 4242, login: 'octo' });
    await as({ id: 4242, login: 'octo-renamed' });
    // Someone else takes "octo" on GitHub.
    const r = await as({ id: 9999, login: 'octo' });
    expect(r.handle).toBe('octo');
    expect(await namespaces.listNamespaces(9999)).toEqual([]);
    expect((await namespaces.getNamespace('octo'))?.github_id).toBe(4242);
  });

  test.each([
    ['linux-64', 'a conda subdir'],
    ['noarch', 'a conda subdir'],
    ['index', 'a channel bucket prefix'],
    ['Quarantine', 'a channel bucket prefix, in another case'],
    ['native-mirror', 'a channel bucket prefix'],
  ])('a reserved login (%s, %s) gets none, and logs in', async (login) => {
    const { as, namespaces, store } = setup();
    await as({ id: 4242, login });
    expect(await namespaces.listNamespaces(4242)).toEqual([]);
    expect(await namespaces.getNamespace(login.toLowerCase())).toBeUndefined();
    expect((await store.getUser(4242))?.handle).toBe(login);
  });

  test.each([
    ['alice_corp', 'an enterprise-managed login holds _'],
    ['trailing-', 'a trailing hyphen, which old GitHub logins may have'],
    ['double--hyphen', 'a double hyphen'],
    ['x'.repeat(40), 'longer than 39'],
  ])('a login outside the grammar (%s: %s) gets none, and logs in', async (login) => {
    const { as, namespaces } = setup();
    await as({ id: 4242, login });
    expect(await namespaces.listNamespaces(4242)).toEqual([]);
  });

  test('a login refused for two-factor makes no namespace and reads no memberships', async () => {
    const { login, fake, namespaces } = setup({ user: { id: 4242, login: 'octo', two_factor_authentication: false } });
    const r = await login.poll({ device_code: (await login.start({ client: 'mopm' })).device_code });
    expect(r).toEqual({ status: 'denied', reason: 'two_factor_required' });
    expect(await namespaces.listNamespaces(4242)).toEqual([]);
    expect(orgCalls(fake.state.calls)).toEqual([]);
  });

  test('a namespace store failure fails the login: no session is minted', async () => {
    const clock = new TestClock();
    const store = new MemoryAuthStore();
    const fake = fakeGitHub();
    const namespaces = new MemoryNamespaceStore();
    namespaces.getNamespace = async () => {
      throw new Error('store down');
    };
    const login = new DeviceLogin({ store, namespaces, github: new HttpGitHubApi('Iv1.testclientid', fake.fetchFn), now: clock.now });
    const s = await login.start({ client: 'mopm' });
    await expect(login.poll({ device_code: s.device_code })).rejects.toThrow('store down');
    expect(store.dumpTokens()).toEqual([]);
  });
});

describe('the login asks for read:user only and reads no organization', () => {
  test('the login asks for read:user alone', async () => {
    const { login, fake } = setup();
    await login.start({ client: 'mopm' });
    expect(new URLSearchParams(fake.state.calls[0]!.body).get('scope')).toBe('read:user');
  });

  test('a login makes no organization call and records no organization on the user row', async () => {
    const { as, store, fake } = setup({ memberships: { 'komira-ai': { body: orgMembership({ id: 77, login: 'komira-ai' }) } } });
    await as({ id: 4242, login: 'octo' });
    expect(orgCalls(fake.state.calls)).toEqual([]);
    expect(await store.getUser(4242)).not.toHaveProperty('orgs');
    expect(JSON.stringify(store.dumpTokens())).not.toContain('gho_faketoken');
  });
});
