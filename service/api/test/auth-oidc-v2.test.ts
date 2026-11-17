import { Authenticator, AuthError, GithubJwtVerifier, MemoryAuthStore, MemoryNamespaceStore, NamespaceError, OidcExchange, type CiPublisher, type TrustedPublisher } from '../src/auth';
import { MAX_CI_PACKAGES } from '../src/auth/oidc';
import { errorViewV2 } from '../src/http/v2-catalogue';
import { MemoryStore } from '../src/memory-store';
import { goodClaims, newKey, signJwt, TestClock } from './auth-helpers';

// `POST /api/v2/auth/oidc/exchange` (OidcExchange.exchangeV2): the two forms with full names, matched to the publishers of the
// namespace. What these prove: the single form needs a publisher registered for the namespace (a trusted-publisher row keyed
// `<namespace>/`), the packages form a configured publisher of that namespace; both need the repository's owner to be the
// namespace's GitHub id; the token carries the namespace and the full names; nothing is created; the CI token is spent once and
// only after a match. What they do not: the HTTP routing (test/http) and real GitHub tokens.

const key = newKey('k1');
const OWNER_ID = 222; // the GitHub id of the account the namespace `komira-ai` is bound to, and the repository's owner in the claims
const CI_OWNER = 'gh-repo:111';
const WORKFLOW = '.github/workflows/release.yml';

const ROW: TrustedPublisher = {
  id: 'tp1',
  name: 'komira-ai/',
  repository_id: '111',
  repository_owner_id: String(OWNER_ID),
  workflow: WORKFLOW,
  added_by: 1,
  added_at: '2026-10-01T00:00:00Z',
};
const CONFIGURED: CiPublisher = {
  repository_id: '111',
  repository_owner_id: String(OWNER_ID),
  workflow: WORKFLOW,
  ref: 'refs/heads/main',
  job_workflow_ref: `acme/widgets/${WORKFLOW}@refs/heads/main`,
  events: ['push'],
  environment: 'prod',
  namespace: 'komira-ai',
};

async function setup(opts: { publishers?: readonly CiPublisher[]; withNamespaces?: boolean } = {}) {
  const clock = new TestClock();
  const store = new MemoryAuthStore();
  const namespaces = new MemoryNamespaceStore();
  const registry = new MemoryStore();
  const created = '2026-10-01T00:00:00Z';
  await namespaces.createNamespace({ namespace: 'komira-ai', kind: 'org', github_id: OWNER_ID, created_at: created });
  await namespaces.createNamespace({ namespace: 'acme-labs', kind: 'org', github_id: 333, created_at: created });
  await namespaces.createNamespace({ namespace: 'moved', kind: 'user', github_id: 999, created_at: created });
  const verifier = new GithubJwtVerifier({ audiences: ['mopm.dev'], now: clock.now, jwks: async () => ({ keys: [key.jwk] }) });
  const oidc = new OidcExchange({
    store,
    verifier,
    now: clock.now,
    registry,
    ...(opts.withNamespaces === false ? {} : { namespaces }),
    ciPublishers: opts.publishers ?? [CONFIGURED],
  });
  const jwt = (over: Record<string, unknown> = {}) =>
    signJwt(key, goodClaims(clock, { job_workflow_ref: `acme/widgets/${WORKFLOW}@refs/heads/main`, environment: 'prod', ...over }));
  return { clock, store, namespaces, registry, oidc, jwt, auth: new Authenticator({ store, now: clock.now }) };
}
type Rig = Awaited<ReturnType<typeof setup>>;

async function refused(p: Promise<unknown>, code: string, status: number): Promise<AuthError | NamespaceError> {
  try {
    await p;
  } catch (e) {
    expect(e).toEqual(expect.objectContaining({ code, status }));
    return e as AuthError | NamespaceError;
  }
  throw new Error(`expected ${code}, got success`);
}
const tokens = (s: Rig) => s.store.dumpTokens().filter((t) => t.kind === 'oidc');
const one = [{ name: 'komira-ai/json', version: '1.0.0' }];

describe('the single form: a publisher registered for the namespace', () => {
  test('a matching identity mints a ten minute token for exactly the full name and version, carrying the namespace', async () => {
    const s = await setup({ publishers: [] });
    await s.store.addTrustedPublisher(ROW);
    const r = (await s.oidc.exchangeV2({ jwt: s.jwt(), name: 'komira-ai/json', version: '1.0.0' })) as Record<string, string>;
    expect(r).toMatchObject({ token_kind: 'publish', name: 'komira-ai/json', version: '1.0.0', expires_at: new Date(s.clock.t + 10 * 60_000).toISOString() });
    expect(r.token).toMatch(/^mopm_[a-z2-7]{32,64}$/);
    const p = await s.auth.authenticate(`Bearer ${r.token}`);
    expect(p).toMatchObject({ kind: 'oidc', ci_namespace: 'komira-ai', ci_owner: CI_OWNER, packages: ['komira-ai/json'], version: '1.0.0' });
    expect(p.github_id).toBeUndefined();
    expect(p.versions).toBeUndefined();
    expect(tokens(s)[0]).toMatchObject({ issued_to: 'acme/widgets', scopes: ['publish'] });
    expect(JSON.stringify(s.store.dumpTokens())).not.toContain(r.token);
  });

  test('a stage purpose mints a stage token; any other purpose is invalid_request and spends nothing', async () => {
    const s = await setup({ publishers: [] });
    await s.store.addTrustedPublisher(ROW);
    const jwt = s.jwt();
    const e = await refused(s.oidc.exchangeV2({ jwt, name: 'komira-ai/json', version: '1.0.0', purpose: 'admin' }), 'invalid_request', 400);
    expect(e.detail.detail).toBe("'purpose' is publish or stage");
    const r = (await s.oidc.exchangeV2({ jwt, name: 'komira-ai/json', version: '1.0.0', purpose: 'stage' })) as { token_kind: string };
    expect(r.token_kind).toBe('stage');
    expect(tokens(s)[0]!.scopes).toEqual(['stage']);
  });

  test('it creates nothing: no package row and no audit row exist afterwards', async () => {
    const s = await setup({ publishers: [] });
    await s.store.addTrustedPublisher(ROW);
    await s.oidc.exchangeV2({ jwt: s.jwt(), name: 'komira-ai/json', version: '1.0.0' });
    expect(await s.registry.getPackage('komira-ai/json')).toBeUndefined();
    expect(await s.registry.listAudit('komira-ai/json')).toEqual([]);
  });

  test('a publisher of the namespace whose repository owner is not the namespace\'s GitHub id is not a match', async () => {
    const s = await setup({ publishers: [] });
    // `moved` is bound to account 999; the row and the claim both say owner 222, as they would after a transfer of the repository.
    await s.store.addTrustedPublisher({ ...ROW, name: 'moved/' });
    await refused(s.oidc.exchangeV2({ jwt: s.jwt(), name: 'moved/json', version: '1.0.0' }), 'oidc_not_trusted', 403);
    expect(tokens(s)).toEqual([]);
  });

  test('a row whose owner id differs from the namespace\'s, with a claim that agrees with the namespace, is not a match', async () => {
    const s = await setup({ publishers: [] });
    await s.store.addTrustedPublisher({ ...ROW, repository_owner_id: '777' });
    await refused(s.oidc.exchangeV2({ jwt: s.jwt(), name: 'komira-ai/json', version: '1.0.0' }), 'oidc_not_trusted', 403);
    await refused(s.oidc.exchangeV2({ jwt: s.jwt({ repository_owner_id: '777' }), name: 'komira-ai/json', version: '1.0.0' }), 'oidc_not_trusted', 403);
  });

  test('a publisher of another namespace, or a flat-name publisher of the same name part, is not a match; the refusal names the full name', async () => {
    const s = await setup({ publishers: [] });
    await s.store.addTrustedPublisher({ ...ROW, name: 'acme-labs/' });
    await s.store.addTrustedPublisher({ ...ROW, id: 'tp2', name: 'json' });
    const e = await refused(s.oidc.exchangeV2({ jwt: s.jwt(), name: 'komira-ai/json', version: '1.0.0' }), 'oidc_not_trusted', 403);
    expect(e.message).toBe("No trusted publisher of 'komira-ai/json' matches this CI identity.");
    expect(errorViewV2(e).body.error.code).toBe('oidc_not_trusted');
  });

  test('another workflow of the same repository is not a match', async () => {
    const s = await setup({ publishers: [] });
    await s.store.addTrustedPublisher(ROW);
    await refused(s.oidc.exchangeV2({ jwt: s.jwt({ workflow_ref: 'acme/widgets/.github/workflows/other.yml@refs/heads/main' }), name: 'komira-ai/json', version: '1.0.0' }), 'oidc_not_trusted', 403);
  });

  test('a registered publisher does not serve the packages form, and a configured one does not serve the single form', async () => {
    const s = await setup({ publishers: [] });
    await s.store.addTrustedPublisher(ROW);
    await refused(s.oidc.exchangeV2({ jwt: s.jwt(), packages: one }), 'oidc_not_trusted', 403);
    const t = await setup();
    await refused(t.oidc.exchangeV2({ jwt: t.jwt(), name: 'komira-ai/json', version: '1.0.0' }), 'oidc_not_trusted', 403);
  });

  test('a namespace nobody has is namespace_not_found (404), whatever the publishers', async () => {
    const s = await setup({ publishers: [] });
    await s.store.addTrustedPublisher({ ...ROW, name: 'ghost/' });
    const e = await refused(s.oidc.exchangeV2({ jwt: s.jwt(), name: 'ghost/json', version: '1.0.0' }), 'namespace_not_found', 404);
    expect(errorViewV2(e).body.error.message).toBe("There is no namespace 'ghost'.");
  });

  test('the CI token is spent by the first exchange only, and a refusal does not spend it', async () => {
    const s = await setup({ publishers: [] });
    const jwt = s.jwt();
    await refused(s.oidc.exchangeV2({ jwt, name: 'komira-ai/json', version: '1.0.0' }), 'oidc_not_trusted', 403);
    await s.store.addTrustedPublisher(ROW);
    await s.oidc.exchangeV2({ jwt, name: 'komira-ai/json', version: '1.0.0' });
    await refused(s.oidc.exchangeV2({ jwt, name: 'komira-ai/json', version: '1.0.0' }), 'oidc_token_invalid', 401);
    expect(tokens(s)).toHaveLength(1);
  });
});

describe('the packages form: a configured publisher of the namespace', () => {
  const set = [
    { name: 'komira-ai/json', version: '1.0.0' },
    { name: 'komira-ai/http', version: '2.1.0' },
  ];

  test('a matching identity mints a token good for exactly those full names at those versions, acting as the repository identity', async () => {
    const s = await setup();
    const r = (await s.oidc.exchangeV2({ jwt: s.jwt(), packages: set })) as Record<string, unknown>;
    expect(r).toMatchObject({ token_kind: 'publish', packages: set });
    const p = await s.auth.authenticate(`Bearer ${r.token}`);
    expect(p).toMatchObject({ kind: 'oidc', ci_namespace: 'komira-ai', ci_owner: CI_OWNER, packages: ['komira-ai/json', 'komira-ai/http'], versions: { 'komira-ai/json': '1.0.0', 'komira-ai/http': '2.1.0' } });
    expect(p.version).toBeUndefined();
    expect(() => s.auth.publishToken(p, 'komira-ai/json', '1.0.0')).not.toThrow();
    for (const [n, v] of [['komira-ai/json', '2.1.0'], ['komira-ai/other', '1.0.0']] as const) {
      expect(() => s.auth.publishToken(p, n, v)).toThrow(expect.objectContaining({ code: 'scope_missing' }));
    }
  });

  test('beside an acts_for row of the same repository (prod while a release moves into its namespace), in either order, the namespace row serves it', async () => {
    const { namespace: _n, ...rest } = CONFIGURED;
    const actsFor: CiPublisher = { ...rest, acts_for: '15257031' };
    for (const publishers of [[actsFor, CONFIGURED], [CONFIGURED, actsFor]]) {
      const s = await setup({ publishers });
      const r = (await s.oidc.exchangeV2({ jwt: s.jwt(), packages: set })) as Record<string, unknown>;
      const p = await s.auth.authenticate(`Bearer ${r.token}`);
      expect(p).toMatchObject({ kind: 'oidc', ci_namespace: 'komira-ai', ci_owner: CI_OWNER, packages: ['komira-ai/json', 'komira-ai/http'] });
      expect(p.github_id).toBeUndefined();
      expect(p.acts_via).toBeUndefined();
    }
  });

  test('an acts_for row alone does not serve the packages form of /api/v2: oidc_not_trusted', async () => {
    const { namespace: _n, ...rest } = CONFIGURED;
    const s = await setup({ publishers: [{ ...rest, acts_for: '15257031' }] });
    await refused(s.oidc.exchangeV2({ jwt: s.jwt(), packages: set }), 'oidc_not_trusted', 403);
    expect(tokens(s)).toEqual([]);
  });

  test('it creates no package, whether or not the names exist', async () => {
    const s = await setup();
    await s.oidc.exchangeV2({ jwt: s.jwt(), packages: set });
    for (const { name } of set) {
      expect(await s.registry.getPackage(name)).toBeUndefined();
      expect(await s.registry.listAudit(name)).toEqual([]);
    }
  });

  test('a stage purpose mints a stage token pinned like the publish one', async () => {
    const s = await setup();
    const r = (await s.oidc.exchangeV2({ jwt: s.jwt(), packages: one, purpose: 'stage' })) as { token_kind: string };
    expect(r.token_kind).toBe('stage');
    expect(tokens(s)[0]).toMatchObject({ scopes: ['stage'], versions: { 'komira-ai/json': '1.0.0' } });
  });

  test('a publisher whose owner id is not the namespace\'s GitHub id is not a match', async () => {
    const s = await setup({ publishers: [{ ...CONFIGURED, namespace: 'moved' }] });
    await refused(s.oidc.exchangeV2({ jwt: s.jwt(), packages: [{ name: 'moved/json', version: '1.0.0' }] }), 'oidc_not_trusted', 403);
    const t = await setup({ publishers: [{ ...CONFIGURED, repository_owner_id: '777' }] });
    await refused(t.oidc.exchangeV2({ jwt: t.jwt({ repository_owner_id: '777' }), packages: one }), 'oidc_not_trusted', 403);
    expect(tokens(s)).toEqual([]);
    expect(tokens(t)).toEqual([]);
  });

  test('a publisher of another namespace, one with no namespace, or none configured is not a match; the refusal names the first full name', async () => {
    for (const publishers of [[{ ...CONFIGURED, namespace: 'acme-labs' }], [{ ...CONFIGURED, namespace: undefined }], []] as CiPublisher[][]) {
      const s = await setup({ publishers });
      const e = await refused(s.oidc.exchangeV2({ jwt: s.jwt(), packages: [...set].reverse() }), 'oidc_not_trusted', 403);
      expect(e.detail.name).toBe('komira-ai/http');
    }
  });

  test('a configured publisher whose workflow or environment differs from the claim is not a match', async () => {
    const s = await setup();
    await refused(s.oidc.exchangeV2({ jwt: s.jwt({ environment: 'beta' }), packages: one }), 'oidc_not_trusted', 403);
    await refused(s.oidc.exchangeV2({ jwt: s.jwt({ event_name: 'pull_request' }), packages: one }), 'oidc_not_trusted', 403);
  });

  test('a namespace nobody has is namespace_not_found', async () => {
    const s = await setup({ publishers: [{ ...CONFIGURED, namespace: 'ghost' }] });
    await refused(s.oidc.exchangeV2({ jwt: s.jwt(), packages: [{ name: 'ghost/json', version: '1.0.0' }] }), 'namespace_not_found', 404);
  });

  test('names of two namespaces in one set are invalid_request, before the CI token is spent', async () => {
    const s = await setup();
    const jwt = s.jwt();
    const e = await refused(s.oidc.exchangeV2({ jwt, packages: [...one, { name: 'acme-labs/json', version: '1.0.0' }] }), 'invalid_request', 400);
    expect(e.detail.detail).toBe("'packages' names more than one namespace");
    await expect(s.oidc.exchangeV2({ jwt, packages: one })).resolves.toBeDefined();
  });

  test('the CI token is spent once: a second exchange with it is oidc_token_invalid', async () => {
    const s = await setup();
    const jwt = s.jwt();
    await s.oidc.exchangeV2({ jwt, packages: one });
    await refused(s.oidc.exchangeV2({ jwt, packages: one }), 'oidc_token_invalid', 401);
    expect(tokens(s)).toHaveLength(1);
  });
});

describe('the form of the request', () => {
  test('a flat name in v2 is invalid_name, in both forms, and so is a name whose namespace part is malformed', async () => {
    const s = await setup();
    for (const name of ['json', 'Komira-AI/json', 'komira-ai/Json', 'komira-ai/', '/json', 'komira-ai/a/b', 'komira--ai/json']) {
      const e = await refused(s.oidc.exchangeV2({ jwt: s.jwt(), name, version: '1.0.0' }), 'invalid_name', 400);
      expect(e.detail.name).toBe(name);
      await refused(s.oidc.exchangeV2({ jwt: s.jwt(), packages: [{ name, version: '1.0.0' }] }), 'invalid_name', 400);
    }
    await refused(s.oidc.exchangeV2({ jwt: s.jwt(), name: 7, version: '1.0.0' }), 'invalid_name', 400);
    await refused(s.oidc.exchangeV2({ jwt: s.jwt(), packages: [null] }), 'invalid_name', 400);
  });

  test('a full name in v1 is invalid_name, in both forms', async () => {
    const s = await setup();
    await refused(s.oidc.exchange({ jwt: s.jwt(), name: 'komira-ai/json', version: '1.0.0' }), 'invalid_name', 400);
    await refused(s.oidc.exchange({ jwt: s.jwt(), packages: one }), 'invalid_name', 400);
  });

  test('a version that is not one is invalid_version, in both forms', async () => {
    const s = await setup();
    await refused(s.oidc.exchangeV2({ jwt: s.jwt(), name: 'komira-ai/json', version: 'one' }), 'invalid_version', 400);
    await refused(s.oidc.exchangeV2({ jwt: s.jwt(), name: 'komira-ai/json' }), 'invalid_version', 400);
    await refused(s.oidc.exchangeV2({ jwt: s.jwt(), packages: [{ name: 'komira-ai/json', version: '1..0' }] }), 'invalid_version', 400);
  });

  test('packages: none, too many, not a list, a name twice, and both forms at once are invalid_request; nothing is spent', async () => {
    const s = await setup();
    const jwt = s.jwt();
    const many = Array.from({ length: MAX_CI_PACKAGES + 1 }, (_x, i) => ({ name: `komira-ai/pkg_${i}`, version: '1.0.0' }));
    await refused(s.oidc.exchangeV2({ jwt, packages: [] }), 'invalid_request', 400);
    await refused(s.oidc.exchangeV2({ jwt, packages: many }), 'invalid_request', 400);
    await refused(s.oidc.exchangeV2({ jwt, packages: null }), 'invalid_request', 400);
    await refused(s.oidc.exchangeV2({ jwt, packages: [...one, ...one] }), 'invalid_request', 400);
    await refused(s.oidc.exchangeV2({ jwt, packages: one, name: 'komira-ai/json', version: '1.0.0' }), 'invalid_request', 400);
    await refused(s.oidc.exchangeV2({ jwt, packages: one, version: '1.0.0' }), 'invalid_request', 400);
    await expect(s.oidc.exchangeV2({ jwt, packages: one })).resolves.toBeDefined();
  });

  test('the largest set is accepted', async () => {
    const s = await setup();
    const full = Array.from({ length: MAX_CI_PACKAGES }, (_x, i) => ({ name: `komira-ai/pkg_${i}`, version: '1.0.0' }));
    expect(((await s.oidc.exchangeV2({ jwt: s.jwt(), packages: full })) as { packages: unknown[] }).packages).toHaveLength(MAX_CI_PACKAGES);
  });

  test('a body that is not an object is invalid_name; a missing or non-string token is oidc_token_invalid', async () => {
    const s = await setup();
    await refused(s.oidc.exchangeV2(null), 'invalid_name', 400);
    await refused(s.oidc.exchangeV2('x'), 'invalid_name', 400);
    await refused(s.oidc.exchangeV2({ name: 'komira-ai/json', version: '1.0.0' }), 'oidc_token_invalid', 401);
    await refused(s.oidc.exchangeV2({ jwt: 7, name: 'komira-ai/json', version: '1.0.0' }), 'oidc_token_invalid', 401);
  });

  test('without a namespace store the exchange is unavailable (503)', async () => {
    const s = await setup({ withNamespaces: false });
    await refused(s.oidc.exchangeV2({ jwt: s.jwt(), name: 'komira-ai/json', version: '1.0.0' }), 'unavailable', 503);
  });
});
