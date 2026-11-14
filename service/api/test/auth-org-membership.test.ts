import {
  authTablesFor,
  AuthError,
  DynamoMembershipPassStore,
  DynamoNamespaceStore,
  HttpGitHubAppApi,
  MEMBERSHIP_PASS_MS,
  MemoryMembershipPassStore,
  MemoryNamespaceStore,
  NamespaceError,
  OrgMembership,
  type GitHubAppApi,
  type MembershipPassStore,
  type NamespaceRecord,
  type NamespaceStore,
} from '../src/auth';
import { FakeAuthDoc, LAMBDA_GRANTS } from './auth-fake-doc';
import { TestClock } from './auth-helpers';
import { APP_ID, APP_PRIVATE_KEY, fakeGitHubApp } from './github-app-fake';

// The organization membership check of docs/design/namespaces.md 2.2, end to end through the HTTP App client against a
// fake GitHub (test/github-app-fake.ts), with the pass store on the memory adapter unless a test says otherwise.

const ORG_ID = 77;
const INST = 5555;
const ALICE = 4242;
const NS: NamespaceRecord = { namespace: 'komira-ai', kind: 'org', github_id: ORG_ID, created_at: '2026-10-01T00:00:00.000Z', installation_id: INST };

function rig(passes: MembershipPassStore = new MemoryMembershipPassStore()) {
  const clock = new TestClock();
  const gh = fakeGitHubApp(clock.now);
  gh.install(INST, { id: ORG_ID, login: 'komira-ai' }).user(ALICE, 'alice');
  const app = new HttpGitHubAppApi({ appId: APP_ID, privateKey: APP_PRIVATE_KEY }, clock.now, gh.fetchFn);
  const om = new OrgMembership({ app, passes, now: clock.now });
  return { clock, gh, app, om, passes };
}

/** What a refusal carries: its code, status, message and detail, compared whole. */
async function refusal(p: Promise<unknown>) {
  try {
    await p;
  } catch (e) {
    const err = e as NamespaceError | AuthError;
    return { name: err.name, code: err.code, status: err.status, message: err.message, detail: err.detail };
  }
  throw new Error('expected a refusal');
}
const notMember = { name: 'NamespaceError', code: 'not_namespace_member', status: 403, message: "You cannot write in 'komira-ai'.", detail: { namespace: 'komira-ai' } };
const unverified = (detail: string) => ({
  name: 'NamespaceError',
  code: 'namespace_unverified',
  status: 403,
  message: `'komira-ai' cannot be verified on GitHub: ${detail}.`,
  detail: { namespace: 'komira-ai', detail },
});
const unavailable = (why: string) => ({
  name: 'AuthError',
  code: 'unavailable',
  status: 503,
  message: `GitHub could not be asked about 'komira-ai': ${why}.`,
  detail: { namespace: 'komira-ai', service: 'GitHub' },
});

describe('the membership check: who passes', () => {
  test.each(['admin', 'member'])('an active %s passes, from ids to current logins', async (role) => {
    const { gh, om } = rig();
    gh.member('komira-ai', 'alice', ALICE, role);
    expect(await om.check(NS, ALICE)).toBe(role);
    expect(gh.reads()).toEqual(['GET /app/installations/5555', 'GET /user/4242', 'GET /orgs/komira-ai/memberships/alice']);
  });

  test.each([
    ['pending, as a member', 'member', 'pending'],
    ['pending, as an admin', 'admin', 'pending'],
    ['a billing manager', 'billing_manager', 'active'],
  ])('%s is refused, naming the namespace', async (_label, role, st) => {
    const { gh, om } = rig();
    gh.member('komira-ai', 'alice', ALICE, role, st);
    expect(await refusal(om.check(NS, ALICE))).toEqual(notMember);
  });

  test('an outside collaborator (GitHub answers 404 for the membership) is refused', async () => {
    const { om } = rig();
    expect(await refusal(om.check(NS, ALICE))).toEqual(notMember);
  });

  test('a login reused by another account is refused: the membership is of another user.id', async () => {
    const { gh, om } = rig();
    // Alice renamed herself to alice2 on GitHub; a stranger (id 9) took "alice" and is a member. A session of the stranger
    // never passes as Alice, and Alice's own check goes from her id to her current login.
    gh.user(ALICE, 'alice2').user(9, 'alice').member('komira-ai', 'alice', 9);
    expect(await refusal(om.check(NS, ALICE))).toEqual(notMember);
    expect(gh.reads()).toContain('GET /orgs/komira-ai/memberships/alice2');
  });

  test('a membership GitHub shows for another id under the caller\'s current login is refused', async () => {
    const { gh, om } = rig();
    gh.member('komira-ai', 'alice', 9);
    expect(await refusal(om.check(NS, ALICE))).toEqual(notMember);
  });

  test('an organization renamed on GitHub keeps writing: the installation gives its current login', async () => {
    const { gh, om } = rig();
    gh.install(INST, { id: ORG_ID, login: 'komira-labs' }).member('komira-labs', 'alice', ALICE);
    expect(await om.check(NS, ALICE)).toBe('member');
    expect(gh.reads()).toContain('GET /orgs/komira-labs/memberships/alice');
  });

  test('a member renamed on GitHub keeps writing: the account id gives the current login', async () => {
    const { gh, om } = rig();
    gh.user(ALICE, 'alice-renamed').member('komira-ai', 'alice-renamed', ALICE);
    expect(await om.check(NS, ALICE)).toBe('member');
  });

  test('an account GitHub no longer has (404 for the user) is refused', async () => {
    const { gh, om } = rig();
    gh.state.users.delete(ALICE);
    expect(await refusal(om.check(NS, ALICE))).toEqual(notMember);
  });

  test('admin required: an active member is refused, an active admin passes', async () => {
    const { gh, om } = rig();
    gh.member('komira-ai', 'alice', ALICE, 'member');
    expect(await refusal(om.check(NS, ALICE, { require: 'admin' }))).toEqual(notMember);
    gh.member('komira-ai', 'alice', ALICE, 'admin');
    expect(await om.check(NS, ALICE, { require: 'admin' })).toBe('admin');
  });
});

describe('the membership check: a pass kept 5 minutes, a refusal never', () => {
  test('a pass is reused for 5 minutes with no GitHub call; a removal takes effect when it ends', async () => {
    const { gh, om, clock } = rig();
    gh.member('komira-ai', 'alice', ALICE);
    expect(await om.check(NS, ALICE)).toBe('member');
    gh.removeMember('komira-ai', 'alice');
    gh.state.calls.length = 0;
    clock.advance(MEMBERSHIP_PASS_MS - 1);
    expect(await om.check(NS, ALICE)).toBe('member');
    expect(gh.state.calls).toEqual([]);
    clock.advance(1);
    expect(await refusal(om.check(NS, ALICE))).toEqual(notMember);
  });

  test('a refusal is not kept: a new member passes at once', async () => {
    const { gh, om } = rig();
    expect(await refusal(om.check(NS, ALICE))).toEqual(notMember);
    gh.member('komira-ai', 'alice', ALICE);
    expect(await om.check(NS, ALICE)).toBe('member');
  });

  test('a pass is per (organization id, account id): another account or another organization asks GitHub', async () => {
    const { gh, om } = rig();
    gh.user(5, 'bob').member('komira-ai', 'alice', ALICE).member('komira-ai', 'bob', 5);
    gh.install(6666, { id: 88, login: 'other-org' }).member('other-org', 'alice', ALICE);
    await om.check(NS, ALICE);
    gh.state.calls.length = 0;
    expect(await om.check(NS, 5)).toBe('member');
    expect(await om.check({ ...NS, namespace: 'other-org', github_id: 88, installation_id: 6666 }, ALICE)).toBe('member');
    expect(gh.reads()).toEqual([
      'GET /app/installations/5555',
      'GET /user/5',
      'GET /orgs/komira-ai/memberships/bob',
      'GET /app/installations/6666',
      'GET /user/4242',
      'GET /orgs/other-org/memberships/alice',
    ]);
  });

  test('a kept member pass does not satisfy an admin check: GitHub is asked', async () => {
    const { gh, om } = rig();
    gh.member('komira-ai', 'alice', ALICE, 'member');
    await om.check(NS, ALICE);
    expect(await refusal(om.check(NS, ALICE, { require: 'admin' }))).toEqual(notMember);
  });

  test('a kept admin pass satisfies an admin check that reuses passes', async () => {
    const { gh, om } = rig();
    gh.member('komira-ai', 'alice', ALICE, 'admin');
    await om.check(NS, ALICE);
    gh.removeMember('komira-ai', 'alice');
    expect(await om.check(NS, ALICE, { require: 'admin' })).toBe('admin');
  });

  test('reuse: false always asks GitHub, and its pass is kept', async () => {
    const { gh, om } = rig();
    gh.member('komira-ai', 'alice', ALICE);
    await om.check(NS, ALICE);
    gh.removeMember('komira-ai', 'alice');
    expect(await refusal(om.check(NS, ALICE, { reuse: false }))).toEqual(notMember);
  });

  test('the pass is kept as role and expiry, 5 minutes from the check', async () => {
    const passes = new MemoryMembershipPassStore();
    const { gh, om } = rig(passes);
    gh.member('komira-ai', 'alice', ALICE, 'admin');
    await om.check(NS, ALICE);
    expect(await passes.getPass(ORG_ID, ALICE)).toEqual({ role: 'admin', expires_at: '2026-10-14T12:05:00.000Z' });
    expect(await passes.getPass(ORG_ID, 5)).toBeUndefined();
  });
});

describe('the membership check: a namespace that cannot be verified is frozen', () => {
  test('the App uninstalled (404 for the installation): every write is refused, the pass too once it ends', async () => {
    const { gh, om, clock } = rig();
    gh.member('komira-ai', 'alice', ALICE);
    expect(await om.check(NS, ALICE)).toBe('member');
    gh.state.installations.delete(INST);
    clock.advance(MEMBERSHIP_PASS_MS);
    gh.state.calls.length = 0;
    expect(await refusal(om.check(NS, ALICE))).toEqual(unverified('the mopm registry GitHub App is not installed on the organization'));
    expect(await refusal(om.check(NS, ALICE))).toEqual(unverified('the mopm registry GitHub App is not installed on the organization'));
    expect(gh.reads()).toEqual(['GET /app/installations/5555', 'GET /app/installations/5555']);
  });

  test('the installation is on another account (the organization deleted, its installation id reused)', async () => {
    const { gh, om } = rig();
    gh.install(INST, { id: 99, login: 'komira-ai' }).member('komira-ai', 'alice', ALICE);
    expect(await refusal(om.check(NS, ALICE))).toEqual(unverified('the GitHub App installation belongs to another GitHub account'));
  });

  test('the installation is suspended by an owner', async () => {
    const { gh, om } = rig();
    gh.member('komira-ai', 'alice', ALICE);
    gh.state.installations.get(INST)!.suspended = true;
    expect(await refusal(om.check(NS, ALICE))).toEqual(unverified('the mopm registry GitHub App is suspended on the organization'));
  });

  test('an organization namespace with no bound installation, and a user namespace, are refused without asking GitHub', async () => {
    const { gh, om } = rig();
    const { installation_id: _i, ...bare } = NS;
    expect(await refusal(om.check(bare, ALICE))).toEqual(unverified('the mopm registry GitHub App is not installed on the organization'));
    expect(await refusal(om.check({ ...NS, kind: 'user' }, ALICE))).toEqual(unverified('it is not an organization namespace'));
    expect(gh.state.calls).toEqual([]);
  });
});

describe('the membership check: GitHub down is unavailable, never a stale pass', () => {
  test.each([
    ['a 500', { path: /^\/orgs\//, status: 500 }, 'GitHub answered 500 for the organization membership'],
    ['rate limited (429)', { path: /^\/user\//, status: 429 }, 'GitHub answered 429 for the user lookup'],
    ['rate limited (403)', { path: /^\/app\/installations\/\d+$/, status: 403 }, 'GitHub answered 403 for the installation'],
    ['unreachable', { path: /./, reject: true }, 'GitHub could not be read for the installation: TypeError'],
    ['a body that is not JSON', { path: /^\/orgs\//, badJson: true }, 'GitHub could not be read for the organization membership: SyntaxError'],
    ['the token refused', { path: /access_tokens$/, status: 401 }, 'GitHub answered 401 for the installation token'],
  ])('%s', async (_label, fault, why) => {
    const { gh, om } = rig();
    gh.member('komira-ai', 'alice', ALICE);
    gh.state.faults.push(fault);
    expect(await refusal(om.check(NS, ALICE))).toEqual(unavailable(why));
  });

  test('a pass that ended is not used when GitHub is down: unavailable', async () => {
    const { gh, om, clock } = rig();
    gh.member('komira-ai', 'alice', ALICE);
    await om.check(NS, ALICE);
    clock.advance(MEMBERSHIP_PASS_MS);
    gh.state.faults.push({ path: /./, reject: true });
    expect(await refusal(om.check(NS, ALICE))).toEqual(unavailable('GitHub could not be read for the installation: TypeError'));
  });

  test.each([
    ['an unknown state', 'member', 'invited', "GitHub answered a membership of state 'invited' and role 'member'"],
    ['an unknown role', 'owner', 'active', "GitHub answered a membership of state 'active' and role 'owner'"],
  ])('a membership of %s is unavailable, not a pass and not a refusal', async (_label, role, st, why) => {
    const { gh, om } = rig();
    gh.member('komira-ai', 'alice', ALICE, role, st);
    expect(await refusal(om.check(NS, ALICE))).toEqual(unavailable(why));
  });

  test('a user lookup that answers another id is unavailable', async () => {
    const { gh, om } = rig();
    gh.state.faults.push({ path: /^\/user\//, body: { id: 9, login: 'alice' } });
    expect(await refusal(om.check(NS, ALICE))).toEqual(unavailable('GitHub answered another user for the account id'));
  });

  test('an error that is not GitHub being unavailable is not turned into unavailable', async () => {
    const app: GitHubAppApi = {
      getInstallation: async () => {
        throw new RangeError('a defect');
      },
      getOrgInstallation: async () => undefined,
      getUserById: async () => undefined,
      getOrgMembership: async () => undefined,
    };
    const om = new OrgMembership({ app, passes: new MemoryMembershipPassStore(), now: () => new Date() });
    await expect(om.check(NS, ALICE)).rejects.toThrow(RangeError);
  });

  test('a pass store failure fails the check', async () => {
    const { om } = rig({
      getPass: async () => {
        throw new Error('store down');
      },
      putPass: async () => undefined,
    });
    await expect(om.check(NS, ALICE)).rejects.toThrow('store down');
  });
});

describe.each<[string, () => MembershipPassStore]>([
  ['memory', () => new MemoryMembershipPassStore()],
  ['dynamodb (strict fake, Lambda grants)', () => new DynamoMembershipPassStore(new FakeAuthDoc({ grants: LAMBDA_GRANTS }), authTablesFor('t').membership_passes)],
])('MembershipPassStore contract: %s', (_label, make) => {
  test('absent, then the pass put, then replaced by the next one of the pair; pairs are apart', async () => {
    const s = make();
    expect(await s.getPass(77, 4242)).toBeUndefined();
    await s.putPass(77, 4242, { role: 'member', expires_at: '2026-10-14T12:05:00.000Z' });
    await s.putPass(77, 5, { role: 'admin', expires_at: '2026-10-14T12:06:00.000Z' });
    expect(await s.getPass(77, 4242)).toEqual({ role: 'member', expires_at: '2026-10-14T12:05:00.000Z' });
    await s.putPass(77, 4242, { role: 'admin', expires_at: '2026-10-14T12:09:00.123Z' });
    expect(await s.getPass(77, 4242)).toEqual({ role: 'admin', expires_at: '2026-10-14T12:09:00.123Z' });
    expect(await s.getPass(77, 5)).toEqual({ role: 'admin', expires_at: '2026-10-14T12:06:00.000Z' });
    expect(await s.getPass(4242, 77)).toBeUndefined();
  });
});

test('the DynamoDB pass row: key, role, TTL in epoch seconds and the exact time beside it', async () => {
  const doc = new FakeAuthDoc({ grants: LAMBDA_GRANTS });
  await new DynamoMembershipPassStore(doc, 'mopm-t-membership_passes').putPass(77, 4242, { role: 'member', expires_at: '2026-10-14T12:05:00.500Z' });
  expect(doc.dump('membership_passes')).toEqual([{ key: '77:4242', role: 'member', expires_at: 1791979500, expires_at_iso: '2026-10-14T12:05:00.500Z' }]);
});

describe('bindOrgNamespace: the creation of an organization namespace by an admin', () => {
  const setup = (store: NamespaceStore = new MemoryNamespaceStore()) => ({ ...rig(), store });

  test('an active admin creates it, bound to the installation and its account id', async () => {
    const { gh, om, store, passes } = setup();
    gh.member('komira-ai', 'alice', ALICE, 'admin');
    expect(await om.bindOrgNamespace(store, 'komira-ai', ALICE)).toEqual({ status: 'created', record: { ...NS, created_at: '2026-10-14T12:00:00.000Z' } });
    expect(await store.getNamespace('komira-ai')).toEqual({ ...NS, created_at: '2026-10-14T12:00:00.000Z' });
    expect(gh.reads()).toEqual(['GET /orgs/komira-ai/installation', 'GET /user/4242', 'GET /orgs/komira-ai/memberships/alice']);
    expect(await passes.getPass(ORG_ID, ALICE)).toEqual({ role: 'admin', expires_at: '2026-10-14T12:05:00.000Z' });
  });

  test('on the DynamoDB store under the Lambda grants', async () => {
    const { gh, om, store } = setup(new DynamoNamespaceStore(new FakeAuthDoc({ grants: LAMBDA_GRANTS }), authTablesFor('t').namespaces));
    gh.member('komira-ai', 'alice', ALICE, 'admin');
    expect((await om.bindOrgNamespace(store, 'komira-ai', ALICE)).status).toBe('created');
    gh.install(6666, { id: ORG_ID, login: 'komira-ai' });
    gh.state.installations.delete(INST);
    expect(await om.bindOrgNamespace(store, 'komira-ai', ALICE)).toEqual({ status: 'rebound', record: { ...NS, created_at: '2026-10-14T12:00:00.000Z', installation_id: 6666 } });
  });

  test('a member who is not an admin is refused, and nothing is created; a kept member pass does not count', async () => {
    const { gh, om, store } = setup();
    gh.member('komira-ai', 'alice', ALICE, 'member');
    expect(await refusal(om.bindOrgNamespace(store, 'komira-ai', ALICE))).toEqual(notMember);
    expect(await store.getNamespace('komira-ai')).toBeUndefined();
  });

  test('an admin pass kept from earlier is not reused: GitHub is asked', async () => {
    const { gh, om, store } = setup();
    gh.member('komira-ai', 'alice', ALICE, 'admin');
    await om.check(NS, ALICE);
    gh.removeMember('komira-ai', 'alice');
    expect(await refusal(om.bindOrgNamespace(store, 'komira-ai', ALICE))).toEqual(notMember);
  });

  test.each([
    ['Komira-AI', 'invalid_namespace', 400, "'Komira-AI' is not a valid namespace."],
    ['a_b', 'invalid_namespace', 400, "'a_b' is not a valid namespace."],
    ['linux-64', 'namespace_reserved', 403, "'linux-64' is reserved."],
    ['index', 'namespace_reserved', 403, "'index' is reserved."],
  ])('%s is refused (%s) before GitHub or the store is asked', async (ns, code, status, message) => {
    const { gh, om, store } = setup();
    expect(await refusal(om.bindOrgNamespace(store, ns, ALICE))).toEqual({ name: 'NamespaceError', code, status, message, detail: { namespace: ns } });
    expect(gh.state.calls).toEqual([]);
  });

  test('no installation of the App on that login: unverified', async () => {
    const { gh, om, store } = setup();
    gh.state.installations.delete(INST);
    expect(await refusal(om.bindOrgNamespace(store, 'komira-ai', ALICE))).toEqual(unverified('the mopm registry GitHub App is not installed on the organization'));
  });

  test('a suspended installation: unverified, and nothing is created', async () => {
    const { gh, om, store } = setup();
    gh.member('komira-ai', 'alice', ALICE, 'admin');
    gh.state.installations.get(INST)!.suspended = true;
    expect(await refusal(om.bindOrgNamespace(store, 'komira-ai', ALICE))).toEqual(unverified('the mopm registry GitHub App is suspended on the organization'));
    expect(await store.getNamespace('komira-ai')).toBeUndefined();
  });

  test('a user namespace of that string is refused without asking GitHub', async () => {
    const { gh, om, store } = setup();
    await store.createNamespace({ namespace: 'komira-ai', kind: 'user', github_id: 3, created_at: NS.created_at });
    expect(await refusal(om.bindOrgNamespace(store, 'komira-ai', ALICE))).toEqual(unverified('it is not an organization namespace'));
    expect(gh.state.calls).toEqual([]);
  });

  test('frozen, then unfrozen: the App installed again on the same organization binds the new installation', async () => {
    const { gh, om, store, clock } = setup();
    gh.member('komira-ai', 'alice', ALICE, 'admin');
    await om.bindOrgNamespace(store, 'komira-ai', ALICE);
    gh.state.installations.delete(INST);
    clock.advance(MEMBERSHIP_PASS_MS);
    const frozen = (await store.getNamespace('komira-ai'))!;
    expect(await refusal(om.check(frozen, ALICE))).toEqual(unverified('the mopm registry GitHub App is not installed on the organization'));
    gh.install(6666, { id: ORG_ID, login: 'komira-ai' });
    const r = await om.bindOrgNamespace(store, 'komira-ai', ALICE);
    expect(r).toEqual({ status: 'rebound', record: { ...NS, created_at: '2026-10-14T12:00:00.000Z', installation_id: 6666 } });
    clock.advance(MEMBERSHIP_PASS_MS);
    expect(await om.check((await store.getNamespace('komira-ai'))!, ALICE)).toBe('admin');
  });

  test('an organization that took the old name (another id) is refused, and the namespace stays bound', async () => {
    const { gh, om, store } = setup();
    await store.createNamespace(NS);
    gh.state.installations.delete(INST);
    gh.install(7777, { id: 99, login: 'komira-ai' }).member('komira-ai', 'alice', ALICE, 'admin');
    expect(await refusal(om.bindOrgNamespace(store, 'komira-ai', ALICE))).toEqual(unverified('it is bound to another GitHub account'));
    expect(await store.getNamespace('komira-ai')).toEqual(NS);
  });

  test('the same installation already bound: held, nothing written', async () => {
    const { gh, om, store } = setup();
    await store.createNamespace(NS);
    gh.member('komira-ai', 'alice', ALICE, 'admin');
    expect(await om.bindOrgNamespace(store, 'komira-ai', ALICE)).toEqual({ status: 'held', record: NS });
  });

  test('GitHub down while creating: unavailable, nothing created', async () => {
    const { gh, om, store } = setup();
    gh.state.faults.push({ path: /installation$/, status: 502 });
    expect(await refusal(om.bindOrgNamespace(store, 'komira-ai', ALICE))).toEqual(unavailable('GitHub answered 502 for the installation'));
    expect(await store.getNamespace('komira-ai')).toBeUndefined();
  });

  // A create that loses a race with another create of the same string: the winner's row decides.
  const racing = (winner: NamespaceRecord, bound?: NamespaceRecord): NamespaceStore => ({
    getNamespace: async () => undefined,
    createNamespace: async () => ({ created: false, record: winner }),
    listNamespaces: async () => [],
    bindInstallation: async () => bound,
  });

  test.each([
    ['the same organization, same installation: held', NS, { status: 'held', record: NS }],
    ['the same organization, an older installation: rebound', { ...NS, installation_id: 1 }, { status: 'rebound', record: NS }],
  ])('a lost race to %s', async (_label, winner, want) => {
    const { gh, om } = setup();
    gh.member('komira-ai', 'alice', ALICE, 'admin');
    expect(await om.bindOrgNamespace(racing(winner, NS), 'komira-ai', ALICE)).toEqual(want);
  });

  test.each([
    ['another organization', { ...NS, github_id: 99 }, 'it is bound to another GitHub account'],
    ['a user', { ...NS, kind: 'user' as const, installation_id: undefined }, 'it is not an organization namespace'],
  ])('a lost race to %s is refused', async (_label, winner, detail) => {
    const { gh, om } = setup();
    gh.member('komira-ai', 'alice', ALICE, 'admin');
    expect(await refusal(om.bindOrgNamespace(racing(winner), 'komira-ai', ALICE))).toEqual(unverified(detail));
  });

  test('a store that cannot bind its own row is a defect, raised', async () => {
    const { gh, om } = setup();
    gh.member('komira-ai', 'alice', ALICE, 'admin');
    await expect(om.bindOrgNamespace(racing({ ...NS, installation_id: 1 }), 'komira-ai', ALICE)).rejects.toThrow(
      'namespace komira-ai: the installation could not be bound to its own row',
    );
  });
});
