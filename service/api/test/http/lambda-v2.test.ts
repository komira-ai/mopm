import { NamespaceAccess, MemoryNamespaceStore, MemoryAuthStore } from '../../src/auth';
import { TokenServiceV2 } from '../../src/auth/tokens-v2';
import { configureV2, packagesInFrom } from '../../src/http/lambda';
import { MemoryStore } from '../../src/memory-store';
import { CreateService } from '../../src/publish/create';
import { FakeAuthDoc } from '../auth-fake-doc';

// The wiring of /api/v2 in the API Lambda: which services a stage's environment gives it, and the package list of a namespace.

const at = '2026-11-14T12:00:00Z';

describe('packagesInFrom', () => {
  test('lists every full name of the namespace, sorted, across pages of the name index, and nothing of another namespace or flat', async () => {
    const store = new MemoryStore();
    const names = Array.from({ length: 205 }, (_, i) => `komira-ai/p${String(i).padStart(3, '0')}`);
    for (const n of [...names].reverse()) await store.createPackage({ name: n, state: 'claimed', created_at: at });
    await store.createPackage({ name: 'komira-aix/p000', state: 'claimed', created_at: at });
    await store.createPackage({ name: 'komira', state: 'claimed', created_at: at });
    const calls: Array<string | undefined> = [];
    const spy = { searchPackages: (p: string, after: string | undefined, limit: number) => (calls.push(after), store.searchPackages(p, after, limit)) };
    expect(await packagesInFrom(spy)('komira-ai')).toEqual(names);
    // 100 + 100 + 5: the third read is short and ends the list.
    expect(calls).toEqual([undefined, 'komira-ai/p099', 'komira-ai/p199']);
  });

  test('a namespace with no package is an empty list after one read', async () => {
    expect(await packagesInFrom(new MemoryStore())('alice')).toEqual([]);
  });
});

describe('configureV2', () => {
  const doc = new FakeAuthDoc({});
  const access = new NamespaceAccess({ namespaces: new MemoryNamespaceStore(), users: new MemoryAuthStore() });
  const creates = {} as CreateService;

  test('with login wired, me and tokens are served; with the publish side, createPackage', () => {
    const v2 = configureV2('beta', doc, { MOPM_OAUTH_SECRET_NAME: 'mopm/beta/github-oauth' }, new MemoryStore(), access, creates);
    expect(v2.access).toBe(access);
    expect(v2.namespaces).toBeDefined();
    expect(v2.tokens).toBeInstanceOf(TokenServiceV2);
    expect(v2.creates).toBe(creates);
    // No GitHub App is configured on any stage yet: createNamespace answers unavailable.
    expect(v2.membership).toBeUndefined();
  });

  test('without login, no tokens service; without the publish side, no createPackage', () => {
    const v2 = configureV2('prod', doc, {}, new MemoryStore(), access, undefined);
    expect(Object.keys(v2).sort()).toEqual(['access', 'namespaces']);
  });
});
