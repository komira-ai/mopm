import { MemoryAuthStore, MemoryNamespaceStore, NamespaceAccess, OrgMembers } from '../../src/auth';
import { TokenServiceV2 } from '../../src/auth/tokens-v2';
import { configureV2, packagesInFrom } from '../../src/http/lambda';
import { MemoryStore } from '../../src/memory-store';
import { CreateService } from '../../src/publish/create';
import { publishApiFor } from '../../src/publish/wiring';
import { FakeAuthDoc } from '../auth-fake-doc';
import { MutableFlags } from '../publish/harness';

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

describe('publishApiFor', () => {
  const queue = (n: string) => `https://sqs.us-east-1.amazonaws.com/acct/${n}.fifo`;
  const required = { MOPM_CHANNEL_BUCKET: 'bucket', MOPM_VALIDATE_QUEUE_URL: queue('validate') };
  const held = (svc: unknown) => (svc as { d: Record<string, unknown> }).d;
  const access = new NamespaceAccess({ namespaces: new MemoryNamespaceStore(), users: new MemoryAuthStore() });
  const doc = () => new FakeAuthDoc({}) as never;

  test('the index queue and the group queue are given to the services when their urls are set, and not otherwise', () => {
    const without = publishApiFor(required, doc(), 't', new MutableFlags(), access)!;
    expect(held(without.service).indexQueue).toBeUndefined();
    expect(held(without.groups).groupQueue).toBeUndefined();
    const both = publishApiFor({ ...required, MOPM_INDEX_QUEUE_URL: queue('index'), MOPM_GROUP_QUEUE_URL: queue('group') }, doc(), 't', new MutableFlags(), access)!;
    expect(held(both.service).indexQueue).toBeDefined();
    expect(held(both.groups).groupQueue).toBeDefined();
  });

  test('createPackage is wired only with the namespace access, which the publish and group services also receive', () => {
    const wired = publishApiFor(required, doc(), 't', new MutableFlags(), access)!;
    expect(wired.creates).toBeInstanceOf(CreateService);
    expect(held(wired.service).namespaces).toBe(access);
    expect(held(wired.groups).namespaces).toBe(access);
    const bare = publishApiFor(required, doc(), 't', new MutableFlags())!;
    expect(bare.creates).toBeUndefined();
    expect(held(bare.service).namespaces).toBeUndefined();
  });

  test('without the upload bucket and queue there is no publish side', () => {
    expect(publishApiFor({}, doc(), 't', new MutableFlags(), access)).toBeUndefined();
  });
});

describe('configureV2', () => {
  const doc = new FakeAuthDoc({});
  const access = new NamespaceAccess({ namespaces: new MemoryNamespaceStore(), users: new MemoryAuthStore() });
  const creates = {} as CreateService;

  test('with login wired, me and tokens are served; with the publish side, createPackage; the members of a namespace are always served', () => {
    const v2 = configureV2('beta', doc, { MOPM_OAUTH_SECRET_NAME: 'mopm/beta/github-oauth' }, new MemoryStore(), access, creates);
    expect(v2.access).toBe(access);
    expect(v2.namespaces).toBeDefined();
    expect(v2.tokens).toBeInstanceOf(TokenServiceV2);
    expect(v2.creates).toBe(creates);
    expect(v2.members).toBeInstanceOf(OrgMembers);
  });

  test('without login, no tokens service; without the publish side, no createPackage', () => {
    const v2 = configureV2('prod', doc, {}, new MemoryStore(), access, undefined);
    expect(Object.keys(v2).sort()).toEqual(['access', 'members', 'namespaces']);
  });

  test('the member table of the stage is the one the namespace store reads: a member row of mopm-<stage>-namespace_members is a member', async () => {
    const d = new FakeAuthDoc({});
    d.seed('namespaces', { namespace: 'komira-ai', kind: 'org', github_id: '77', github_id_num: 77, created_at: at, members_rev: 1 });
    d.seed('namespace_members', { namespace: 'komira-ai', member: '5', github_id: 5, role: 'member', added_by: 1, added_at: at });
    const v2 = configureV2('t' as never, d as never, {}, new MemoryStore(), access, undefined);
    expect(await v2.namespaces.getMember('komira-ai', 5)).toMatchObject({ role: 'member' });
  });
});
