import { AuthError, MemoryAuthStore, MemoryNamespaceStore, NamespaceAccess, NamespaceError, type NamespaceRecord, type OrgMembership } from '../src/auth';
import type { UserRecord } from '../src/auth/types';

// NamespaceAccess over memory stores and a scripted membership check: which namespaces an account may write in and how they
// are ordered, the roles, and the answers for a namespace that is missing, invalid, reserved, frozen or unreachable.

const AT = '2026-11-14T12:00:00Z';
const row = (namespace: string, github_id: number, over: Partial<NamespaceRecord> = {}): NamespaceRecord => ({ namespace, kind: 'user', github_id, created_at: AT, ...over });
const org = (namespace: string, github_id: number, installation_id: number | null = 1) => row(namespace, github_id, { kind: 'org', ...(installation_id === null ? {} : { installation_id }) });

type Check = (rec: NamespaceRecord, account: number) => Promise<'admin' | 'member'>;

async function rig(rows: NamespaceRecord[], check?: Check) {
  const namespaces = new MemoryNamespaceStore();
  for (const r of rows) await namespaces.createNamespace(r);
  const users = new MemoryAuthStore();
  const calls: string[] = [];
  const membership = check ? ({ check: async (rec: NamespaceRecord, account: number) => (calls.push(rec.namespace), check(rec, account)) } as unknown as OrgMembership) : undefined;
  const access = new NamespaceAccess({ namespaces, users, ...(membership ? { membership } : {}) });
  return { access, users, calls, namespaces };
}

const user = (github_id: number, handle: string, orgs?: number[]): UserRecord =>
  ({ github_id, handle, created_at: AT, last_login_at: AT, ...(orgs ? { orgs: orgs.map((id) => ({ github_id: id, login: `org${id}` })) } : {}) }) as unknown as UserRecord;

const notMember = (rec: NamespaceRecord) => new NamespaceError('not_namespace_member', 'no', { namespace: rec.namespace });

describe('writable', () => {
  test('user namespaces first, then organizations, each kind sorted by namespace; an organization listed twice is checked once', async () => {
    const { access, calls } = await rig(
      [row('zed', 9), row('amy', 9), org('zeta-org', 20), org('alpha-org', 10), org('beta-org', 10)],
      async (_rec, _account) => 'member',
    );
    const out = await access.writable(user(9, 'amy', [20, 10, 20, 10]));
    expect(out.map((w) => [w.record.namespace, w.role])).toEqual([
      ['amy', 'owner'],
      ['zed', 'owner'],
      ['alpha-org', 'member'],
      ['beta-org', 'member'],
      ['zeta-org', 'member'],
    ]);
    // Organization ids are visited in ascending order, once each: 10 (two rows), then 20.
    expect(calls).toEqual(['alpha-org', 'beta-org', 'zeta-org']);
  });

  test('the order does not depend on the order the store lists them in', async () => {
    const { access, namespaces } = await rig([row('amy', 9), row('zed', 9), org('a-org', 10), org('z-org', 10)], async () => 'member');
    const backwards = Object.create(namespaces, { listNamespaces: { value: async (id: number) => (await namespaces.listNamespaces(id)).reverse() } });
    const flipped = new NamespaceAccess({ namespaces: backwards, users: new MemoryAuthStore(), membership: (access as unknown as { d: { membership: OrgMembership } }).d.membership });
    expect((await flipped.writable(user(9, 'amy', [10]))).map((w) => w.record.namespace)).toEqual(['amy', 'zed', 'a-org', 'z-org']);
  });

  test('an organization namespace the check refuses is left out while the others are listed with their roles', async () => {
    const { access } = await rig([org('closed', 10), org('open', 20), org('frozen', 30, null)], async (rec) => {
      if (rec.namespace === 'closed') throw notMember(rec);
      if (rec.namespace === 'frozen') throw new NamespaceError('namespace_unverified', 'frozen', { namespace: 'frozen' });
      return 'admin';
    });
    const out = await access.writable(user(9, 'amy', [10, 20, 30]));
    expect(out.map((w) => [w.record.namespace, w.role])).toEqual([['open', 'admin']]);
  });

  test('unavailable from the check is not skipped: it propagates', async () => {
    const { access } = await rig([org('closed', 10)], async () => {
      throw new AuthError('unavailable', 'GitHub is down');
    });
    await expect(access.writable(user(9, 'amy', [10]))).rejects.toMatchObject({ code: 'unavailable' });
  });

  test('without a membership check no organization is listed', async () => {
    const { access } = await rig([row('amy', 9), org('some-org', 10)]);
    const out = await access.writable(user(9, 'amy', [10]));
    expect(out.map((w) => w.record.namespace)).toEqual(['amy']);
  });

  test('a user with no recorded organizations lists its own namespaces only, and a user namespace filed under a recorded organization id is not listed as one', async () => {
    const { access, calls } = await rig([row('amy', 9), row('shared-id', 10)], async () => 'member');
    const out = await access.writable(user(9, 'amy'));
    expect(out.map((w) => w.record.namespace)).toEqual(['amy']);
    const viaOrgId = await access.writable(user(9, 'amy', [10]));
    expect(viaOrgId.map((w) => w.record.namespace)).toEqual(['amy']);
    expect(calls).toEqual([]);
  });
});

describe('roleIn and require', () => {
  test('the account bound to a user namespace is its owner; any other account is refused', async () => {
    const { access } = await rig([row('amy', 9)]);
    expect((await access.require('amy', 9)).role).toBe('owner');
    await expect(access.require('amy', 8)).rejects.toMatchObject({ code: 'not_namespace_member', detail: { namespace: 'amy' } });
  });

  test('an organization write without a GitHub App is unavailable and names GitHub', async () => {
    const { access } = await rig([org('some-org', 10)]);
    await expect(access.require('some-org', 9)).rejects.toMatchObject({ code: 'unavailable', detail: { namespace: 'some-org', service: 'GitHub' } });
  });

  test('an organization write answers the role of the membership check', async () => {
    const { access } = await rig([org('some-org', 10)], async () => 'admin');
    expect((await access.require('some-org', 9)).role).toBe('admin');
  });

  test.each([
    ['Not_Valid', 'invalid_namespace'],
    ['index', 'namespace_reserved'],
    ['nobody', 'namespace_not_found'],
  ])('%s is %s', async (namespace, code) => {
    const { access } = await rig([]);
    await expect(access.require(namespace, 9)).rejects.toMatchObject({ code });
    await expect(access.requireCi(namespace)).rejects.toMatchObject({ code });
  });
});

describe('requireCi', () => {
  test('a user namespace and an organization with its installation bound answer the row; a frozen organization is namespace_unverified', async () => {
    const { access } = await rig([row('amy', 9), org('some-org', 10), org('frozen', 11, null)]);
    expect((await access.requireCi('amy')).github_id).toBe(9);
    expect((await access.requireCi('some-org')).github_id).toBe(10);
    await expect(access.requireCi('frozen')).rejects.toMatchObject({ code: 'namespace_unverified', detail: { namespace: 'frozen' } });
  });
});

describe('handleOf and info', () => {
  test('handleOf is the handle of the last login, or u:<id> for an account without a row', async () => {
    const { access, users } = await rig([]);
    await users.upsertUser(9, 'Amy', AT);
    expect(await access.handleOf(9)).toBe('Amy');
    expect(await access.handleOf(77)).toBe('u:77');
  });

  test('info of a user namespace whose account has no user row falls back to the namespace; of an organization it is the namespace', async () => {
    const { access } = await rig([row('amy', 9), org('some-org', 10), org('frozen', 11, null)]);
    expect(await access.info(row('amy', 9))).toEqual({ namespace: 'amy', kind: 'user', github_id: 9, login: 'amy', frozen: false });
    expect(await access.info(org('some-org', 10))).toEqual({ namespace: 'some-org', kind: 'org', github_id: 10, login: 'some-org', frozen: false });
    expect((await access.info(org('frozen', 11, null))).frozen).toBe(true);
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
