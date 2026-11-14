import {
  AuthError,
  DynamoAuthStore,
  DynamoNamespaceStore,
  MemoryAuthStore,
  MemoryNamespaceStore,
  NamespaceAccess,
  NamespaceError,
  OrgMembers,
  authTablesFor,
  type AuthStore,
  type NamespaceStore,
} from '../src/auth';
import { FakeAuthDoc, LAMBDA_GRANTS } from './auth-fake-doc';
import { TestClock } from './auth-helpers';

// The members of an organization namespace (src/auth/org-members.ts), by mopm username, over the memory adapters and the
// DynamoDB adapters on the strict fake under the Lambda grants. Only the member table is read or written.

const ALICE = 1001; // owner of komira-ai, user namespace `alice` (handle Alice)
const BOB = 1002; // user namespace `bob`, not a member
const CAROL = 2001; // member of komira-ai, user namespace `carol`
const ERIN = 2003; // owner of komira-ai through registration, no user namespace; handle Erin-X
const ORG = 77;

type Backing = 'memory' | 'dynamodb';

async function setup(backing: Backing) {
  const clock = new TestClock();
  let users: AuthStore;
  let namespaces: NamespaceStore;
  if (backing === 'memory') {
    users = new MemoryAuthStore();
    namespaces = new MemoryNamespaceStore();
  } else {
    const doc = new FakeAuthDoc({ pageSize: 2, grants: LAMBDA_GRANTS });
    const tables = authTablesFor('t');
    users = new DynamoAuthStore(doc, tables);
    namespaces = new DynamoNamespaceStore(doc, tables.namespaces, tables.namespace_members);
  }
  const at = clock.now().toISOString();
  for (const [id, handle] of [[ALICE, 'Alice'], [BOB, 'bob'], [CAROL, 'carol'], [ERIN, 'Erin-X']] as const) await users.upsertUser(id, handle, at, true);
  for (const [ns, id] of [['alice', ALICE], ['bob', BOB], ['carol', CAROL]] as const) await namespaces.createNamespace({ namespace: ns, kind: 'user', github_id: id, created_at: at });
  await namespaces.createOrgNamespace(
    { namespace: 'komira-ai', kind: 'org', github_id: ORG, created_at: at, created_by: ALICE },
    { namespace: 'komira-ai', github_id: ALICE, role: 'owner', added_by: ALICE, added_at: at },
  );
  await namespaces.setMember({ namespace: 'komira-ai', github_id: CAROL, role: 'member', added_by: ALICE, added_at: at });
  const access = new NamespaceAccess({ namespaces, users });
  const members = new OrgMembers({ namespaces, access, users, now: clock.now });
  return { clock, users, namespaces, access, members, at };
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

describe.each<Backing>(['memory', 'dynamodb'])('members of an organization namespace on %s', (backing) => {
  const rig = () => setup(backing);

  describe('list', () => {
    test('an owner and a member read the members, sorted by user, with the handle, GitHub id, role and the time of the add', async () => {
      const r = await rig();
      const want = {
        namespace: 'komira-ai',
        members: [
          { user: 'alice', handle: 'Alice', github_id: ALICE, role: 'owner', added_at: r.at },
          { user: 'carol', handle: 'carol', github_id: CAROL, role: 'member', added_at: r.at },
        ],
      };
      expect(await r.members.list(ALICE, 'komira-ai')).toEqual(want);
      expect(await r.members.list(CAROL, 'komira-ai')).toEqual(want);
    });

    test('a member whose account holds several user namespaces goes by the one equal to its handle, else the first', async () => {
      const r = await rig();
      await r.namespaces.createNamespace({ namespace: 'alice-old', kind: 'user', github_id: ALICE, created_at: r.at });
      await r.namespaces.createNamespace({ namespace: 'aaa-first', kind: 'user', github_id: CAROL, created_at: r.at });
      const list = (await r.members.list(ALICE, 'komira-ai')).members;
      // alice: handle Alice matches `alice`; carol: handle carol matches `carol`, though `aaa-first` sorts before it.
      expect(list.map((m) => m.user)).toEqual(['alice', 'carol']);
      await r.users.upsertUser(CAROL, 'Renamed', r.at, true);
      expect((await r.members.list(ALICE, 'komira-ai')).members.map((m) => [m.user, m.handle])).toEqual([['aaa-first', 'Renamed'], ['alice', 'Alice']]);
    });

    test('an account with no user namespace goes by its handle in lower case; one with no user row by its GitHub id', async () => {
      const r = await rig();
      await r.members.set(ALICE, 'komira-ai', 'bob', 'owner');
      await r.namespaces.setMember({ namespace: 'komira-ai', github_id: ERIN, role: 'member', added_by: ALICE, added_at: r.at });
      await r.namespaces.setMember({ namespace: 'komira-ai', github_id: 31337, role: 'member', added_by: ALICE, added_at: r.at });
      const list = (await r.members.list(ALICE, 'komira-ai')).members;
      expect(list.map((m) => [m.user, m.handle, m.github_id])).toEqual([
        ['31337', '31337', 31337],
        ['alice', 'Alice', ALICE],
        ['bob', 'bob', BOB],
        ['carol', 'carol', CAROL],
        ['erin-x', 'Erin-X', ERIN],
      ]);
    });

    test('two members that go by the same name are listed in GitHub id order', async () => {
      const r = await rig();
      // An account with no user namespace whose handle lower-cases to `alice`, the name ALICE's own namespace gives her.
      await r.users.upsertUser(500, 'ALICE', r.at, true);
      await r.namespaces.setMember({ namespace: 'komira-ai', github_id: 500, role: 'member', added_by: ALICE, added_at: r.at });
      expect((await r.members.list(ALICE, 'komira-ai')).members.map((m) => [m.user, m.github_id])).toEqual([['alice', 500], ['alice', ALICE], ['carol', CAROL]]);
    });

    test('an account that is not in the namespace is not_namespace_member; a removed member is too', async () => {
      const r = await rig();
      expect(await refusal(r.members.list(BOB, 'komira-ai'))).toMatchObject({ code: 'not_namespace_member', status: 403, detail: { namespace: 'komira-ai' } });
      await r.members.remove(ALICE, 'komira-ai', 'carol');
      expect((await refusal(r.members.list(CAROL, 'komira-ai'))).code).toBe('not_namespace_member');
    });

    test('a user namespace has no members: invalid_request naming it; a bad or unknown namespace is the namespace error', async () => {
      const r = await rig();
      expect(await refusal(r.members.list(ALICE, 'alice'))).toMatchObject({
        code: 'invalid_request',
        message: "The request is not valid: 'alice' is a user namespace; it has no members.",
        detail: { detail: "'alice' is a user namespace; it has no members" },
      });
      expect((await refusal(r.members.list(ALICE, 'Komira'))).code).toBe('invalid_namespace');
      expect((await refusal(r.members.list(ALICE, 'index'))).code).toBe('namespace_reserved');
      expect((await refusal(r.members.list(ALICE, 'nobody'))).code).toBe('namespace_not_found');
    });
  });

  describe('set', () => {
    test('an owner adds an account as a member: created, with the time of the add and who added it', async () => {
      const r = await rig();
      r.clock.advance(60_000);
      const out = await r.members.set(ALICE, 'komira-ai', 'bob', 'member');
      expect(out).toEqual({ created: true, member: { user: 'bob', handle: 'bob', github_id: BOB, role: 'member', added_at: r.clock.now().toISOString() } });
      expect(await r.namespaces.getMember('komira-ai', BOB)).toMatchObject({ role: 'member', added_by: ALICE });
    });

    test('the role of a member changes (not created, new time); the same role answers the row as it was and writes nothing', async () => {
      const r = await rig();
      r.clock.advance(60_000);
      const changed = await r.members.set(ALICE, 'komira-ai', 'carol', 'owner');
      expect(changed).toEqual({ created: false, member: { user: 'carol', handle: 'carol', github_id: CAROL, role: 'owner', added_at: r.clock.now().toISOString() } });
      r.clock.advance(60_000);
      const same = await r.members.set(ALICE, 'komira-ai', 'carol', 'owner');
      expect(same).toEqual(changed);
    });

    test('a role set that finds the account gone when it re-reads the row is member_not_found, not a crash', async () => {
      const r = await rig();
      const gone = Object.create(r.namespaces, { getMember: { value: async (ns: string, id: number) => (id === CAROL ? undefined : r.namespaces.getMember(ns, id)) } }) as NamespaceStore;
      const members = new OrgMembers({ namespaces: gone, access: r.access, users: r.users, now: r.clock.now });
      expect(await refusal(members.set(ALICE, 'komira-ai', 'carol', 'member'))).toEqual({
        code: 'member_not_found',
        status: 404,
        message: "'carol' is not a member of 'komira-ai'.",
        detail: { user: 'carol', namespace: 'komira-ai' },
      });
    });

    test('only an owner may set: a member is not_namespace_owner, a stranger not_namespace_member, and nothing is written', async () => {
      const r = await rig();
      expect(await refusal(r.members.set(CAROL, 'komira-ai', 'bob', 'member'))).toEqual({
        code: 'not_namespace_owner',
        status: 403,
        message: "You are not an owner of 'komira-ai'.",
        detail: { namespace: 'komira-ai' },
      });
      expect((await refusal(r.members.set(BOB, 'komira-ai', 'bob', 'member'))).code).toBe('not_namespace_member');
      expect(await r.namespaces.getMember('komira-ai', BOB)).toBeUndefined();
    });

    test('the last owner is not demoted: last_owner, and the row is unchanged; with a second owner the demotion passes', async () => {
      const r = await rig();
      expect(await refusal(r.members.set(ALICE, 'komira-ai', 'alice', 'member'))).toEqual({
        code: 'last_owner',
        status: 409,
        message: "'alice' is the last owner of 'komira-ai'.",
        detail: { user: 'alice', namespace: 'komira-ai' },
      });
      expect((await r.namespaces.getMember('komira-ai', ALICE))!.role).toBe('owner');
      await r.members.set(ALICE, 'komira-ai', 'carol', 'owner');
      expect((await r.members.set(ALICE, 'komira-ai', 'alice', 'member')).member.role).toBe('member');
    });

    test.each([
      ['an account with no user namespace', 'ghost'],
      ['an organization namespace', 'komira-ai'],
      ['a string outside the grammar', 'Bob'],
    ])('%s is user_not_found', async (_why, user) => {
      const r = await rig();
      expect(await refusal(r.members.set(ALICE, 'komira-ai', user, 'member'))).toEqual({
        code: 'user_not_found',
        status: 404,
        message: `There is no mopm user '${user}'.`,
        detail: { user },
      });
    });

    test.each([['admin'], [undefined], [7]])('a role of %p is invalid_request', async (role) => {
      const r = await rig();
      expect(await refusal(r.members.set(ALICE, 'komira-ai', 'bob', role))).toMatchObject({
        code: 'invalid_request',
        message: "The request is not valid: 'role' must be 'owner' or 'member'.",
      });
      expect(await r.namespaces.getMember('komira-ai', BOB)).toBeUndefined();
    });

    test('a user namespace has no members to set', async () => {
      const r = await rig();
      expect((await refusal(r.members.set(ALICE, 'alice', 'bob', 'member'))).code).toBe('invalid_request');
    });
  });

  describe('remove', () => {
    test('an owner removes a member; the removed account is refused by the very next write check, with no GitHub involved', async () => {
      const r = await rig();
      expect((await r.access.require('komira-ai', CAROL)).role).toBe('member');
      await r.members.remove(ALICE, 'komira-ai', 'carol');
      expect(await refusal(r.access.require('komira-ai', CAROL))).toMatchObject({ code: 'not_namespace_member', detail: { namespace: 'komira-ai' } });
      expect((await r.access.writable({ github_id: CAROL, handle: 'carol', created_at: r.at, last_login_at: r.at })).map((w) => w.record.namespace)).toEqual(['carol']);
    });

    test('a removed account can be added again, as a member or an owner', async () => {
      const r = await rig();
      await r.members.remove(ALICE, 'komira-ai', 'carol');
      expect((await r.members.set(ALICE, 'komira-ai', 'carol', 'owner')).created).toBe(true);
      expect((await r.access.require('komira-ai', CAROL)).role).toBe('owner');
    });

    test('an account that is not a member is member_not_found', async () => {
      const r = await rig();
      expect(await refusal(r.members.remove(ALICE, 'komira-ai', 'bob'))).toEqual({
        code: 'member_not_found',
        status: 404,
        message: "'bob' is not a member of 'komira-ai'.",
        detail: { user: 'bob', namespace: 'komira-ai' },
      });
      await r.members.remove(ALICE, 'komira-ai', 'carol');
      expect((await refusal(r.members.remove(ALICE, 'komira-ai', 'carol'))).code).toBe('member_not_found');
    });

    test('the only owner is not removed (last_owner); an owner may remove themselves while another owner remains', async () => {
      const r = await rig();
      expect((await refusal(r.members.remove(ALICE, 'komira-ai', 'alice'))).code).toBe('last_owner');
      expect((await r.namespaces.getMember('komira-ai', ALICE))!.role).toBe('owner');
      await r.members.set(ALICE, 'komira-ai', 'carol', 'owner');
      await r.members.remove(ALICE, 'komira-ai', 'alice');
      expect(await r.namespaces.getMember('komira-ai', ALICE)).toBeUndefined();
      expect((await r.namespaces.listMembers('komira-ai')).map((m) => m.github_id)).toEqual([CAROL]);
    });

    test('only an owner may remove: a member is not_namespace_owner, a stranger not_namespace_member', async () => {
      const r = await rig();
      expect((await refusal(r.members.remove(CAROL, 'komira-ai', 'carol'))).code).toBe('not_namespace_owner');
      expect((await refusal(r.members.remove(BOB, 'komira-ai', 'carol'))).code).toBe('not_namespace_member');
      expect(await r.namespaces.getMember('komira-ai', CAROL)).toBeDefined();
    });

    test('an account with no user namespace is user_not_found', async () => {
      const r = await rig();
      expect((await refusal(r.members.remove(ALICE, 'komira-ai', 'ghost'))).code).toBe('user_not_found');
    });
  });

  test('without an injected clock the system time dates a change', async () => {
    const r = await rig();
    const members = new OrgMembers({ namespaces: r.namespaces, access: r.access, users: r.users });
    const out = await members.set(ALICE, 'komira-ai', 'bob', 'member');
    expect(Date.parse(out.member.added_at)).not.toBeNaN();
  });
});
