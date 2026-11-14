import {
  authTablesFor,
  DynamoNamespaceStore,
  ensureUserNamespace,
  MemoryNamespaceStore,
  NAMESPACE_MAX_LENGTH,
  namespaceProblem,
  type NamespaceRecord,
  type NamespaceStore,
} from '../src/auth';
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
  ])('%s is reserved', (ns) => {
    expect(namespaceProblem(ns)).toBe('reserved');
  });
});

type Check = (s: NamespaceStore) => Promise<void>;

const CHECKS: Record<string, Check> = {
  'an absent namespace is undefined; a created one reads back exactly, installation id included': async (s) => {
    expect(await s.getNamespace('octo')).toBeUndefined();
    expect(await s.createNamespace(rec('octo', 4242))).toEqual({ created: true, record: rec('octo', 4242) });
    expect(await s.getNamespace('octo')).toEqual(rec('octo', 4242));
    const org = rec('komira-ai', 77, { kind: 'org', installation_id: 5555 });
    await s.createNamespace(org);
    expect(await s.getNamespace('komira-ai')).toEqual(org);
  },
  'create once: a second create of the string, by anyone, stores nothing and answers the holder': async (s) => {
    await s.createNamespace(rec('octo', 4242));
    expect(await s.createNamespace(rec('octo', 9, { created_at: '2026-10-15T00:00:00.000Z' }))).toEqual({ created: false, record: rec('octo', 4242) });
    expect(await s.createNamespace(rec('octo', 4242, { created_at: '2026-10-15T00:00:00.000Z' }))).toEqual({ created: false, record: rec('octo', 4242) });
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
};

const lambdaDoc = () => new FakeAuthDoc({ pageSize: 2, grants: LAMBDA_GRANTS });

describe.each<[string, () => NamespaceStore]>([
  ['memory', () => new MemoryNamespaceStore()],
  ['dynamodb (strict fake, Lambda grants)', () => new DynamoNamespaceStore(lambdaDoc(), authTablesFor('t').namespaces)],
])('NamespaceStore contract: %s', (_label, make) => {
  test.each(Object.entries(CHECKS))('%s', async (_name, check) => {
    await check(make());
  });
});

describe('the DynamoDB adapter', () => {
  test('a row keeps the id as a string index key with the number beside it, and nothing is ever deleted or updated', async () => {
    const doc = lambdaDoc();
    const s = new DynamoNamespaceStore(doc, 'mopm-t-namespaces');
    await s.createNamespace(rec('octo', 4242));
    await s.createNamespace(rec('octo', 9));
    expect(doc.dump('namespaces')).toEqual([{ namespace: 'octo', kind: 'user', github_id: '4242', github_id_num: 4242, created_at: NOW }]);
    expect(doc.commands.filter((c) => c !== 'GetCommand' && c !== 'PutCommand')).toEqual([]);
  });

  test('a refusal other than the condition is an error, not a holder (no permission: AccessDenied surfaces)', async () => {
    const doc = new FakeAuthDoc({ grants: { ...LAMBDA_GRANTS, namespaces: { actions: ['dynamodb:GetItem'] } } });
    const s = new DynamoNamespaceStore(doc, 'mopm-t-namespaces');
    await expect(s.createNamespace(rec('octo', 4242))).rejects.toMatchObject({ name: 'AccessDeniedException' });
    expect(doc.dump('namespaces')).toEqual([]);
  });

  test('without the index grant the list is AccessDenied: the role needs by_github_id by name', async () => {
    const doc = new FakeAuthDoc({ grants: { ...LAMBDA_GRANTS, namespaces: { actions: ['dynamodb:GetItem', 'dynamodb:PutItem', 'dynamodb:Query'] } } });
    await expect(new DynamoNamespaceStore(doc, 'mopm-t-namespaces').listNamespaces(4242)).rejects.toMatchObject({ name: 'AccessDeniedException' });
  });
});

describe('ensureUserNamespace: the user namespace made at login', () => {
  test('a free login becomes the account user namespace, created now', async () => {
    const s = new MemoryNamespaceStore();
    expect(await ensureUserNamespace(s, 4242, 'octo', NOW)).toEqual({ status: 'created', namespace: 'octo' });
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
    expect(await ensureUserNamespace(s, 4242, 'Octo-Cat', NOW)).toEqual({ status: 'created', namespace: 'octo-cat' });
    expect(await ensureUserNamespace(s, 4242, 'OCTO-CAT', NOW)).toEqual({ status: 'held', namespace: 'octo-cat' });
    expect(await s.getNamespace('Octo-Cat')).toBeUndefined();
  });

  test('a renamed account keeps its old namespace and gains the new login as a second one', async () => {
    const s = new MemoryNamespaceStore();
    await ensureUserNamespace(s, 4242, 'octo', NOW);
    const later = '2026-11-01T00:00:00.000Z';
    expect(await ensureUserNamespace(s, 4242, 'octo-renamed', later)).toEqual({ status: 'created', namespace: 'octo-renamed' });
    expect(await s.listNamespaces(4242)).toEqual([rec('octo', 4242), rec('octo-renamed', 4242, { created_at: later })]);
  });

  test('a new holder of an old login gets none: the string stays bound to the first id', async () => {
    const s = new MemoryNamespaceStore();
    await ensureUserNamespace(s, 4242, 'octo', NOW);
    expect(await ensureUserNamespace(s, 9, 'octo', NOW)).toEqual({ status: 'taken', namespace: 'octo' });
    expect(await s.listNamespaces(9)).toEqual([]);
    expect(await s.getNamespace('octo')).toEqual(rec('octo', 4242));
  });

  test('a login equal to an organization namespace gets none', async () => {
    const s = new MemoryNamespaceStore();
    await s.createNamespace(rec('komira-ai', 77, { kind: 'org', installation_id: 5555 }));
    expect(await ensureUserNamespace(s, 4242, 'komira-ai', NOW)).toEqual({ status: 'taken', namespace: 'komira-ai' });
    expect(await s.getNamespace('komira-ai')).toEqual(rec('komira-ai', 77, { kind: 'org', installation_id: 5555 }));
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
      getNamespace: async (ns) => (asked.push(`get ${ns}`), undefined),
      createNamespace: async (r) => (asked.push(`create ${r.namespace}`), { created: true, record: r }),
      listNamespaces: async () => [],
    };
    expect(await ensureUserNamespace(s, 4242, login, NOW)).toEqual({ status, namespace: login.toLowerCase() });
    expect(asked).toEqual([]);
  });

  test.each([
    [4242, 'held'],
    [9, 'taken'],
  ] as const)('a create lost to a racing create of the same string: the winner (id %s) decides, as %s', async (winner, status) => {
    const s: NamespaceStore = {
      getNamespace: async () => undefined,
      createNamespace: async (r) => ({ created: false, record: { ...r, github_id: winner } }),
      listNamespaces: async () => [],
    };
    expect(await ensureUserNamespace(s, 4242, 'octo', NOW)).toEqual({ status, namespace: 'octo' });
  });

  test('a store failure is the login failing, never a silent none', async () => {
    const s: NamespaceStore = {
      getNamespace: async () => {
        throw new Error('store down');
      },
      createNamespace: async (r) => ({ created: true, record: r }),
      listNamespaces: async () => [],
    };
    await expect(ensureUserNamespace(s, 4242, 'octo', NOW)).rejects.toThrow('store down');
  });
});
