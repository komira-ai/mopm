import {
  AuthError,
  Authenticator,
  MemoryAuthStore,
  MemoryMembershipPassStore,
  MemoryNamespaceStore,
  HttpGitHubAppApi,
  NamespaceAccess,
  NamespaceError,
  OrgMembership,
  mintToken,
} from '../src/auth';
import type { AuthServices } from '../src/http/auth-routes';
import { route, type HttpResponse, type RouterDeps } from '../src/http/router';
import { MemoryStore } from '../src/memory-store';
import { TokenServiceV2 } from '../src/auth/tokens-v2';
import { TestClock } from './auth-helpers';
import { APP_ID, APP_PRIVATE_KEY, fakeGitHubApp } from './github-app-fake';

// GET /api/v2/me and POST /api/v2/me/tokens (src/auth/tokens-v2.ts): the namespaces an account can write in now and the
// full-name packages of an API token, directly and through route() with RouterDeps.v2 and RouterDeps.auth.

const ALICE = 4242;
const ORG_ID = 77;
const INST = 5555;

async function rig(opts: { app?: boolean } = {}) {
  const clock = new TestClock();
  const store = new MemoryAuthStore();
  const namespaces = new MemoryNamespaceStore();
  const gh = fakeGitHubApp(clock.now);
  gh.install(INST, { id: ORG_ID, login: 'komira-ai' }).user(ALICE, 'alice').member('komira-ai', 'alice', ALICE, 'admin');
  const app = new HttpGitHubAppApi({ appId: APP_ID, privateKey: APP_PRIVATE_KEY }, clock.now, gh.fetchFn);
  const membership = opts.app === false ? undefined : new OrgMembership({ app, passes: new MemoryMembershipPassStore(), now: clock.now });
  const access = new NamespaceAccess({ namespaces, users: store, membership });
  const packages: Record<string, string[]> = { alice: ['alice/zeta', 'alice/alpha'], 'komira-ai': ['komira-ai/json'] };
  const svc = new TokenServiceV2({ store, access, packagesIn: async (ns) => [...(packages[ns] ?? [])].sort(), now: clock.now });
  const at = clock.now().toISOString();
  await namespaces.createNamespace({ namespace: 'alice', kind: 'user', github_id: ALICE, created_at: at });
  await namespaces.createNamespace({ namespace: 'komira-ai', kind: 'org', github_id: ORG_ID, created_at: at, installation_id: INST });
  await store.upsertUser(ALICE, 'Alice', at, true, [{ github_id: ORG_ID, login: 'komira-ai', role: 'admin' }]);
  return { clock, store, namespaces, gh, access, svc, packages };
}

async function refusal(p: Promise<unknown>) {
  try {
    await p;
  } catch (e) {
    expect(e instanceof AuthError || e instanceof NamespaceError).toBe(true);
    const err = e as AuthError | NamespaceError;
    return { code: err.code, message: err.message, detail: err.detail };
  }
  throw new Error('expected a refusal');
}
const input = (over: Record<string, unknown> = {}) => ({ name: 'ci', scopes: ['publish'], packages: ['alice/alpha'], expires_in_days: 30, ...over });

describe('me', () => {
  test('a user namespace and an organization namespace the check passes: user first, each with its sorted packages and role', async () => {
    const r = await rig();
    expect(await r.svc.me(ALICE)).toEqual({
      github_id: ALICE,
      handle: 'Alice',
      namespaces: [
        { namespace: 'alice', kind: 'user', role: 'owner', packages: ['alice/alpha', 'alice/zeta'] },
        { namespace: 'komira-ai', kind: 'org', role: 'admin', packages: ['komira-ai/json'] },
      ],
    });
  });

  test('an organization the check refuses is left out', async () => {
    const r = await rig();
    r.gh.removeMember('komira-ai', 'alice');
    const me = await r.svc.me(ALICE);
    expect(me.namespaces.map((n) => n.namespace)).toEqual(['alice']);
  });

  test('GitHub unreachable during the organization check propagates as unavailable', async () => {
    const r = await rig();
    r.gh.state.faults.push({ path: /./, reject: true });
    expect((await refusal(r.svc.me(ALICE))).code).toBe('unavailable');
  });

  test('an account with no user namespace and a free login lists nothing and reports no unavailable_namespace', async () => {
    const r = await rig();
    await r.store.upsertUser(900, 'newcomer', r.clock.now().toISOString(), true);
    const me = await r.svc.me(900);
    expect(me).toEqual({ github_id: 900, handle: 'newcomer', namespaces: [] });
    expect('unavailable_namespace' in me).toBe(false);
  });

  test.each([
    ['reserved', 'Linux-64', 'linux-64'],
    ['out of the grammar', 'A_b', 'a_b'],
    ['held by another account', 'ALICE', 'alice'],
  ])('a login %s is reported as unavailable_namespace in lower case', async (_why, handle, ns) => {
    const r = await rig();
    await r.store.upsertUser(901, handle, r.clock.now().toISOString(), true);
    const me = await r.svc.me(901);
    expect(me.namespaces).toEqual([]);
    expect(me.unavailable_namespace).toBe(ns);
  });

  test('an account with no user row is token_unknown', async () => {
    const r = await rig();
    expect((await refusal(r.svc.me(1))).code).toBe('token_unknown');
  });

  test('without a GitHub App no organization is listed', async () => {
    const r = await rig({ app: false });
    expect((await r.svc.me(ALICE)).namespaces.map((n) => n.namespace)).toEqual(['alice']);
  });
});

describe('token creation', () => {
  test('packages are collapsed, sorted and stored as full names; the secret is returned once and only its hash is stored', async () => {
    const r = await rig();
    const t = await r.svc.create(ALICE, input({ scopes: ['yank', 'publish', 'publish'], packages: ['komira-ai/json', 'alice/alpha', 'alice/alpha'] }));
    expect(t.packages).toEqual(['alice/alpha', 'komira-ai/json']);
    expect(t.scopes).toEqual(['publish', 'yank']);
    expect(t.token).toMatch(/^mopm_[a-z2-7]{32,64}$/);
    expect(t.expires_at).toBe(new Date(r.clock.t + 30 * 86_400_000).toISOString());
    expect(t.last_used_at).toBeNull();
    const rows = r.store.dumpTokens();
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ kind: 'api', github_id: ALICE, all_current: false, packages: ['alice/alpha', 'komira-ai/json'] });
    expect(JSON.stringify(rows)).not.toContain(t.token);
  });

  test('a package that does not exist yet may be named when the namespace is writable', async () => {
    const r = await rig();
    const t = await r.svc.create(ALICE, input({ packages: ['alice/brand_new'] }));
    expect(t.packages).toEqual(['alice/brand_new']);
  });

  test('all_current is the packages of every namespace the caller can write now, sorted, flagged on the row', async () => {
    const r = await rig();
    const t = await r.svc.create(ALICE, input({ packages: 'all_current' }));
    expect(t.packages).toBe('all_current');
    expect(r.store.dumpTokens()[0]).toMatchObject({ all_current: true, packages: ['alice/alpha', 'alice/zeta', 'komira-ai/json'] });
  });

  test('all_current with no packages in any writable namespace is invalid_request', async () => {
    const r = await rig();
    r.packages.alice = [];
    r.packages['komira-ai'] = [];
    expect(await refusal(r.svc.create(ALICE, input({ packages: 'all_current' })))).toEqual({
      code: 'invalid_request',
      message: 'The request is not valid: you own no packages yet.',
      detail: { detail: 'you own no packages yet' },
    });
  });

  test('all_current for an account without a user row is token_unknown', async () => {
    const r = await rig();
    expect((await refusal(r.svc.create(1, input({ packages: 'all_current' })))).code).toBe('token_unknown');
  });

  test.each([
    ['a flat name', 'alpha'],
    ['a namespace out of the grammar', 'A/json'],
    ['a name out of the grammar', 'alice/1x'],
    ['an extra segment', 'alice/a/b'],
    ['a non-string', 7],
  ])('%s is invalid_name with the exact message', async (_why, p) => {
    const r = await rig();
    expect(await refusal(r.svc.create(ALICE, input({ packages: [p] })))).toEqual({
      code: 'invalid_name',
      message: `'${String(p)}' is not a valid package name.`,
      detail: { name: String(p) },
    });
  });

  test('a namespace the caller cannot write in propagates its NamespaceError and mints nothing', async () => {
    const r = await rig();
    await r.namespaces.createNamespace({ namespace: 'bob', kind: 'user', github_id: 2, created_at: r.clock.now().toISOString() });
    expect(await refusal(r.svc.create(ALICE, input({ packages: ['alice/alpha', 'bob/x1'] })))).toEqual({
      code: 'not_namespace_member',
      message: "You cannot write in 'bob'.",
      detail: { namespace: 'bob' },
    });
    expect((await refusal(r.svc.create(ALICE, input({ packages: ['nobody/x1'] })))).code).toBe('namespace_not_found');
    expect((await refusal(r.svc.create(ALICE, input({ packages: ['index/x1'] })))).code).toBe('namespace_reserved');
    expect(r.store.dumpTokens()).toEqual([]);
  });

  test.each([
    ['no object', undefined],
    ['an empty name', input({ name: '' })],
    ['a name of 81 characters', input({ name: 'n'.repeat(81) })],
    ['no scopes', input({ scopes: [] })],
    ['an unknown scope', input({ scopes: ['owners'] })],
    ['expires_in_days 0', input({ expires_in_days: 0 })],
    ['expires_in_days 91', input({ expires_in_days: 91 })],
    ['a fractional expires_in_days', input({ expires_in_days: 1.5 })],
    ['an empty package list', input({ packages: [] })],
    ['packages that is a string other than all_current', input({ packages: 'alice/alpha' })],
  ])('%s is invalid_request', async (_why, body) => {
    const r = await rig();
    expect((await refusal(r.svc.create(ALICE, body))).code).toBe('invalid_request');
  });

  test('the 51st live token is refused; a revoked or expired one does not count', async () => {
    const r = await rig();
    const stamp = r.clock.now().toISOString();
    const later = new Date(r.clock.t + 86_400_000).toISOString();
    const row = (over: Partial<Parameters<typeof mintToken>[1]> = {}) =>
      mintToken(r.store, { kind: 'api', github_id: ALICE, name: 't', scopes: ['publish'], packages: [], all_current: false, created_at: stamp, expires_at: later, ...over });
    for (let n = 0; n < 49; n++) await row();
    await row({ revoked_at: stamp });
    await row({ expires_at: stamp });
    await r.svc.create(ALICE, input());
    expect(await refusal(r.svc.create(ALICE, input()))).toEqual({
      code: 'invalid_request',
      message: 'The request is not valid: at most 50 live tokens per account.',
      detail: { detail: 'at most 50 live tokens per account' },
    });
  });

  test('without an injected clock the system time dates the token', async () => {
    const r = await rig();
    const svc = new TokenServiceV2({ store: r.store, access: r.access, packagesIn: async () => [] });
    const t = await svc.create(ALICE, input());
    expect(Date.parse(t.created_at)).not.toBeNaN();
  });
});

describe('through route()', () => {
  async function world() {
    const r = await rig();
    const authn = new Authenticator({ store: r.store, now: r.clock.now });
    const auth = { authn } as unknown as AuthServices;
    const deps: RouterDeps = {
      store: new MemoryStore(),
      stage: 'beta',
      version: 'v',
      commit: 'c',
      readOnly: false,
      auth,
      v2: { access: r.access, namespaces: r.namespaces, tokens: r.svc },
    };
    const send = async (method: string, path: string, token?: string, body?: unknown): Promise<{ res: HttpResponse; json: any }> => {
      const res = await route(
        { method, path: `/api/v2${path}`, query: {}, headers: token ? { authorization: `Bearer ${token}` } : {}, ...(body !== undefined ? { body: JSON.stringify(body) } : {}) },
        deps,
        'req-v2',
      );
      return { res, json: res.body ? JSON.parse(res.body) : undefined };
    };
    const session = async (freshMs: number) =>
      (
        await mintToken(r.store, {
          kind: 'session', github_id: ALICE, name: 'login', scopes: [], packages: [], all_current: false,
          fresh_until: new Date(r.clock.t + freshMs).toISOString(), created_at: r.clock.now().toISOString(), expires_at: new Date(r.clock.t + 86_400_000).toISOString(),
        })
      ).secret;
    return { ...r, send, session };
  }

  test('GET /me answers MeV2 for any live token', async () => {
    const w = await world();
    const { res, json } = await w.send('GET', '/me', await w.session(-1000));
    expect(res.statusCode).toBe(200);
    expect(json.namespaces.map((n: { namespace: string }) => n.namespace)).toEqual(['alice', 'komira-ai']);
  });

  test('GET /me without a token is token_missing', async () => {
    const w = await world();
    const { res, json } = await w.send('GET', '/me');
    expect([res.statusCode, json.error.code]).toEqual([401, 'token_missing']);
  });

  test('POST /me/tokens with a fresh session answers 201 with the secret and full names', async () => {
    const w = await world();
    const { res, json } = await w.send('POST', '/me/tokens', await w.session(60_000), input({ packages: ['komira-ai/json', 'alice/new_one'] }));
    expect(res.statusCode).toBe(201);
    expect(json.packages).toEqual(['alice/new_one', 'komira-ai/json']);
    expect(json.token).toMatch(/^mopm_/);
  });

  test('POST /me/tokens with a stale session is stale_session', async () => {
    const w = await world();
    const { res, json } = await w.send('POST', '/me/tokens', await w.session(-1000), input());
    expect([res.statusCode, json.error.code]).toEqual([401, 'stale_session']);
    expect(w.store.dumpTokens().filter((t) => t.kind === 'api')).toEqual([]);
  });

  test('POST /me/tokens naming a namespace the caller cannot write in renders the namespace error', async () => {
    const w = await world();
    const { res, json } = await w.send('POST', '/me/tokens', await w.session(60_000), input({ packages: ['nobody/x1'] }));
    expect([res.statusCode, json.error.code, json.error.message]).toEqual([404, 'namespace_not_found', "There is no namespace 'nobody'."]);
  });
});
