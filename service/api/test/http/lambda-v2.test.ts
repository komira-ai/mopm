import { GitHubUnavailable, MemoryAuthStore, MemoryMembershipPassStore, MemoryNamespaceStore, NamespaceAccess, OrgMembership, type GitHubAppApi, type GitHubOrgMembershipOf } from '../../src/auth';
import { TokenServiceV2 } from '../../src/auth/tokens-v2';
import { appSecretName, SecretGitHubAppApi } from '../../src/http/app-secret';
import { configureV2, membershipFor, packagesInFrom } from '../../src/http/lambda';
import type { SecretReader } from '../../src/http/oauth-secret';
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

  test('with login wired, me and tokens are served; with the publish side, createPackage', () => {
    const v2 = configureV2('beta', doc, { MOPM_OAUTH_SECRET_NAME: 'mopm/beta/github-oauth' }, new MemoryStore(), access, creates);
    expect(v2.access).toBe(access);
    expect(v2.namespaces).toBeDefined();
    expect(v2.tokens).toBeInstanceOf(TokenServiceV2);
    expect(v2.creates).toBe(creates);
    // Without a membership check, createNamespace answers unavailable.
    expect(v2.membership).toBeUndefined();
  });

  test('without login, no tokens service; without the publish side, no createPackage', () => {
    const v2 = configureV2('prod', doc, {}, new MemoryStore(), access, undefined);
    expect(Object.keys(v2).sort()).toEqual(['access', 'namespaces']);
  });
});

// The GitHub App wiring: the secret's name is derived from the stage, and it is read on the first organization question.
describe('membershipFor and the GitHub App secret', () => {
  const doc = new FakeAuthDoc({});
  const { generateKeyPairSync } = require('node:crypto') as typeof import('node:crypto');
  const pem = generateKeyPairSync('rsa', { modulusLength: 2048 }).privateKey.export({ type: 'pkcs1', format: 'pem' }) as string;
  const good = JSON.stringify({ app_id: '12345', private_key: pem });
  const quiet = () => jest.spyOn(console, 'error').mockImplementation(() => undefined);
  afterEach(() => jest.restoreAllMocks());

  function reader(values: Array<string | undefined | Error>) {
    const calls: string[] = [];
    const read: SecretReader = async (id) => {
      calls.push(id);
      const v = values.length > 1 ? values.shift()! : values[0]!;
      if (v instanceof Error) throw v;
      return v;
    };
    return { read, calls };
  }
  const fakeApi = (): GitHubAppApi => ({
    getInstallation: async (id) => ({ id, account: { id: 7, login: 'komira-ai' }, suspended: false }),
    getOrgInstallation: async () => undefined,
    getUserById: async () => undefined,
    getOrgMembership: async () => undefined,
  });

  test('the secret name is derived from the stage, and building the check reads nothing', async () => {
    expect(appSecretName('beta')).toBe('mopm/beta/github-app');
    expect(appSecretName('prod')).toBe('mopm/prod/github-app');
    const r = reader([undefined]);
    quiet();
    const m = membershipFor('gamma', doc, r.read);
    expect(m).toBeInstanceOf(OrgMembership);
    expect(r.calls).toEqual([]);
    // The first organization question reads the stage's secret; absent, it is GitHub unavailable.
    await expect((m as unknown as { d: { app: GitHubAppApi } }).d.app.getOrgInstallation('komira-ai')).rejects.toBeInstanceOf(GitHubUnavailable);
    expect(r.calls).toEqual(['mopm/gamma/github-app']);
  });

  test('configureV2 carries the membership check it is given', () => {
    const access = new NamespaceAccess({ namespaces: new MemoryNamespaceStore(), users: new MemoryAuthStore() });
    const m = membershipFor('beta', doc, reader([good]).read);
    expect(m).toBeInstanceOf(OrgMembership);
    expect(configureV2('beta', doc, {}, new MemoryStore(), access, undefined, m).membership).toBe(m);
  });

  test('the secret is read once on first use, by its name, and the client is reused', async () => {
    const r = reader([good]);
    const built: Array<{ appId: string }> = [];
    const api = new SecretGitHubAppApi({ secretId: 'mopm/beta/github-app', read: r.read }, (c) => (built.push(c), fakeApi()));
    expect(r.calls).toEqual([]);
    expect((await api.getInstallation(5))?.id).toBe(5);
    expect(r.calls).toEqual(['mopm/beta/github-app']);
    expect(built).toEqual([{ appId: '12345', privateKey: pem }]);
  });

  test('each call is forwarded with its arguments to the client the secret built, and answers its result', async () => {
    const calls: unknown[][] = [];
    const installation = { id: 41, account: { id: 7, login: 'komira-ai' }, suspended: false };
    const orgInstallation = { id: 42, account: { id: 8, login: 'acme' }, suspended: true };
    const user = { id: 2, login: 'alice' };
    const membership: GitHubOrgMembershipOf = { user_id: 3, state: 'active', role: 'admin' };
    const api = new SecretGitHubAppApi({ secretId: 'mopm/beta/github-app', read: reader([good]).read }, () => ({
      getInstallation: async (...a) => (calls.push(['getInstallation', ...a]), installation),
      getOrgInstallation: async (...a) => (calls.push(['getOrgInstallation', ...a]), orgInstallation),
      getUserById: async (...a) => (calls.push(['getUserById', ...a]), user),
      getOrgMembership: async (...a) => (calls.push(['getOrgMembership', ...a]), membership),
    }));
    expect(await api.getInstallation(41)).toBe(installation);
    expect(await api.getOrgInstallation('acme')).toBe(orgInstallation);
    expect(await api.getUserById(42, 2)).toBe(user);
    expect(await api.getOrgMembership(42, 'acme', 'bob')).toBe(membership);
    expect(calls).toEqual([
      ['getInstallation', 41],
      ['getOrgInstallation', 'acme'],
      ['getUserById', 42, 2],
      ['getOrgMembership', 42, 'acme', 'bob'],
    ]);
  });

  test('the secret is read once for many calls', async () => {
    const r = reader([good]);
    const built: Array<{ appId: string }> = [];
    const api = new SecretGitHubAppApi({ secretId: 'mopm/beta/github-app', read: r.read }, (c) => (built.push(c), fakeApi()));
    await api.getInstallation(5);
    await api.getOrgInstallation('x');
    await api.getUserById(1, 2);
    await api.getOrgMembership(1, 'o', 'u');
    expect(r.calls).toEqual(['mopm/beta/github-app']);
    expect(built).toEqual([{ appId: '12345', privateKey: pem }]);
  });

  test('a number app_id is accepted and read again after the good-answer lifetime, keeping the client when unchanged', async () => {
    let t = 0;
    const r = reader([JSON.stringify({ app_id: 12345, private_key: pem })]);
    const built: unknown[] = [];
    const api = new SecretGitHubAppApi({ secretId: 's', read: r.read, now: () => t, okTtlMs: 1000 }, (c) => (built.push(c), fakeApi()));
    await api.getInstallation(1);
    t = 1001;
    await api.getInstallation(1);
    expect(r.calls).toHaveLength(2);
    expect(built).toHaveLength(1);
  });

  test('rotated credentials build a new client', async () => {
    let t = 0;
    const r = reader([good, JSON.stringify({ app_id: '999', private_key: pem })]);
    const built: Array<{ appId: string }> = [];
    const api = new SecretGitHubAppApi({ secretId: 's', read: r.read, now: () => t, okTtlMs: 1000 }, (c) => (built.push(c), fakeApi()));
    await api.getInstallation(1);
    t = 1001;
    await api.getInstallation(1);
    expect(built.map((b) => b.appId)).toEqual(['12345', '999']);
  });

  test.each([
    ['absent', undefined],
    ['not JSON', 'nope'],
    ['no app_id', JSON.stringify({ private_key: pem })],
    ['bad app_id', JSON.stringify({ app_id: 'abc', private_key: pem })],
    ['no private_key', JSON.stringify({ app_id: '1' })],
    ['private_key not a key', JSON.stringify({ app_id: '1', private_key: 'not a key' })],
    ['JSON null', 'null'],
  ])('a secret that is %s answers GitHubUnavailable, logs no value, and is asked again only after the failure lifetime', async (_n, value) => {
    const err = quiet();
    let t = 0;
    const r = reader([value]);
    const api = new SecretGitHubAppApi({ secretId: 's', read: r.read, now: () => t, failTtlMs: 100 }, fakeApi);
    await expect(api.getInstallation(1)).rejects.toBeInstanceOf(GitHubUnavailable);
    await expect(api.getOrgMembership(1, 'o', 'u')).rejects.toBeInstanceOf(GitHubUnavailable);
    expect(r.calls).toHaveLength(1);
    t = 101;
    await expect(api.getInstallation(1)).rejects.toBeInstanceOf(GitHubUnavailable);
    expect(r.calls).toHaveLength(2);
    expect(err.mock.calls.flat().join('\n')).not.toContain('BEGIN');
  });

  test('a read that rejects is GitHubUnavailable and the error is not echoed', async () => {
    const err = quiet();
    const api = new SecretGitHubAppApi({ secretId: 's', read: reader([Object.assign(new Error('secret-detail'), { name: 'AccessDenied' })]).read }, fakeApi);
    await expect(api.getInstallation(1)).rejects.toBeInstanceOf(GitHubUnavailable);
    const logged = err.mock.calls.flat().join('\n');
    expect(logged).toContain('AccessDenied');
    expect(logged).not.toContain('secret-detail');
  });

  test('with real credentials the default client is built, and its first call goes to GitHub through the injected fetch path only (no secret, no network here)', async () => {
    const api = new SecretGitHubAppApi({ secretId: 's', read: reader([good]).read });
    // The real client signs a JWT with the stored key, then calls GitHub; with fetch replaced it answers from the fake.
    const real = globalThis.fetch;
    globalThis.fetch = (async () => new Response(JSON.stringify({ id: 9, account: { id: 7, login: 'komira-ai' }, suspended_at: null }), { status: 200 })) as typeof fetch;
    try {
      expect((await api.getInstallation(9))?.id).toBe(9);
    } finally {
      globalThis.fetch = real;
    }
  });

  test('a read that rejects with something nameless is still GitHubUnavailable', async () => {
    quiet();
    const read: SecretReader = async () => { throw undefined; };
    await expect(new SecretGitHubAppApi({ secretId: 's', read }, fakeApi).getInstallation(1)).rejects.toBeInstanceOf(GitHubUnavailable);
  });

  test('an organization write with no usable secret answers unavailable, not a crash', async () => {
    quiet();
    const namespaces = new MemoryNamespaceStore();
    const users = new MemoryAuthStore();
    await namespaces.createNamespace({ namespace: 'komira-ai', kind: 'org', github_id: 7, installation_id: 3, created_at: at, created_by: 1 } as never);
    const m = new OrgMembership({ app: new SecretGitHubAppApi({ secretId: 's', read: reader([undefined]).read }), passes: new MemoryMembershipPassStore(), now: () => new Date(at) });
    const access = new NamespaceAccess({ namespaces, users, membership: m });
    await expect(access.require('komira-ai', 1)).rejects.toMatchObject({ code: 'unavailable' });
  });
});
