import { DynamoNamespaceStore } from '../src/auth/dynamo-namespace-store';
import {
  ensureUserNamespace,
  MemoryNamespaceStore,
  NAMESPACE_MAX_LENGTH,
  namespaceProblem,
  type NamespaceMember,
  type NamespaceRecord,
  type NamespaceStore,
} from '../src/auth/namespaces';
import { FakeAuthDoc, LAMBDA_GRANTS } from './auth-fake-doc';

// The namespace rules of docs/design/namespaces.md sections 1 and 2.1 and 2.3, and the NamespaceStore port: one suite over
// the memory adapter (which defines the rules) and the DynamoDB adapter on the strict fake under the Lambda's grants.

const NOW = '2026-10-14T12:00:00.000Z';
const rec = (namespace: string, github_id: number, over: Partial<NamespaceRecord> = {}): NamespaceRecord => ({
  namespace,
  kind: 'user',
  github_id,
  created_at: NOW,
  ...over,
});

describe('namespaceProblem: the grammar of a GitHub login in lower case, and the reserved strings', () => {
  test.each([
    ['a', 'one character'],
    ['komira-ai', 'a hyphen between parts'],
    ['a-b-c-1', 'several single hyphens'],
    ['0day', 'a leading digit'],
    ['x'.repeat(NAMESPACE_MAX_LENGTH), 'exactly 39 characters'],
    ['linux', 'a platform word without a subdir suffix'],
    ['linux64', 'a platform word run on, no hyphen'],
    ['noarch-x', 'noarch with a suffix is not a subdir'],
    ['mac-64', 'a platform word conda does not use'],
    ['indexer', 'a reserved prefix as part of a longer word'],
    ['mopm', 'the reserved import names are not reserved namespaces'],
  ])('%s is a namespace (%s)', (ns) => {
    expect(namespaceProblem(ns)).toBeUndefined();
  });

  test.each([
    ['', 'empty'],
    ['x'.repeat(NAMESPACE_MAX_LENGTH + 1), '40 characters'],
    ['-a', 'a leading hyphen'],
    ['a-', 'a trailing hyphen'],
    ['a--b', 'a double hyphen'],
    ['Octo', 'upper case: one spelling'],
    ['alice_corp', 'an underscore (an enterprise-managed login)'],
    ['a.b', 'a dot'],
    ['a/b', 'a slash'],
    ['café', 'a letter outside ASCII'],
  ])('%s is invalid (%s)', (ns) => {
    expect(namespaceProblem(ns)).toBe('invalid');
  });

  test.each([
    'noarch',
    'linux-64',
    'linux-aarch64',
    'osx-arm64',
    'osx-64',
    'win-64',
    'freebsd-64',
    'zos-z',
    'wasi-wasm32',
    'emscripten-wasm32',
    'index',
    'quarantine',
    'native-mirror',
    'poll',
  ])('%s is reserved', (ns) => {
    expect(namespaceProblem(ns)).toBe('reserved');
  });
});

type Check = (s: NamespaceStore) => Promise<void>;

const LATER = '2026-10-16T00:00:00.000Z';
const member = (namespace: string, github_id: number, role: NamespaceMember['role'], over: Partial<NamespaceMember> = {}): NamespaceMember => ({
  namespace,
  github_id,
  role,
  added_by: 4242,
  added_at: NOW,
  ...over,
});
const orgWithOwner = (s: NamespaceStore, owner = 4242) =>
  s.createOrgNamespace(rec('komira-ai', 77, { kind: 'org', created_by: owner }), member('komira-ai', owner, 'owner', { added_by: owner }));

const NO_MEMBERS: Pick<NamespaceStore, 'createOrgNamespace' | 'getMember' | 'listMembers' | 'listMemberships' | 'setMember' | 'removeMember'> = {
  createOrgNamespace: async (r) => ({ created: true, record: r }),
  getMember: async () => undefined,
  listMembers: async () => [],
  listMemberships: async () => [],
  setMember: async () => 'added',
  removeMember: async () => 'not_member',
};

const CHECKS: Record<string, Check> = {
  'an absent namespace is undefined; a created one reads back exactly, an org row with its registrant': async (s) => {
    expect(await s.getNamespace('octo')).toBeUndefined();
    expect(await s.createNamespace(rec('octo', 4242))).toEqual({
      created: true,
      record: rec('octo', 4242),
    });
    expect(await s.getNamespace('octo')).toEqual(rec('octo', 4242));
    const org = rec('komira-ai', 77, { kind: 'org', created_by: 4242 });
    await s.createNamespace(org);
    expect(await s.getNamespace('komira-ai')).toEqual(org);
  },
  'create once: a second create of the string, by anyone, stores nothing and answers the holder': async (s) => {
    await s.createNamespace(rec('octo', 4242));
    expect(await s.createNamespace(rec('octo', 9, { created_at: '2026-10-15T00:00:00.000Z' }))).toEqual({
      created: false,
      record: rec('octo', 4242),
    });
    expect(await s.createNamespace(rec('octo', 4242, { created_at: '2026-10-15T00:00:00.000Z' }))).toEqual({
      created: false,
      record: rec('octo', 4242),
    });
    expect(await s.getNamespace('octo')).toEqual(rec('octo', 4242));
  },
  'of two racing creates of one string exactly one wins, and both answer the winner': async (s) => {
    const [a, b] = await Promise.all([s.createNamespace(rec('octo', 1)), s.createNamespace(rec('octo', 2))]);
    expect([a!.created, b!.created].filter(Boolean)).toHaveLength(1);
    expect(a!.record).toEqual(b!.record);
    expect(await s.getNamespace('octo')).toEqual(a!.record);
  },
  'listNamespaces gives every namespace of one id across pages, in namespace order, and nobody elses': async (s) => {
    for (const ns of ['octo-c', 'octo-a', 'octo-b']) await s.createNamespace(rec(ns, 4242));
    await s.createNamespace(rec('other', 9));
    expect((await s.listNamespaces(4242)).map((r) => r.namespace)).toEqual(['octo-a', 'octo-b', 'octo-c']);
    expect(await s.listNamespaces(4242)).toEqual(['octo-a', 'octo-b', 'octo-c'].map((ns) => rec(ns, 4242)));
    expect(await s.listNamespaces(9)).toEqual([rec('other', 9)]);
    expect(await s.listNamespaces(1)).toEqual([]);
  },
  'a record read back is a copy: changing it changes nothing stored': async (s) => {
    await s.createNamespace(rec('octo', 4242));
    const r = (await s.getNamespace('octo'))!;
    r.github_id = 9;
    (await s.listNamespaces(4242))[0]!.namespace = 'x';
    expect(await s.getNamespace('octo')).toEqual(rec('octo', 4242));
  },
  'createOrgNamespace stores the org row and its first owner together; both read back, the owner is listed and the org is a membership': async (
    s,
  ) => {
    const org = rec('komira-ai', 77, { kind: 'org', created_by: 4242 });
    expect(await s.createOrgNamespace(org, member('komira-ai', 4242, 'owner'))).toEqual({ created: true, record: org });
    expect(await s.getNamespace('komira-ai')).toEqual(org);
    expect(await s.listNamespaces(77)).toEqual([org]);
    expect(await s.getMember('komira-ai', 4242)).toEqual(member('komira-ai', 4242, 'owner'));
    expect(await s.listMembers('komira-ai')).toEqual([member('komira-ai', 4242, 'owner')]);
    expect(await s.listMemberships(4242)).toEqual([member('komira-ai', 4242, 'owner')]);
  },
  'createOrgNamespace on a held string writes nothing: no row change, no owner, the held row answered': async (s) => {
    await s.createNamespace(rec('octo', 4242));
    const org = rec('komira-ai', 77, { kind: 'org', created_by: 4242 });
    await s.createOrgNamespace(org, member('komira-ai', 4242, 'owner'));
    const second = rec('komira-ai', 78, {
      kind: 'org',
      created_by: 9,
      created_at: '2026-10-15T00:00:00.000Z',
    });
    expect(await s.createOrgNamespace(second, member('komira-ai', 9, 'owner'))).toEqual({ created: false, record: org });
    expect(await s.createOrgNamespace(rec('octo', 5, { kind: 'org', created_by: 5 }), member('octo', 5, 'owner'))).toEqual({
      created: false,
      record: rec('octo', 4242),
    });
    expect(await s.listMembers('komira-ai')).toEqual([member('komira-ai', 4242, 'owner')]);
    expect(await s.listMembers('octo')).toEqual([]);
    expect(await s.getMember('komira-ai', 9)).toBeUndefined();
    expect(await s.getNamespace('komira-ai')).toEqual(org);
  },
  'of two racing org creates of one string exactly one wins, with its owner only': async (s) => {
    const [a, b] = await Promise.all([
      s.createOrgNamespace(rec('komira-ai', 77, { kind: 'org', created_by: 1 }), member('komira-ai', 1, 'owner')),
      s.createOrgNamespace(rec('komira-ai', 77, { kind: 'org', created_by: 2 }), member('komira-ai', 2, 'owner')),
    ]);
    expect([a!.created, b!.created].filter(Boolean)).toHaveLength(1);
    expect(a!.record).toEqual(b!.record);
    expect((await s.listMembers('komira-ai')).map((m) => m.github_id)).toEqual([a!.record.created_by]);
  },
  'setMember adds a member, then answers same for the same role without touching the row, and changed for another role': async (s) => {
    await orgWithOwner(s);
    expect(await s.setMember(member('komira-ai', 10, 'member', { added_at: LATER }))).toBe('added');
    expect(await s.getMember('komira-ai', 10)).toEqual(member('komira-ai', 10, 'member', { added_at: LATER }));
    expect(
      await s.setMember(
        member('komira-ai', 10, 'member', {
          added_by: 99,
          added_at: '2026-10-16T00:00:00.000Z',
        }),
      ),
    ).toBe('same');
    expect(await s.getMember('komira-ai', 10)).toEqual(member('komira-ai', 10, 'member', { added_at: LATER }));
    const promoted = member('komira-ai', 10, 'owner', {
      added_by: 4242,
      added_at: '2026-10-16T00:00:00.000Z',
    });
    expect(await s.setMember(promoted)).toBe('changed');
    expect(await s.getMember('komira-ai', 10)).toEqual(promoted);
  },
  'an owner can be demoted while another owner remains': async (s) => {
    await orgWithOwner(s);
    await s.setMember(member('komira-ai', 10, 'owner'));
    expect(await s.setMember(member('komira-ai', 4242, 'member', { added_at: LATER }))).toBe('changed');
    expect((await s.getMember('komira-ai', 4242))!.role).toBe('member');
    expect((await s.getMember('komira-ai', 10))!.role).toBe('owner');
  },
  'the last owner cannot be demoted or removed, and nothing is written; a member can be removed': async (s) => {
    await orgWithOwner(s);
    await s.setMember(member('komira-ai', 10, 'member'));
    expect(await s.setMember(member('komira-ai', 4242, 'member', { added_at: LATER }))).toBe('last_owner');
    expect(await s.removeMember('komira-ai', 4242, 4242, LATER)).toBe('last_owner');
    expect(await s.getMember('komira-ai', 4242)).toEqual(member('komira-ai', 4242, 'owner'));
    expect(await s.removeMember('komira-ai', 10, 4242, LATER)).toBe('removed');
    expect((await s.listMembers('komira-ai')).map((m) => m.github_id)).toEqual([4242]);
  },
  'an owner may remove themselves when another owner remains': async (s) => {
    await orgWithOwner(s);
    await s.setMember(member('komira-ai', 10, 'owner'));
    expect(await s.removeMember('komira-ai', 4242, 4242, LATER)).toBe('removed');
    expect(await s.listMembers('komira-ai')).toEqual([member('komira-ai', 10, 'owner')]);
  },
  'removeMember of a non-member, or in a namespace without members, answers not_member': async (s) => {
    await orgWithOwner(s);
    expect(await s.removeMember('komira-ai', 10, 4242, LATER)).toBe('not_member');
    expect(await s.removeMember('nobody', 10, 4242, LATER)).toBe('not_member');
    expect(await s.listMembers('komira-ai')).toEqual([member('komira-ai', 4242, 'owner')]);
  },
  'a removed member is not read by getMember, listMembers or listMemberships; removing again answers not_member': async (s) => {
    await orgWithOwner(s);
    await s.setMember(member('komira-ai', 10, 'member'));
    expect(await s.removeMember('komira-ai', 10, 4242, LATER)).toBe('removed');
    expect(await s.getMember('komira-ai', 10)).toBeUndefined();
    expect((await s.listMembers('komira-ai')).map((m) => m.github_id)).toEqual([4242]);
    expect(await s.listMemberships(10)).toEqual([]);
    expect(await s.removeMember('komira-ai', 10, 4242, LATER)).toBe('not_member');
  },
  'a removed account can be added again, as a member or as an owner, and is then read as that': async (s) => {
    await orgWithOwner(s);
    await s.setMember(member('komira-ai', 10, 'owner'));
    await s.removeMember('komira-ai', 10, 4242, LATER);
    const again = member('komira-ai', 10, 'member', {
      added_by: 4242,
      added_at: '2026-10-17T00:00:00.000Z',
    });
    expect(await s.setMember(again)).toBe('added');
    expect(await s.getMember('komira-ai', 10)).toEqual(again);
    expect(await s.listMemberships(10)).toEqual([again]);
    await s.removeMember('komira-ai', 10, 4242, LATER);
    expect(await s.setMember({ ...again, role: 'owner' })).toBe('added');
    expect((await s.getMember('komira-ai', 10))!.role).toBe('owner');
  },
  'a removed owner no longer counts: the remaining sole owner cannot be demoted': async (s) => {
    await orgWithOwner(s);
    await s.setMember(member('komira-ai', 10, 'owner'));
    await s.removeMember('komira-ai', 10, 4242, LATER);
    expect(await s.setMember(member('komira-ai', 4242, 'member'))).toBe('last_owner');
  },
  'listMembers is sorted by GitHub id, numerically': async (s) => {
    await orgWithOwner(s, 100);
    for (const id of [9, 1000, 20]) await s.setMember(member('komira-ai', id, 'member'));
    expect((await s.listMembers('komira-ai')).map((m) => m.github_id)).toEqual([9, 20, 100, 1000]);
  },
  'listMemberships gives every org the account is in, sorted by namespace, across pages, and nobody elses': async (s) => {
    for (const ns of ['org-c', 'org-a', 'org-b', 'org-d']) {
      await s.createOrgNamespace(rec(ns, ns.charCodeAt(4), { kind: 'org', created_by: 1 }), member(ns, 1, 'owner'));
      await s.setMember(member(ns, 10, ns === 'org-c' ? 'owner' : 'member'));
    }
    await s.removeMember('org-d', 10, 1, LATER);
    expect(await s.listMemberships(10)).toEqual([member('org-a', 10, 'member'), member('org-b', 10, 'member'), member('org-c', 10, 'owner')]);
    expect((await s.listMemberships(1)).map((m) => m.namespace)).toEqual(['org-a', 'org-b', 'org-c', 'org-d']);
    expect(await s.listMemberships(5)).toEqual([]);
  },
  'setMember in a namespace that is not an organization one is an error and writes nothing': async (s) => {
    await s.createNamespace(rec('octo', 4242));
    await expect(s.setMember(member('octo', 10, 'member'))).rejects.toThrow('not an organization namespace');
    await expect(s.setMember(member('absent', 10, 'member'))).rejects.toThrow('not an organization namespace');
    expect(await s.listMembers('octo')).toEqual([]);
  },
  'a member record read back is a copy: changing it changes nothing stored': async (s) => {
    await orgWithOwner(s);
    (await s.getMember('komira-ai', 4242))!.role = 'member';
    (await s.listMembers('komira-ai'))[0]!.role = 'member';
    (await s.listMemberships(4242))[0]!.role = 'member';
    expect((await s.getMember('komira-ai', 4242))!.role).toBe('owner');
  },
  'two concurrent demotions of two owners leave exactly one owner': async (s) => {
    await orgWithOwner(s);
    await s.setMember(member('komira-ai', 10, 'owner'));
    const outcomes = await Promise.all([
      s.setMember(member('komira-ai', 4242, 'member', { added_at: LATER })),
      s.setMember(member('komira-ai', 10, 'member', { added_at: LATER })),
    ]);
    expect([...outcomes].sort()).toEqual(['changed', 'last_owner']);
    expect((await s.listMembers('komira-ai')).filter((m) => m.role === 'owner')).toHaveLength(1);
  },
  'a concurrent demotion and removal of two owners leave exactly one owner': async (s) => {
    await orgWithOwner(s);
    await s.setMember(member('komira-ai', 10, 'owner'));
    const outcomes = await Promise.all([
      s.setMember(member('komira-ai', 4242, 'member', { added_at: LATER })),
      s.removeMember('komira-ai', 10, 4242, LATER),
    ]);
    expect(outcomes.filter((o) => o === 'last_owner')).toHaveLength(1);
    expect((await s.listMembers('komira-ai')).filter((m) => m.role === 'owner')).toHaveLength(1);
  },
};

// The grants of the two namespace tables as the stack declares them (service/infra/stacks/lib/api-stack.ts AUTH_GRANTS).
const GRANTS = {
  ...LAMBDA_GRANTS,
  namespace_members: {
    actions: ['dynamodb:GetItem', 'dynamodb:PutItem', 'dynamodb:Query'],
    indexes: ['by_member'],
  },
};
const MEMBERS = 'mopm-t-namespace_members';
const lambdaDoc = () => new FakeAuthDoc({ pageSize: 2, grants: GRANTS });
const dynamo = (doc = lambdaDoc()) => new DynamoNamespaceStore(doc, 'mopm-t-namespaces', MEMBERS);

describe.each<[string, () => NamespaceStore]>([
  ['memory', () => new MemoryNamespaceStore()],
  ['dynamodb (strict fake, Lambda grants)', () => dynamo()],
])('NamespaceStore contract: %s', (_label, make) => {
  test.each(Object.entries(CHECKS))('%s', async (_name, check) => {
    await check(make());
  });
});

describe('the DynamoDB adapter', () => {
  const NS = (extra: object = {}) => ({
    namespace: 'komira-ai',
    kind: 'org',
    github_id: '77',
    github_id_num: 77,
    created_at: NOW,
    created_by: 4242,
    ...extra,
  });
  const row = (id: number, role: string, extra: object = {}) => ({
    namespace: 'komira-ai',
    member: String(id),
    github_id: id,
    role,
    added_by: 4242,
    added_at: NOW,
    ...extra,
  });

  test('a row keeps the id as a string index key with the number beside it, and nothing is ever deleted or updated', async () => {
    const doc = lambdaDoc();
    const s = dynamo(doc);
    await s.createNamespace(rec('octo', 4242));
    await s.createNamespace(rec('octo', 9));
    expect(doc.dump('namespaces')).toEqual([
      {
        namespace: 'octo',
        kind: 'user',
        github_id: '4242',
        github_id_num: 4242,
        created_at: NOW,
      },
    ]);
    expect(doc.commands.filter((c) => c !== 'GetCommand' && c !== 'PutCommand')).toEqual([]);
  });

  test('a refusal other than the condition is an error, not a holder (no permission: AccessDenied surfaces)', async () => {
    const doc = new FakeAuthDoc({
      grants: { ...GRANTS, namespaces: { actions: ['dynamodb:GetItem'] } },
    });
    await expect(dynamo(doc).createNamespace(rec('octo', 4242))).rejects.toMatchObject({ name: 'AccessDeniedException' });
    expect(doc.dump('namespaces')).toEqual([]);
  });

  test('createOrgNamespace is one transaction: the org row with members_rev 1 and the owner row keyed by the id as a string', async () => {
    const doc = lambdaDoc();
    await orgWithOwner(dynamo(doc));
    expect(doc.commands).toEqual(['TransactWriteCommand']);
    expect(doc.dump('namespaces')).toEqual([NS({ members_rev: 1 })]);
    expect(doc.dump('namespace_members')).toEqual([row(4242, 'owner', { added_by: 4242 })]);
  });

  test('createOrgNamespace on a held string answers the held row, which it reads back, and writes nothing', async () => {
    const doc = lambdaDoc();
    doc.seed('namespaces', {
      namespace: 'komira-ai',
      kind: 'user',
      github_id: '9',
      github_id_num: 9,
      created_at: NOW,
    });
    const r = await orgWithOwner(dynamo(doc));
    expect(r).toEqual({ created: false, record: rec('komira-ai', 9) });
    expect(doc.dump('namespace_members')).toEqual([]);
  });

  test('createOrgNamespace refuses a user record, or an owner of another namespace, before any write', async () => {
    const doc = lambdaDoc();
    const s = dynamo(doc);
    await expect(s.createOrgNamespace(rec('octo', 4242), member('octo', 4242, 'owner'))).rejects.toThrow('not an organization namespace');
    await expect(s.createOrgNamespace(rec('komira-ai', 77, { kind: 'org' }), member('other', 4242, 'owner'))).rejects.toThrow('with its owner');
    expect(doc.commands).toEqual([]);
  });

  test('createOrgNamespace surfaces a cancelled transaction that carries no reasons at all', async () => {
    const doc = lambdaDoc();
    const send = doc.send.bind(doc);
    doc.send = async (cmd) => {
      if (cmd.constructor.name === 'TransactWriteCommand') throw Object.assign(new Error('cancelled'), { name: 'TransactionCanceledException' });
      return send(cmd);
    };
    await expect(orgWithOwner(dynamo(doc))).rejects.toMatchObject({ name: 'TransactionCanceledException' });
  });

  test('createOrgNamespace whose condition failed but whose row cannot be read back is an error, never a made-up holder', async () => {
    const doc = lambdaDoc();
    const send = doc.send.bind(doc);
    doc.send = async (cmd) => {
      if (cmd.constructor.name === 'TransactWriteCommand')
        throw Object.assign(new Error('cancelled'), { name: 'TransactionCanceledException', CancellationReasons: [{ Code: 'ConditionalCheckFailed' }, { Code: 'None' }] });
      return send(cmd);
    };
    await expect(orgWithOwner(dynamo(doc))).rejects.toThrow('namespace komira-ai: the create was refused but no row is stored');
  });

  test('a query answer without Items reads as no members and no memberships', async () => {
    const doc = lambdaDoc();
    const send = doc.send.bind(doc);
    doc.send = async (cmd) => (cmd.constructor.name === 'QueryCommand' ? {} : send(cmd));
    const store = dynamo(doc);
    await expect(store.listMembers('komira-ai')).resolves.toEqual([]);
    await expect(store.listMemberships(4242)).resolves.toEqual([]);
  });

  test('createOrgNamespace surfaces a transaction cancelled for another reason than a failed condition', async () => {
    const doc = lambdaDoc();
    const send = doc.send.bind(doc);
    doc.send = async (cmd) => {
      if (cmd.constructor.name === 'TransactWriteCommand')
        throw Object.assign(new Error('busy'), {
          name: 'TransactionCanceledException',
          CancellationReasons: [{ Code: 'TransactionConflict' }, { Code: 'None' }],
        });
      return send(cmd);
    };
    await expect(orgWithOwner(dynamo(doc))).rejects.toMatchObject({
      name: 'TransactionCanceledException',
    });
  });

  test('a member change bumps members_rev with the member row in one transaction; a same answer writes nothing', async () => {
    const doc = lambdaDoc();
    const s = dynamo(doc);
    await orgWithOwner(s);
    doc.commands.length = 0;
    expect(await s.setMember(member('komira-ai', 10, 'member'))).toBe('added');
    expect(await s.setMember(member('komira-ai', 10, 'member'))).toBe('same');
    expect(doc.commands.filter((c) => c === 'TransactWriteCommand')).toHaveLength(1);
    expect(doc.dump('namespaces')).toEqual([NS({ members_rev: 2 })]);
    expect(doc.dump('namespace_members')).toEqual([row(4242, 'owner'), row(10, 'member')]);
  });

  test('a namespace row without members_rev is changed under attribute_not_exists, and gets members_rev 1', async () => {
    const doc = lambdaDoc();
    doc.seed('namespaces', NS());
    expect(await dynamo(doc).setMember(member('komira-ai', 10, 'owner'))).toBe('added');
    expect(doc.dump('namespaces')).toEqual([NS({ members_rev: 1 })]);
  });

  test('a removal writes the row back with role removed, who removed it and when; nothing is deleted', async () => {
    const doc = lambdaDoc();
    const s = dynamo(doc);
    await orgWithOwner(s);
    await s.setMember(member('komira-ai', 10, 'member'));
    expect(await s.removeMember('komira-ai', 10, 4242, LATER)).toBe('removed');
    expect(doc.dump('namespace_members')).toEqual([row(4242, 'owner'), row(10, 'removed', { removed_by: 4242, removed_at: LATER })]);
    expect(doc.commands.filter((c) => c === 'DeleteCommand' || c === 'UpdateCommand')).toEqual([]);
  });

  test('a re-add replaces the removed row: no removed_by or removed_at is left', async () => {
    const doc = lambdaDoc();
    const s = dynamo(doc);
    await orgWithOwner(s);
    await s.setMember(member('komira-ai', 10, 'member'));
    await s.removeMember('komira-ai', 10, 4242, LATER);
    await s.setMember(member('komira-ai', 10, 'owner', { added_at: LATER }));
    expect(doc.dump('namespace_members').find((i) => i.member === '10')).toEqual(row(10, 'owner', { added_at: LATER }));
  });

  test('a member change lost to another change reads and decides again, and then writes', async () => {
    const doc = lambdaDoc();
    const s = dynamo(doc);
    const other = dynamo(doc);
    await orgWithOwner(s);
    const send = doc.send.bind(doc);
    let raced = false;
    doc.send = async (cmd) => {
      if (cmd.constructor.name === 'TransactWriteCommand' && !raced) {
        raced = true;
        await other.setMember(member('komira-ai', 11, 'member')); // another change lands between this one's read and write
      }
      return send(cmd);
    };
    expect(await s.setMember(member('komira-ai', 10, 'member'))).toBe('added');
    expect((await s.listMembers('komira-ai')).map((m) => m.github_id)).toEqual([10, 11, 4242]);
    expect(doc.commands.filter((c) => c === 'TransactWriteCommand')).toHaveLength(4); // create, the other change, this change lost, this change again
    expect(doc.dump('namespaces')).toEqual([NS({ members_rev: 3 })]);
  });

  test('a retry decides on what the winner wrote: a demotion that was allowed becomes last_owner', async () => {
    const doc = lambdaDoc();
    const s = dynamo(doc);
    const other = dynamo(doc);
    await orgWithOwner(s);
    await s.setMember(member('komira-ai', 10, 'owner'));
    const send = doc.send.bind(doc);
    let raced = false;
    doc.send = async (cmd) => {
      if (cmd.constructor.name === 'TransactWriteCommand' && !raced) {
        raced = true;
        expect(await other.setMember(member('komira-ai', 10, 'member'))).toBe('changed');
      }
      return send(cmd);
    };
    expect(await s.setMember(member('komira-ai', 4242, 'member'))).toBe('last_owner');
    expect((await s.getMember('komira-ai', 4242))!.role).toBe('owner');
  });

  test('a change that loses four times is an error, after exactly four attempts, and writes no member row', async () => {
    const doc = lambdaDoc();
    const s = dynamo(doc);
    await orgWithOwner(s);
    const send = doc.send.bind(doc);
    let attempts = 0;
    doc.send = async (cmd) => {
      if (cmd.constructor.name === 'TransactWriteCommand') {
        attempts++;
        const held = doc.dump('namespaces')[0]!;
        doc.seed('namespaces', { ...held, members_rev: held.members_rev + 1 }); // someone else always gets in first
      }
      return send(cmd);
    };
    await expect(s.setMember(member('komira-ai', 10, 'member'))).rejects.toMatchObject({ name: 'TransactionCanceledException' });
    expect(attempts).toBe(4);
    expect(doc.dump('namespace_members')).toEqual([row(4242, 'owner')]);
  });

  test('a change in a namespace that is a user row, or absent: setMember is an error and removeMember not_member, before any write', async () => {
    const doc = lambdaDoc();
    const s = dynamo(doc);
    await s.createNamespace(rec('octo', 4242));
    await expect(s.setMember(member('octo', 10, 'member'))).rejects.toThrow('not an organization namespace');
    expect(await s.removeMember('absent', 10, 1, LATER)).toBe('not_member');
    expect(await s.removeMember('octo', 10, 1, LATER)).toBe('not_member');
    expect(doc.commands.filter((c) => c === 'TransactWriteCommand')).toEqual([]);
  });

  test('the members are read with strong consistency, across pages; a membership list reads the by_member index', async () => {
    const doc = new FakeAuthDoc({ pageSize: 1, grants: GRANTS });
    const s = dynamo(doc);
    await orgWithOwner(s);
    for (const id of [10, 11]) await s.setMember(member('komira-ai', id, 'member'));
    expect((await s.listMembers('komira-ai')).map((m) => m.github_id)).toEqual([10, 11, 4242]);
    expect((await s.listMemberships(11)).map((m) => m.namespace)).toEqual(['komira-ai']);
  });

  test('without the by_member grant the membership list is AccessDenied: the role needs the index by name', async () => {
    const doc = new FakeAuthDoc({
      grants: {
        ...GRANTS,
        namespace_members: {
          actions: ['dynamodb:GetItem', 'dynamodb:PutItem', 'dynamodb:Query'],
        },
      },
    });
    await expect(dynamo(doc).listMemberships(4242)).rejects.toMatchObject({
      name: 'AccessDeniedException',
    });
  });

  test('without the PutItem grant on the members table a transaction is AccessDenied and nothing is written', async () => {
    const doc = new FakeAuthDoc({
      grants: {
        ...GRANTS,
        namespace_members: {
          actions: ['dynamodb:GetItem', 'dynamodb:Query'],
          indexes: ['by_member'],
        },
      },
    });
    await expect(orgWithOwner(dynamo(doc))).rejects.toMatchObject({
      name: 'AccessDeniedException',
    });
    expect(doc.dump('namespaces')).toEqual([]);
  });

  test('without the by_github_id grant the list is AccessDenied: the role needs by_github_id by name', async () => {
    const doc = new FakeAuthDoc({
      grants: {
        ...GRANTS,
        namespaces: {
          actions: ['dynamodb:GetItem', 'dynamodb:PutItem', 'dynamodb:Query'],
        },
      },
    });
    await expect(dynamo(doc).listNamespaces(4242)).rejects.toMatchObject({
      name: 'AccessDeniedException',
    });
  });
});

describe('the strict fake: TransactWriteItems', () => {
  const put = (table: string, Item: Record<string, unknown>, extra: object = {}) => ({ Put: { TableName: table, Item, ...extra } });
  const cond = {
    ConditionExpression: 'attribute_not_exists(#n)',
    ExpressionAttributeNames: { '#n': 'namespace' },
  };

  test('one failed condition cancels every item and names which one failed', async () => {
    const { TransactWriteCommand } = await import('@aws-sdk/lib-dynamodb');
    const doc = new FakeAuthDoc();
    doc.seed('namespaces', {
      namespace: 'b',
      kind: 'user',
      github_id: '1',
      github_id_num: 1,
      created_at: NOW,
    });
    const send = doc.send(
      new TransactWriteCommand({
        TransactItems: [
          put('mopm-t-namespaces', { namespace: 'a', github_id: '2' }, cond),
          put('mopm-t-namespaces', { namespace: 'b', github_id: '3' }, cond),
        ],
      }),
    );
    await expect(send).rejects.toMatchObject({
      name: 'TransactionCanceledException',
      CancellationReasons: [{ Code: 'None' }, { Code: 'ConditionalCheckFailed' }],
    });
    expect(doc.dump('namespaces').map((i) => i.namespace)).toEqual(['b']);
  });

  test('two items on one key are refused', async () => {
    const { TransactWriteCommand } = await import('@aws-sdk/lib-dynamodb');
    const doc = new FakeAuthDoc();
    await expect(
      doc.send(
        new TransactWriteCommand({
          TransactItems: [put('mopm-t-namespaces', { namespace: 'a', github_id: '2' }), put('mopm-t-namespaces', { namespace: 'a', github_id: '3' })],
        }),
      ),
    ).rejects.toMatchObject({ name: 'ValidationException' });
  });
});

describe('ensureUserNamespace: the user namespace made at login', () => {
  test('a free login becomes the account user namespace, created now', async () => {
    const s = new MemoryNamespaceStore();
    expect(await ensureUserNamespace(s, 4242, 'octo', NOW)).toEqual({
      status: 'created',
      namespace: 'octo',
    });
    expect(await s.getNamespace('octo')).toEqual(rec('octo', 4242));
  });

  test('the next login of the same account holds it: nothing changes, created_at stays', async () => {
    const s = new MemoryNamespaceStore();
    await ensureUserNamespace(s, 4242, 'octo', NOW);
    expect(await ensureUserNamespace(s, 4242, 'octo', '2026-10-20T00:00:00.000Z')).toEqual({ status: 'held', namespace: 'octo' });
    expect(await s.listNamespaces(4242)).toEqual([rec('octo', 4242)]);
  });

  test('the login is lower-cased: one spelling (GitHub logins ignore case)', async () => {
    const s = new MemoryNamespaceStore();
    expect(await ensureUserNamespace(s, 4242, 'Octo-Cat', NOW)).toEqual({
      status: 'created',
      namespace: 'octo-cat',
    });
    expect(await ensureUserNamespace(s, 4242, 'OCTO-CAT', NOW)).toEqual({
      status: 'held',
      namespace: 'octo-cat',
    });
    expect(await s.getNamespace('Octo-Cat')).toBeUndefined();
  });

  test('a renamed account keeps its old namespace and gains the new login as a second one', async () => {
    const s = new MemoryNamespaceStore();
    await ensureUserNamespace(s, 4242, 'octo', NOW);
    const later = '2026-11-01T00:00:00.000Z';
    expect(await ensureUserNamespace(s, 4242, 'octo-renamed', later)).toEqual({
      status: 'created',
      namespace: 'octo-renamed',
    });
    expect(await s.listNamespaces(4242)).toEqual([rec('octo', 4242), rec('octo-renamed', 4242, { created_at: later })]);
  });

  test('a new holder of an old login gets none: the string stays bound to the first id', async () => {
    const s = new MemoryNamespaceStore();
    await ensureUserNamespace(s, 4242, 'octo', NOW);
    expect(await ensureUserNamespace(s, 9, 'octo', NOW)).toEqual({
      status: 'taken',
      namespace: 'octo',
    });
    expect(await s.listNamespaces(9)).toEqual([]);
    expect(await s.getNamespace('octo')).toEqual(rec('octo', 4242));
  });

  test('a login equal to an organization namespace gets none', async () => {
    const s = new MemoryNamespaceStore();
    await s.createNamespace(rec('komira-ai', 77, { kind: 'org', created_by: 4242 }));
    expect(await ensureUserNamespace(s, 4242, 'komira-ai', NOW)).toEqual({
      status: 'taken',
      namespace: 'komira-ai',
    });
    expect(await s.getNamespace('komira-ai')).toEqual(rec('komira-ai', 77, { kind: 'org', created_by: 4242 }));
  });

  test.each([
    ['linux-64', 'reserved'],
    ['Native-Mirror', 'reserved'],
    ['index', 'reserved'],
    ['alice_corp', 'invalid'],
    ['trailing-', 'invalid'],
    ['x'.repeat(NAMESPACE_MAX_LENGTH + 1), 'invalid'],
  ])('%s gets none (%s), and the store is not asked', async (login, status) => {
    const asked: string[] = [];
    const s: NamespaceStore = {
      ...NO_MEMBERS,
      getNamespace: async (ns) => (asked.push(`get ${ns}`), undefined),
      createNamespace: async (r) => (asked.push(`create ${r.namespace}`), { created: true, record: r }),
      listNamespaces: async () => [],
    };
    expect(await ensureUserNamespace(s, 4242, login, NOW)).toEqual({
      status,
      namespace: login.toLowerCase(),
    });
    expect(asked).toEqual([]);
  });

  test.each([
    [4242, 'held'],
    [9, 'taken'],
  ] as const)('a create lost to a racing create of the same string: the winner (id %s) decides, as %s', async (winner, status) => {
    const s: NamespaceStore = {
      ...NO_MEMBERS,
      getNamespace: async () => undefined,
      createNamespace: async (r) => ({
        created: false,
        record: { ...r, github_id: winner },
      }),
      listNamespaces: async () => [],
    };
    expect(await ensureUserNamespace(s, 4242, 'octo', NOW)).toEqual({
      status,
      namespace: 'octo',
    });
  });

  test('a store failure is the login failing, never a silent none', async () => {
    const s: NamespaceStore = {
      ...NO_MEMBERS,
      getNamespace: async () => {
        throw new Error('store down');
      },
      createNamespace: async (r) => ({ created: true, record: r }),
      listNamespaces: async () => [],
    };
    await expect(ensureUserNamespace(s, 4242, 'octo', NOW)).rejects.toThrow('store down');
  });
});
