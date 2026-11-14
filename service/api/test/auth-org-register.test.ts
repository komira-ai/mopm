import {
  AuthError,
  DeviceLogin,
  DynamoAuthStore,
  DynamoNamespaceStore,
  HttpGitHubApi,
  MemoryAuthStore,
  MemoryNamespaceStore,
  NamespaceError,
  OrgRegistration,
  authTablesFor,
  hashToken,
  type AuthStore,
  type NamespaceStore,
} from '../src/auth';
import { FakeAuthDoc, LAMBDA_GRANTS } from './auth-fake-doc';
import { fakeGitHub, orgMembership, TestClock } from './auth-helpers';

// Registering an organization namespace (src/auth/org-register.ts): GitHub is asked once, with a token read only for this call,
// and never about the organization again. Each case runs over the memory adapters and over the DynamoDB adapters on the strict
// fake under the Lambda grants.

const DAVE = 2002;
const ORG_ID = 99;
const TOKEN = 'gho_faketoken';

type Backing = 'memory' | 'dynamodb';

async function setup(backing: Backing, gh: Parameters<typeof fakeGitHub>[0] = {}) {
  const clock = new TestClock();
  let store: AuthStore;
  let namespaces: NamespaceStore;
  let dump: () => string;
  if (backing === 'memory') {
    const s = new MemoryAuthStore();
    const n = new MemoryNamespaceStore();
    store = s;
    namespaces = n;
    dump = () => JSON.stringify([s, n], (_k, v) => (v instanceof Map ? [...v] : v));
  } else {
    const doc = new FakeAuthDoc({ pageSize: 2, grants: LAMBDA_GRANTS });
    const tables = authTablesFor('t');
    store = new DynamoAuthStore(doc, tables);
    namespaces = new DynamoNamespaceStore(doc, tables.namespaces, tables.namespace_members);
    dump = () => JSON.stringify([...doc.tables.entries()].map(([k, v]) => [k, [...v.values()]]));
  }
  const fake = fakeGitHub({
    user: { id: DAVE, login: 'dave', two_factor_authentication: true },
    memberships: { 'acme-labs': { body: orgMembership({ id: ORG_ID, login: 'acme-labs' }, 'admin', 'active', DAVE) } },
    ...gh,
  });
  const github = new HttpGitHubApi('Iv1.testclientid', fake.fetchFn);
  const at = clock.now().toISOString();
  await store.upsertUser(DAVE, 'Dave', at, true);
  await namespaces.createNamespace({ namespace: 'dave', kind: 'user', github_id: DAVE, created_at: at });
  const reg = new OrgRegistration({ store, namespaces, github, now: clock.now });
  const login = new DeviceLogin({ store, namespaces, github, now: clock.now });
  const orgCalls = () => fake.state.calls.filter((c) => c.url.includes('/user/memberships/orgs'));
  return { clock, store, namespaces, fake, reg, login, dump, orgCalls };
}

/** `namespaces` with the user namespace `dave` of DAVE, whom a registration needs as a caller. */
async function withDave<T extends NamespaceStore>(namespaces: T): Promise<T> {
  await namespaces.createNamespace({ namespace: 'dave', kind: 'user', github_id: DAVE, created_at: 'x' });
  return namespaces;
}

async function refusal(p: Promise<unknown>) {
  try {
    await p;
  } catch (e) {
    expect(e instanceof AuthError || e instanceof NamespaceError).toBe(true);
    const err = e as AuthError | NamespaceError;
    return { code: err.code, status: err.status, message: err.message, detail: err.detail };
  }
  throw new Error('expected a refusal');
}

describe.each<Backing>(['memory', 'dynamodb'])('registering an organization namespace on %s', (backing) => {
  const rig = (gh?: Parameters<typeof fakeGitHub>[0]) => setup(backing, gh);

  describe('start', () => {
    test('asks GitHub for the read:org scope and answers the login shape; the device row is bound to the caller and the namespace', async () => {
      const r = await rig();
      const s = await r.reg.start(DAVE, 'acme-labs');
      expect(new URLSearchParams(r.fake.state.calls[0]!.body).get('scope')).toBe('read:org');
      expect(s).toEqual({ device_code: expect.stringMatching(/^dev_[0-9a-f]{48}$/), user_code: 'WDJB-MJHT', verification_uri: 'https://github.com/login/device', expires_in: 600, interval: 5 });
      const row = await r.store.getDeviceLogin(hashToken(s.device_code));
      expect(row).toMatchObject({ org_namespace: 'acme-labs', account_id: DAVE, github_device_code: 'gh-device-code-0123456789' });
      expect(JSON.stringify(row)).not.toContain(s.device_code);
    });

    test.each([
      ['a string outside the grammar', 'Acme-Labs', 'invalid_namespace', 400],
      ['a reserved string', 'index', 'namespace_reserved', 403],
      ['poll, the path of the poll operation', 'poll', 'namespace_reserved', 403],
    ])('%s is refused before GitHub is asked', async (_why, ns, code, status) => {
      const r = await rig();
      const e = await refusal(r.reg.start(DAVE, ns));
      expect([e.code, e.status]).toEqual([code, status]);
      expect(r.fake.state.calls).toEqual([]);
    });

    test('a namespace of any kind that is held is namespace_taken, before GitHub is asked', async () => {
      const r = await rig();
      await r.namespaces.createOrgNamespace(
        { namespace: 'komira-ai', kind: 'org', github_id: 77, created_at: 'x', created_by: 1 },
        { namespace: 'komira-ai', github_id: 1, role: 'owner', added_by: 1, added_at: 'x' },
      );
      for (const ns of ['dave', 'komira-ai']) {
        expect(await refusal(r.reg.start(DAVE, ns))).toEqual({ code: 'namespace_taken', status: 409, message: `'${ns}' is taken.`, detail: { namespace: ns } });
      }
      expect(r.fake.state.calls).toEqual([]);
    });

    test('a caller that holds no user namespace is user_not_found with its handle in lower case, before GitHub is asked', async () => {
      const r = await rig();
      await r.store.upsertUser(5005, 'Enterprise_Login', r.clock.now().toISOString(), true);
      expect(await refusal(r.reg.start(5005, 'acme-labs'))).toEqual({
        code: 'user_not_found',
        status: 404,
        message: "There is no mopm user 'enterprise_login'.",
        detail: { user: 'enterprise_login' },
      });
      expect((await refusal(r.reg.start(5006, 'acme-labs'))).message).toBe("There is no mopm user '5006'.");
      expect((await refusal(r.reg.start(5005, 'Acme-Labs'))).code).toBe('invalid_namespace');
      expect(r.fake.state.calls).toEqual([]);
    });

    test('a namespace that is not a string is invalid_request', async () => {
      const r = await rig();
      expect((await refusal(r.reg.start(DAVE, 7))).code).toBe('invalid_request');
      expect(r.fake.state.calls).toEqual([]);
    });
  });

  describe('poll: the registration passes', () => {
    test('an active admin of the organization registers it: the row holds the organization id, the registrant is its first owner', async () => {
      const r = await rig();
      const s = await r.reg.start(DAVE, 'acme-labs');
      const at = r.clock.now().toISOString();
      const p = await r.reg.poll(DAVE, s.device_code);
      expect(p).toEqual({ status: 'created', record: { namespace: 'acme-labs', kind: 'org', github_id: ORG_ID, created_at: at, created_by: DAVE } });
      expect(await r.namespaces.getNamespace('acme-labs')).toMatchObject({ kind: 'org', github_id: ORG_ID, created_by: DAVE });
      expect(await r.namespaces.listMembers('acme-labs')).toEqual([{ namespace: 'acme-labs', github_id: DAVE, role: 'owner', added_by: DAVE, added_at: at }]);
      expect(await r.namespaces.listMemberships(DAVE)).toHaveLength(1);
      const call = r.orgCalls()[0]!;
      expect(call).toMatchObject({ method: 'GET', url: 'https://api.github.com/user/memberships/orgs/acme-labs' });
      expect(call.headers.authorization).toBe(`Bearer ${TOKEN}`);
    });

    test('the GitHub token is never stored: no row of any table holds it, and the device row is gone', async () => {
      const r = await rig();
      const s = await r.reg.start(DAVE, 'acme-labs');
      await r.reg.poll(DAVE, s.device_code);
      expect(r.dump()).not.toContain(TOKEN);
      expect(await r.store.getDeviceLogin(hashToken(s.device_code))).toBeUndefined();
    });

    test('the organization is matched by its current login in lower case: a login in mixed case is the namespace', async () => {
      const r = await rig({ memberships: { 'acme-labs': { body: orgMembership({ id: ORG_ID, login: 'Acme-Labs' }, 'admin', 'active', DAVE) } } });
      const s = await r.reg.start(DAVE, 'acme-labs');
      expect((await r.reg.poll(DAVE, s.device_code)).status).toBe('created');
    });

    test('a renamed organization: its new login is a second namespace with the same GitHub id and its own members', async () => {
      const r = await rig({ memberships: { 'acme-new': { body: orgMembership({ id: ORG_ID, login: 'acme-new' }, 'admin', 'active', DAVE) } } });
      await r.namespaces.createOrgNamespace(
        { namespace: 'acme-old', kind: 'org', github_id: ORG_ID, created_at: 'x', created_by: 1 },
        { namespace: 'acme-old', github_id: 1, role: 'owner', added_by: 1, added_at: 'x' },
      );
      const s = await r.reg.start(DAVE, 'acme-new');
      expect((await r.reg.poll(DAVE, s.device_code)).status).toBe('created');
      expect((await r.namespaces.listNamespaces(ORG_ID)).map((n) => n.namespace)).toEqual(['acme-new', 'acme-old']);
      expect((await r.namespaces.listMembers('acme-old')).map((m) => m.github_id)).toEqual([1]);
      expect((await r.namespaces.listMembers('acme-new')).map((m) => m.github_id)).toEqual([DAVE]);
    });
  });

  describe('poll: refused as not_org_admin, and nothing is stored', () => {
    const message = "You are not an active admin of the GitHub organization 'acme-labs'.";
    const answers: Array<[string, Parameters<typeof fakeGitHub>[0]]> = [
      ['a plain member of the organization', { memberships: { 'acme-labs': { body: orgMembership({ id: ORG_ID, login: 'acme-labs' }, 'member', 'active', DAVE) } } }],
      ['an admin whose membership is still pending', { memberships: { 'acme-labs': { body: orgMembership({ id: ORG_ID, login: 'acme-labs' }, 'admin', 'pending', DAVE) } } }],
      ['a billing manager', { memberships: { 'acme-labs': { body: orgMembership({ id: ORG_ID, login: 'acme-labs' }, 'billing_manager', 'active', DAVE) } } }],
      ['an account that is not in the organization (404)', { memberships: {} }],
      ['an organization that restricts OAuth apps (403)', { memberships: { 'acme-labs': { status: 403, body: { message: 'Forbidden' } } } }],
      ['an organization whose current login is another', { memberships: { 'acme-labs': { body: orgMembership({ id: ORG_ID, login: 'acme-renamed' }, 'admin', 'active', DAVE) } } }],
    ];
    test.each(answers)('%s', async (_why, gh) => {
      const r = await rig(gh);
      const s = await r.reg.start(DAVE, 'acme-labs');
      expect(await refusal(r.reg.poll(DAVE, s.device_code))).toEqual({ code: 'not_org_admin', status: 403, message, detail: { namespace: 'acme-labs' } });
      expect(await r.namespaces.getNamespace('acme-labs')).toBeUndefined();
      expect(await r.namespaces.listMemberships(DAVE)).toEqual([]);
      // The flow is over at GitHub: the same code is not used again.
      expect((await refusal(r.reg.poll(DAVE, s.device_code))).code).toBe('device_code_unknown');
      expect(r.dump()).not.toContain(TOKEN);
    });

    test('another GitHub account approved: github_account_mismatch, and the organization is not asked about', async () => {
      const r = await rig({ user: { id: 9999, login: 'mallory', two_factor_authentication: true } });
      const s = await r.reg.start(DAVE, 'acme-labs');
      expect(await refusal(r.reg.poll(DAVE, s.device_code))).toEqual({
        code: 'github_account_mismatch',
        status: 403,
        message: 'The GitHub account that approved is not the one logged in to mopm.',
        detail: { namespace: 'acme-labs' },
      });
      expect(r.orgCalls()).toEqual([]);
      expect(await r.namespaces.getNamespace('acme-labs')).toBeUndefined();
    });

    test('the namespace taken while the person approved is namespace_taken, and the holder is untouched', async () => {
      const r = await rig();
      const s = await r.reg.start(DAVE, 'acme-labs');
      await r.namespaces.createOrgNamespace(
        { namespace: 'acme-labs', kind: 'org', github_id: ORG_ID, created_at: 'x', created_by: 1 },
        { namespace: 'acme-labs', github_id: 1, role: 'owner', added_by: 1, added_at: 'x' },
      );
      expect((await refusal(r.reg.poll(DAVE, s.device_code))).code).toBe('namespace_taken');
      expect((await r.namespaces.listMembers('acme-labs')).map((m) => m.github_id)).toEqual([1]);
    });
  });

  describe('what is not GitHub failing is not swallowed', () => {
    test('an unexpected error of the GitHub client at start and at the poll passes through unchanged', async () => {
      const r = await rig();
      const http = new HttpGitHubApi('Iv1.testclientid', r.fake.fetchFn);
      const bug = (name: 'startDeviceFlow' | 'getUser') => ({ ...http, startDeviceFlow: http.startDeviceFlow.bind(http), pollDeviceFlow: http.pollDeviceFlow.bind(http), getUser: http.getUser.bind(http), getOrgMembership: http.getOrgMembership.bind(http), [name]: async () => { throw new TypeError('a bug'); } }); // prettier-ignore
      const atStart = new OrgRegistration({ store: r.store, namespaces: r.namespaces, github: bug('startDeviceFlow') });
      await expect(atStart.start(DAVE, 'acme-labs')).rejects.toThrow('a bug');
      const s = await r.reg.start(DAVE, 'acme-labs');
      const atPoll = new OrgRegistration({ store: r.store, namespaces: r.namespaces, github: bug('getUser'), now: r.clock.now });
      await expect(atPoll.poll(DAVE, s.device_code)).rejects.toThrow('a bug');
    });

    test('an unusable answer to the start of the device flow is unavailable', async () => {
      const fake = fakeGitHub();
      const github = new HttpGitHubApi('Iv1.testclientid', async (url, init) => (url.endsWith('/login/device/code') ? { ok: true, status: 200, json: async () => ({ device_code: 'x' }) } : fake.fetchFn(url, init)));
      const reg = new OrgRegistration({ store: new MemoryAuthStore(), namespaces: await withDave(new MemoryNamespaceStore()), github });
      expect((await refusal(reg.start(DAVE, 'acme-labs'))).code).toBe('unavailable');
    });

    test('without an injected clock the system time dates the namespace', async () => {
      const store = new MemoryAuthStore();
      const namespaces = await withDave(new MemoryNamespaceStore());
      const fake = fakeGitHub({
        user: { id: DAVE, login: 'dave', two_factor_authentication: true },
        memberships: { 'acme-labs': { body: orgMembership({ id: ORG_ID, login: 'acme-labs' }, 'admin', 'active', DAVE) } },
      });
      const reg = new OrgRegistration({ store, namespaces, github: new HttpGitHubApi('Iv1.testclientid', fake.fetchFn) });
      const s = await reg.start(DAVE, 'acme-labs');
      await reg.poll(DAVE, s.device_code);
      expect(Date.parse((await namespaces.getNamespace('acme-labs'))!.created_at)).not.toBeNaN();
    });
  });

  describe('poll: the flow', () => {
    test('pending while the person has not decided; polling faster than the interval is answered without GitHub and slows the client', async () => {
      const r = await rig({ pollScript: [{ error: 'authorization_pending' }] });
      const s = await r.reg.start(DAVE, 'acme-labs');
      expect(await r.reg.poll(DAVE, s.device_code)).toEqual({ status: 'pending', interval: 5 });
      const polls = () => r.fake.state.calls.filter((c) => c.url.endsWith('/access_token')).length;
      expect(polls()).toBe(1);
      r.clock.advance(1000);
      expect(await r.reg.poll(DAVE, s.device_code)).toEqual({ status: 'pending', interval: 10 });
      expect(polls()).toBe(1);
    });

    test('GitHub asking to slow down raises the interval to what it says, or by five seconds when it says none', async () => {
      const said = await rig({ pollScript: [{ error: 'slow_down', interval: 20 }] });
      const a = await said.reg.start(DAVE, 'acme-labs');
      expect(await said.reg.poll(DAVE, a.device_code)).toEqual({ status: 'pending', interval: 20 });
      const silent = await rig({ pollScript: [{ error: 'slow_down' }] });
      const b = await silent.reg.start(DAVE, 'acme-labs');
      expect(await silent.reg.poll(DAVE, b.device_code)).toEqual({ status: 'pending', interval: 10 });
    });

    test('denied on GitHub is denied, and the row is gone; expired after ten minutes is expired', async () => {
      const r = await rig({ pollScript: [{ error: 'access_denied' }] });
      const a = await r.reg.start(DAVE, 'acme-labs');
      expect(await r.reg.poll(DAVE, a.device_code)).toEqual({ status: 'denied' });
      expect((await refusal(r.reg.poll(DAVE, a.device_code))).code).toBe('device_code_unknown');
      const b = await r.reg.start(DAVE, 'acme-labs');
      r.clock.advance(11 * 60_000);
      expect(await r.reg.poll(DAVE, b.device_code)).toEqual({ status: 'expired' });
    });

    test('GitHub failing is unavailable at start, at the poll, and when the organization is read', async () => {
      const startDown = new OrgRegistration({
        store: new MemoryAuthStore(),
        namespaces: await withDave(new MemoryNamespaceStore()),
        github: new HttpGitHubApi('Iv1.testclientid', async () => ({ ok: false, status: 502, json: async () => ({}) })),
      });
      expect((await refusal(startDown.start(DAVE, 'acme-labs'))).code).toBe('unavailable');

      const down = await rig({ pollScript: [{ error: 'incorrect_device_code' }] });
      const s = await down.reg.start(DAVE, 'acme-labs');
      expect((await refusal(down.reg.poll(DAVE, s.device_code))).code).toBe('unavailable');

      const userDown = await rig({ userStatus: 502 });
      const u = await userDown.reg.start(DAVE, 'acme-labs');
      expect((await refusal(userDown.reg.poll(DAVE, u.device_code))).code).toBe('unavailable');

      const orgDown = await rig({ memberships: { 'acme-labs': { status: 500, body: {} } } });
      const o = await orgDown.reg.start(DAVE, 'acme-labs');
      expect((await refusal(orgDown.reg.poll(DAVE, o.device_code))).code).toBe('unavailable');
      expect(await orgDown.namespaces.getNamespace('acme-labs')).toBeUndefined();
    });

    test('only the account that started the flow may poll it; a code of a login is not a registration, and a registration code is not a login', async () => {
      const r = await rig();
      const s = await r.reg.start(DAVE, 'acme-labs');
      expect((await refusal(r.reg.poll(5, s.device_code))).code).toBe('device_code_unknown');
      expect((await refusal(r.reg.poll(DAVE, 'dev_' + '0'.repeat(48)))).code).toBe('device_code_unknown');
      expect((await refusal(r.reg.poll(DAVE, 'short'))).code).toBe('device_code_unknown');
      const l = await r.login.start({ client: 'mopm' });
      expect((await refusal(r.reg.poll(DAVE, l.device_code))).code).toBe('device_code_unknown');
      expect((await refusal(r.login.poll({ device_code: s.device_code }))).code).toBe('device_code_unknown');
      // Neither mistaken poll used the flow up.
      expect((await r.reg.poll(DAVE, s.device_code)).status).toBe('created');
    });
  });
});
