import {
  Authenticator,
  DeviceLogin,
  HttpGitHubApi,
  MemoryAuthStore,
  MemoryNamespaceStore,
  ORG_PAGE_SIZE,
  ORG_PAGES_MAX,
  type GitHubApi,
} from '../src/auth';
import { fakeGitHub, TestClock } from './auth-helpers';

// Login and namespaces (docs/design/namespaces.md 2.1 to 2.3): the user namespace made at login, renames, reserved and
// out-of-grammar logins, and the organization memberships read with `read:org` for whoami.

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

const membership = (id: number, login: string, role = 'member', state = 'active') => ({
  state,
  role,
  organization: { id, login, url: `https://api.github.com/orgs/${login}` },
  user: { id: 4242, login: 'octo' },
});
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

describe('the organization memberships read at login (read:org, for whoami only)', () => {
  test('the login asks for read:user and read:org', async () => {
    const { login, fake } = setup();
    await login.start({ client: 'mopm' });
    expect(new URLSearchParams(fake.state.calls[0]!.body).get('scope')).toBe('read:user read:org');
  });

  test('active admin and member memberships are recorded; pending and billing-manager ones are not', async () => {
    const { as, store, fake } = setup({
      orgPages: [[membership(77, 'komira-ai', 'admin'), membership(78, 'acme'), membership(79, 'pending-org', 'member', 'pending'), membership(80, 'billing', 'billing_manager')]],
    });
    await as({ id: 4242, login: 'octo' });
    expect((await store.getUser(4242))?.orgs).toEqual([
      { github_id: 77, login: 'komira-ai', role: 'admin' },
      { github_id: 78, login: 'acme', role: 'member' },
    ]);
    const call = orgCalls(fake.state.calls)[0]!;
    expect(call).toMatchObject({ method: 'GET', url: 'https://api.github.com/user/memberships/orgs?state=active&per_page=100&page=1' });
    expect(call.headers.authorization).toBe('Bearer gho_faketoken');
    expect(JSON.stringify(store.dumpTokens())).not.toContain('gho_faketoken');
    expect(JSON.stringify(await store.getUser(4242))).not.toContain('gho_faketoken');
  });

  test('no membership is an empty list, read in one call', async () => {
    const { as, store, fake } = setup();
    await as({ id: 4242, login: 'octo' });
    expect((await store.getUser(4242))?.orgs).toEqual([]);
    expect(orgCalls(fake.state.calls)).toHaveLength(1);
  });

  test('a full page is followed by the next; a short page ends the list', async () => {
    const full = Array.from({ length: ORG_PAGE_SIZE }, (_, i) => membership(1000 + i, `org-${i}`));
    const { as, store, fake } = setup({ orgPages: [full, [membership(5, 'last')]] });
    await as({ id: 4242, login: 'octo' });
    const orgs = (await store.getUser(4242))!.orgs!;
    expect(orgs).toHaveLength(ORG_PAGE_SIZE + 1);
    expect(orgs[ORG_PAGE_SIZE]).toEqual({ github_id: 5, login: 'last', role: 'member' });
    expect(orgCalls(fake.state.calls).map((c) => c.url.split('&page=')[1])).toEqual(['1', '2']);
  });

  test('a full page exactly at the end costs one more call, answered empty', async () => {
    const full = Array.from({ length: ORG_PAGE_SIZE }, (_, i) => membership(1000 + i, `org-${i}`));
    const { as, store, fake } = setup({ orgPages: [full] });
    await as({ id: 4242, login: 'octo' });
    expect((await store.getUser(4242))!.orgs).toHaveLength(ORG_PAGE_SIZE);
    expect(orgCalls(fake.state.calls)).toHaveLength(2);
  });

  test(`at most ${ORG_PAGES_MAX} pages are read`, async () => {
    const pages = Array.from({ length: ORG_PAGES_MAX + 2 }, (_, p) => Array.from({ length: ORG_PAGE_SIZE }, (_, i) => membership(p * 1000 + i + 1, `org-${p}-${i}`)));
    const { as, store, fake } = setup({ orgPages: pages });
    await as({ id: 4242, login: 'octo' });
    expect(orgCalls(fake.state.calls)).toHaveLength(ORG_PAGES_MAX);
    expect((await store.getUser(4242))!.orgs).toHaveLength(ORG_PAGES_MAX * ORG_PAGE_SIZE);
  });

  test('a later login replaces the list: an organization left is gone', async () => {
    const { as, store, fake } = setup({ orgPages: [[membership(77, 'komira-ai'), membership(78, 'acme')]] });
    await as({ id: 4242, login: 'octo' });
    fake.state.orgPages = [[membership(78, 'acme-renamed', 'admin')]];
    await as({ id: 4242, login: 'octo' });
    expect((await store.getUser(4242))?.orgs).toEqual([{ github_id: 78, login: 'acme-renamed', role: 'admin' }]);
  });

  test.each([
    ['GitHub answers 500', { orgStatus: 500 }],
    ['GitHub answers 403 (the scope was not granted)', { orgStatus: 403 }],
    ['the answer is not a list', { orgPages: [{ message: 'no' }] }],
    ['a membership has no organization', { orgPages: [[{ state: 'active', role: 'member' }]] }],
    ['a membership is null', { orgPages: [[null]] }],
    ['an organization id is not a positive integer', { orgPages: [[{ ...membership(77, 'x'), organization: { id: 0, login: 'x' } }]] }],
    ['an organization id is not a number', { orgPages: [[{ ...membership(77, 'x'), organization: { id: '77', login: 'x' } }]] }],
    ['an organization login is empty', { orgPages: [[{ ...membership(77, 'x'), organization: { id: 77, login: '' } }]] }],
  ])('%s: the login still succeeds and keeps the list of the last good read', async (_what, broken) => {
    const { as, store, fake } = setup({ orgPages: [[membership(77, 'komira-ai', 'admin')]] });
    await as({ id: 4242, login: 'octo' });
    Object.assign(fake.state, broken);
    await as({ id: 4242, login: 'octo' });
    expect((await store.getUser(4242))?.orgs).toEqual([{ github_id: 77, login: 'komira-ai', role: 'admin' }]);
  });

  test.each([
    ['the request is rejected (GitHub unreachable)', async () => Promise.reject(new TypeError('fetch failed'))],
    ['the body is not JSON', async () => ({ ok: true, status: 200, json: async () => JSON.parse('<html>') })],
  ])('%s on the membership read: the login still succeeds and keeps the last list', async (_what, broken) => {
    const { as, store, fake } = setup({ orgPages: [[membership(77, 'komira-ai', 'admin')]] });
    await as({ id: 4242, login: 'octo' });
    const real = fake.fetchFn;
    const login = new DeviceLogin({
      store,
      namespaces: new MemoryNamespaceStore(),
      github: new HttpGitHubApi('Iv1.testclientid', async (url, init) => (url.includes('/user/memberships/orgs') ? broken() : real(url, init))),
    });
    const r = await login.poll({ device_code: (await login.start({ client: 'mopm' })).device_code });
    expect(r.status).toBe('approved');
    expect((await store.getUser(4242))?.orgs).toEqual([{ github_id: 77, login: 'komira-ai', role: 'admin' }]);
  });

  test('a first login whose membership read fails records no list, and the namespace is still made', async () => {
    const { as, store, namespaces } = setup({ orgStatus: 502 });
    await as({ id: 4242, login: 'octo' });
    expect(await store.getUser(4242)).not.toHaveProperty('orgs');
    expect((await namespaces.listNamespaces(4242)).map((n) => n.namespace)).toEqual(['octo']);
  });

  test('an unexpected error from the membership read is not swallowed', async () => {
    const clock = new TestClock();
    const store = new MemoryAuthStore();
    const fake = fakeGitHub();
    const http = new HttpGitHubApi('Iv1.testclientid', fake.fetchFn);
    const github: GitHubApi = {
      startDeviceFlow: (s) => http.startDeviceFlow(s),
      pollDeviceFlow: (c) => http.pollDeviceFlow(c),
      getUser: (t) => http.getUser(t),
      listOrgMemberships: async () => {
        throw new TypeError('a bug');
      },
    };
    const login = new DeviceLogin({ store, namespaces: new MemoryNamespaceStore(), github, now: clock.now });
    const s = await login.start({ client: 'mopm' });
    await expect(login.poll({ device_code: s.device_code })).rejects.toThrow('a bug');
    expect(store.dumpTokens()).toEqual([]);
  });
});
