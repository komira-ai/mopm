import { MemoryAuthStore, MemoryNamespaceStore, NamespaceAccess, type MemberRole, type NamespaceMember, type NamespaceRecord } from '../src/auth';
import type { UserRecord } from '../src/auth/types';

// NamespaceAccess over memory stores: which namespaces an account may write in and how they are ordered, the roles taken from the
// member table alone, and the answers for a namespace that is missing, invalid or reserved.

const AT = '2026-11-14T12:00:00Z';
const row = (namespace: string, github_id: number, over: Partial<NamespaceRecord> = {}): NamespaceRecord => ({ namespace, kind: 'user', github_id, created_at: AT, ...over });
const member = (namespace: string, github_id: number, role: MemberRole): NamespaceMember => ({ namespace, github_id, role, added_by: 1, added_at: AT });

/** User namespaces `rows`, and organization namespaces with their members: `{ 'komira-ai': [[account, role], ...] }` (the first is the owner that creates it). */
async function rig(rows: NamespaceRecord[], orgs: Record<string, Array<[number, MemberRole]>> = {}) {
  const namespaces = new MemoryNamespaceStore();
  for (const r of rows) await namespaces.createNamespace(r);
  let id = 100;
  for (const [ns, members] of Object.entries(orgs)) {
    const [first, ...rest] = members;
    await namespaces.createOrgNamespace(row(ns, id++, { kind: 'org', created_by: first![0] }), member(ns, first![0], first![1]));
    for (const [account, role] of rest) await namespaces.setMember(member(ns, account, role));
  }
  const users = new MemoryAuthStore();
  const access = new NamespaceAccess({ namespaces, users });
  return { access, users, namespaces };
}

const user = (github_id: number, handle: string): UserRecord => ({ github_id, handle, created_at: AT, last_login_at: AT });

describe('writable', () => {
  test('user namespaces first, then the organizations the account has a member row in, each kind sorted by namespace, with the row roles', async () => {
    const { access } = await rig([row('zed', 9), row('amy', 9)], {
      'zeta-org': [[9, 'member']],
      'alpha-org': [[9, 'owner']],
      'beta-org': [[1, 'owner'], [9, 'member']],
    });
    const out = await access.writable(user(9, 'amy'));
    expect(out.map((w) => [w.record.namespace, w.record.kind, w.role])).toEqual([
      ['amy', 'user', 'owner'],
      ['zed', 'user', 'owner'],
      ['alpha-org', 'org', 'owner'],
      ['beta-org', 'org', 'member'],
      ['zeta-org', 'org', 'member'],
    ]);
  });

  test('the order does not depend on the order the store lists them in', async () => {
    const { namespaces } = await rig([row('amy', 9), row('zed', 9)], { 'a-org': [[9, 'owner']], 'z-org': [[9, 'owner']] });
    const backwards = Object.create(namespaces, {
      listNamespaces: { value: async (id: number) => (await namespaces.listNamespaces(id)).reverse() },
      listMemberships: { value: async (id: number) => (await namespaces.listMemberships(id)).reverse() },
    });
    const flipped = new NamespaceAccess({ namespaces: backwards, users: new MemoryAuthStore() });
    expect((await flipped.writable(user(9, 'amy'))).map((w) => w.record.namespace)).toEqual(['amy', 'zed', 'a-org', 'z-org']);
  });

  test('an organization the account is not in is not listed, and a user namespace of another account is not either', async () => {
    const { access } = await rig([row('amy', 9), row('bob', 8)], { 'closed-org': [[8, 'owner']], 'open-org': [[8, 'owner'], [9, 'member']] });
    expect((await access.writable(user(9, 'amy'))).map((w) => w.record.namespace)).toEqual(['amy', 'open-org']);
  });

  test('a removed member no longer lists the organization', async () => {
    const { access, namespaces } = await rig([row('amy', 9)], { 'some-org': [[1, 'owner'], [9, 'member']] });
    expect((await access.writable(user(9, 'amy'))).map((w) => w.record.namespace)).toEqual(['amy', 'some-org']);
    await namespaces.removeMember('some-org', 9, 1, AT);
    expect((await access.writable(user(9, 'amy'))).map((w) => w.record.namespace)).toEqual(['amy']);
  });

  test('a membership whose namespace row is not an organization one is not listed', async () => {
    const { namespaces } = await rig([row('amy', 9)], { 'some-org': [[9, 'owner']] });
    const stray = Object.create(namespaces, { getNamespace: { value: async (ns: string) => (ns === 'some-org' ? undefined : namespaces.getNamespace(ns)) } });
    const out = await new NamespaceAccess({ namespaces: stray, users: new MemoryAuthStore() }).writable(user(9, 'amy'));
    expect(out.map((w) => w.record.namespace)).toEqual(['amy']);
  });
});

describe('roleIn and require', () => {
  test('the account bound to a user namespace is its owner; any other account is refused', async () => {
    const { access } = await rig([row('amy', 9)]);
    expect((await access.require('amy', 9)).role).toBe('owner');
    await expect(access.require('amy', 8)).rejects.toMatchObject({ code: 'not_namespace_member', detail: { namespace: 'amy' } });
  });

  test('an organization write answers the role of the member row, with no GitHub involved', async () => {
    const { access } = await rig([], { 'some-org': [[1, 'owner'], [9, 'member']] });
    expect((await access.require('some-org', 1)).role).toBe('owner');
    expect((await access.require('some-org', 9)).role).toBe('member');
  });

  test('an account with no member row is not_namespace_member, and so is one whose row was removed, on the very next call', async () => {
    const { access, namespaces } = await rig([], { 'some-org': [[1, 'owner'], [9, 'member']] });
    await expect(access.require('some-org', 7)).rejects.toMatchObject({ code: 'not_namespace_member', detail: { namespace: 'some-org' } });
    await access.require('some-org', 9);
    await namespaces.removeMember('some-org', 9, 1, AT);
    await expect(access.require('some-org', 9)).rejects.toMatchObject({ code: 'not_namespace_member' });
  });

  test.each([
    ['Not_Valid', 'invalid_namespace'],
    ['index', 'namespace_reserved'],
    ['poll', 'namespace_reserved'],
    ['nobody', 'namespace_not_found'],
  ])('%s is %s', async (namespace, code) => {
    const { access } = await rig([]);
    await expect(access.require(namespace, 9)).rejects.toMatchObject({ code });
    await expect(access.requireCi(namespace)).rejects.toMatchObject({ code });
  });
});

describe('requireCi', () => {
  test('a user namespace and an organization namespace answer their row; none asks about members', async () => {
    const { access } = await rig([row('amy', 9)], { 'some-org': [[1, 'owner']] });
    expect((await access.requireCi('amy')).github_id).toBe(9);
    expect((await access.requireCi('some-org')).kind).toBe('org');
  });
});

describe('handleOf and info', () => {
  test('handleOf is the handle of the last login, or u:<id> for an account without a row', async () => {
    const { access, users } = await rig([]);
    await users.upsertUser(9, 'Amy', AT);
    expect(await access.handleOf(9)).toBe('Amy');
    expect(await access.handleOf(77)).toBe('u:77');
  });

  test('info has no frozen state; a user namespace whose account has no user row falls back to the namespace, an organization shows its namespace', async () => {
    const { access } = await rig([row('amy', 9)], { 'some-org': [[1, 'owner']] });
    expect(await access.info(row('amy', 9))).toEqual({ namespace: 'amy', kind: 'user', github_id: 9, login: 'amy' });
    expect(await access.info(row('some-org', 10, { kind: 'org' }))).toEqual({ namespace: 'some-org', kind: 'org', github_id: 10, login: 'some-org' });
  });

  test('info of a user namespace shows the handle of the last login in its own case, which may differ from the namespace', async () => {
    const { access, users } = await rig([row('amy', 9)]);
    await users.upsertUser(9, 'Amy-New', AT);
    expect((await access.info(row('amy', 9))).login).toBe('Amy-New');
  });
});

describe('unavailableNamespace', () => {
  test('a login outside the grammar or reserved is unavailable, as is one held by another account; one the account holds or that is free is not', async () => {
    const { access } = await rig([row('taken', 5), row('mine', 9)]);
    expect(await access.unavailableNamespace(user(9, 'Bad_Name'))).toBe('bad_name');
    expect(await access.unavailableNamespace(user(9, 'Index'))).toBe('index');
    expect(await access.unavailableNamespace(user(9, 'Taken'))).toBe('taken');
    expect(await access.unavailableNamespace(user(9, 'Mine'))).toBeUndefined();
    expect(await access.unavailableNamespace(user(9, 'free-one'))).toBeUndefined();
  });
});
