import { Authenticator, AuthError, GithubJwtVerifier, mintToken, OidcExchange, type CiPublisher } from '../../src/auth';
import type { AuthServices } from '../../src/http/auth-routes';
import { route } from '../../src/http/router';
import { RegistryError } from '../../src/errors';
import { goodClaims, newKey, signJwt } from '../auth-helpers';
import { Harness, pkg } from './harness';

// A CI identity the deployment trusts by configuration (beta only) publishes through the whole pipeline: exchange,
// package creation, the publish routes, ownership. What these prove: the trusted repository's token creates and owns
// a package and publishes it; every other identity, owner and scope is refused; the ownership check for a CI token
// reads the package's ci_owner (and cannot be bypassed). What they do not: real GitHub tokens, DynamoDB, API Gateway
// (service/infra/stacks pins the beta-only variable and grant).

const key = newKey('k1');
const OWNER = 'gh-repo:1376408823';
const PUBLISHER: CiPublisher = {
  repository_id: '1376408823',
  repository_owner_id: '305577347',
  workflow: '.github/workflows/release.yml',
  ref: 'refs/heads/main',
  job_workflow_ref: 'komira-ai/komira/.github/workflows/release.yml@refs/heads/main',
  events: ['push'],
  environment: 'beta',
};

/** `null`: a deployment with no CI publisher configured at all (every stage but beta). */
function setup(publishers: readonly CiPublisher[] | null = [PUBLISHER]) {
  const h = new Harness();
  const verifier = new GithubJwtVerifier({ audiences: ['beta.mopm.dev'], now: h.clock.now, jwks: async () => ({ keys: [key.jwk] }) });
  const oidc = new OidcExchange({ store: h.authStore, verifier, now: h.clock.now, ...(publishers ? { ciPublishers: publishers, registry: h.registry } : {}) });
  /** What GitHub issues to the komira release workflow on main, in the beta environment, for a push. */
  const jwt = (over: Record<string, unknown> = {}) =>
    signJwt(
      key,
      goodClaims(h.clock, {
        aud: 'beta.mopm.dev',
        repository: 'komira-ai/komira',
        repository_id: '1376408823',
        repository_owner_id: '305577347',
        workflow_ref: 'komira-ai/komira/.github/workflows/release.yml@refs/heads/main',
        job_workflow_ref: 'komira-ai/komira/.github/workflows/release.yml@refs/heads/main',
        environment: 'beta',
        ...over,
      }),
    );
  return { h, oidc, jwt, auth: new Authenticator({ store: h.authStore, now: h.clock.now }) };
}
type Setup = ReturnType<typeof setup>;

const widgets = [{ name: 'widgets', version: '1.0.0' }];

async function refused(p: Promise<unknown>, code: string, status: number) {
  try {
    await p;
  } catch (e) {
    expect(e).toBeInstanceOf(AuthError);
    expect({ code: (e as AuthError).code, status: (e as AuthError).status }).toEqual({ code, status });
    return;
  }
  throw new Error(`expected ${code}, got success`);
}
const errCode = (r: { body: string }) => JSON.parse(r.body).error.code as string;
const ciTokens = (s: Setup) => s.h.authStore.dumpTokens().filter((t) => t.kind === 'oidc');

describe('the trusted repository publishes a new package on beta and owns it', () => {
  test('the exchange creates the package claimed, owned by the repository identity (no account owner), and the token publishes it end to end', async () => {
    const s = setup();
    const r = await s.oidc.exchange({ jwt: s.jwt(), packages: widgets });
    expect(r.packages).toEqual(widgets);
    expect(r.token_kind).toBe('publish');
    expect(r.expires_at).toBe(new Date(s.h.clock.t + 10 * 60_000).toISOString());

    const rec = await s.h.registry.getPackage('widgets');
    expect(rec).toMatchObject({ name: 'widgets', state: 'claimed', ci_owner: OWNER });
    expect(await s.h.registry.listOwners('widgets')).toEqual([]);
    expect((await s.h.registry.listAudit('widgets')).map((a) => [a.actor, a.action])).toEqual([[OWNER, 'ci_claim']]);

    const p = pkg({ name: 'widgets', version: '1.0.0' });
    const id = await s.h.publish(r.token, p);
    await s.h.runValidator();
    await s.h.runIndexer();
    expect((await s.h.status(r.token, id)).body.status).toBe('published');
    expect((await s.h.registry.getVersion('widgets', '1.0.0'))?.published_by).toBe(OWNER);
  });

  test('the package is active after its first published version, and the read API names no owner and leaks no ci_owner', async () => {
    const s = setup();
    const r = await s.oidc.exchange({ jwt: s.jwt(), packages: widgets });
    const p = pkg({ name: 'widgets', version: '1.0.0' });
    await s.h.publish(r.token, p);
    expect((await s.h.registry.getPackage('widgets'))?.state).toBe('claimed'); // nothing is published yet
    await s.h.runValidator();
    expect(await s.h.registry.getPackage('widgets')).toMatchObject({ state: 'active', ci_owner: OWNER });
    const info = JSON.parse((await s.h.call('GET', '/api/v1/packages/widgets')).body);
    expect(info).toMatchObject({ name: 'widgets', state: 'active', owners: [], latest: '1.0.0' });
    expect(JSON.stringify(info)).not.toContain('ci_owner');
    expect(JSON.stringify(info)).not.toContain(OWNER);
  });

  test('a later run of the same repository publishes the next version to the package it owns; the package is not created twice', async () => {
    const s = setup();
    await s.oidc.exchange({ jwt: s.jwt(), packages: widgets });
    const again = await s.oidc.exchange({ jwt: s.jwt(), packages: [{ name: 'widgets', version: '1.0.1' }] });
    expect((await s.h.registry.listAudit('widgets')).filter((a) => a.action === 'ci_claim')).toHaveLength(1);
    const u = await s.h.upload(again.token, pkg({ name: 'widgets', version: '1.0.1' }));
    expect(u.res.statusCode).toBe(200);
  });

  test('one exchange covers several packages, each at its own version, and nothing else', async () => {
    const s = setup();
    const r = await s.oidc.exchange({ jwt: s.jwt(), packages: [...widgets, { name: 'gadgets', version: '2.0.0' }] });
    const principal = await s.auth.authenticate(`Bearer ${r.token}`);
    expect(principal).toMatchObject({ kind: 'oidc', ci_owner: OWNER, packages: ['widgets', 'gadgets'], versions: { widgets: '1.0.0', gadgets: '2.0.0' } });
    expect(() => s.auth.publishToken(principal, 'widgets', '1.0.0')).not.toThrow();
    expect(() => s.auth.publishToken(principal, 'gadgets', '2.0.0')).not.toThrow();
    for (const [n, v] of [['widgets', '2.0.0'], ['gadgets', '1.0.0'], ['widgets', '1.0.1'], ['other', '1.0.0']] as const) {
      expect(() => s.auth.publishToken(principal, n, v)).toThrow(expect.objectContaining({ code: 'scope_missing', status: 403 }));
    }
    expect(() => s.auth.yankToken(principal, 'widgets')).toThrow(expect.objectContaining({ code: 'scope_missing' }));
    expect(() => s.auth.userToken(principal)).toThrow(expect.objectContaining({ code: 'scope_missing' }));
  });

  test('the token lives ten minutes: valid at 9:59, expired at 10:00', async () => {
    const s = setup();
    const r = await s.oidc.exchange({ jwt: s.jwt(), packages: widgets });
    s.h.clock.advance(10 * 60_000 - 1000);
    await s.auth.authenticate(`Bearer ${r.token}`);
    s.h.clock.advance(1000);
    await expect(s.auth.authenticate(`Bearer ${r.token}`)).rejects.toMatchObject({ code: 'token_expired' });
  });

  test('a token is exchanged once: the second exchange of the same CI token is oidc_token_invalid and creates nothing more', async () => {
    const s = setup();
    const jwt = s.jwt();
    await s.oidc.exchange({ jwt, packages: widgets });
    await refused(s.oidc.exchange({ jwt, packages: [{ name: 'gadgets', version: '1.0.0' }] }), 'oidc_token_invalid', 401);
    expect(await s.h.registry.getPackage('gadgets')).toBeUndefined();
  });

  test('through the router: POST /auth/oidc/exchange with packages answers 200 with the packages and a publish token', async () => {
    const s = setup();
    const auth = { authn: s.auth, oidc: s.oidc } as unknown as AuthServices;
    const res = await route(
      { method: 'POST', path: '/api/v1/auth/oidc/exchange', query: {}, headers: {}, body: JSON.stringify({ jwt: s.jwt(), packages: widgets }) },
      { store: s.h.registry, stage: 'beta', version: 't', commit: 't', readOnly: false, auth },
      'req-x',
    );
    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.body)).toMatchObject({ token_kind: 'publish', packages: widgets });
    const bad = await route(
      { method: 'POST', path: '/api/v1/auth/oidc/exchange', query: {}, headers: {}, body: JSON.stringify({ jwt: s.jwt(), packages: widgets, name: 'widgets', version: '1.0.0' }) },
      { store: s.h.registry, stage: 'beta', version: 't', commit: 't', readOnly: false, auth },
      'req-y',
    );
    expect([bad.statusCode, errCode(bad)]).toEqual([400, 'invalid_request']);
  });
});

describe('names that belong to someone else are refused', () => {
  test('a user-owned name: not_owner (403); nothing is created, no token is minted, and the CI token is not spent', async () => {
    const s = setup();
    await s.h.account(1, 'someone', ['demo']);
    const jwt = s.jwt();
    await refused(s.oidc.exchange({ jwt, packages: [{ name: 'demo', version: '1.0.0' }, ...widgets] }), 'not_owner', 403);
    expect(await s.h.registry.getPackage('widgets')).toBeUndefined(); // the free name in the same request is not created either
    expect((await s.h.registry.getPackage('demo'))?.ci_owner).toBeUndefined();
    expect(ciTokens(s)).toEqual([]);
    await expect(s.oidc.exchange({ jwt, packages: widgets })).resolves.toBeDefined(); // the same CI token still works for a name that is free
  });

  test('a name owned by another CI identity: not_owner', async () => {
    const s = setup();
    await s.h.registry.createPackage({ name: 'widgets', state: 'claimed', created_at: '2026-10-01T00:00:00Z', ci_owner: 'gh-repo:999' });
    await refused(s.oidc.exchange({ jwt: s.jwt(), packages: widgets }), 'not_owner', 403);
    expect((await s.h.registry.getPackage('widgets'))?.ci_owner).toBe('gh-repo:999');
    expect(ciTokens(s)).toEqual([]);
  });

  test('a name created by someone between the read and the write is theirs: refused; created by this identity meanwhile: carried on', async () => {
    for (const [existingOwner, outcome] of [['gh-repo:999', 'refused'], [OWNER, 'ok']] as const) {
      const s = setup();
      await s.h.registry.createPackage({ name: 'widgets', state: 'claimed', created_at: '2026-10-01T00:00:00Z', ci_owner: existingOwner });
      // the first read does not see the package (it is created "meanwhile"); createPackage then loses with name_taken
      jest.spyOn(s.h.registry, 'getPackage').mockImplementationOnce(async () => undefined);
      const run = s.oidc.exchange({ jwt: s.jwt(), packages: widgets });
      if (outcome === 'refused') await refused(run, 'not_owner', 403);
      else await expect(run).resolves.toBeDefined();
    }
  });

  test('another error from the registry while creating is not swallowed', async () => {
    const s = setup();
    jest.spyOn(s.h.registry, 'createPackage').mockRejectedValueOnce(new RegistryError('unavailable', 'down'));
    await expect(s.oidc.exchange({ jwt: s.jwt(), packages: widgets })).rejects.toMatchObject({ code: 'unavailable' });
  });
});

describe('only the configured identity is trusted, field by field', () => {
  const cases: Array<[string, Record<string, unknown>]> = [
    ['another repository_id', { repository_id: '1376408824' }],
    ['another repository_owner_id', { repository_owner_id: '305577348' }],
    ['another workflow file', { workflow_ref: 'komira-ai/komira/.github/workflows/other.yml@refs/heads/main' }],
    ['a workflow of another repository with the right file name', { workflow_ref: 'evil/fork/.github/workflows/release.yml@refs/heads/main' }],
    // workflow_ref, ref, environment and event all look right; only job_workflow_ref differs
    ['a job of another file (a reusable workflow called from release.yml)', { job_workflow_ref: 'komira-ai/komira/.github/workflows/other.yml@refs/heads/main' }],
    ['a job of release.yml at another ref', { job_workflow_ref: 'komira-ai/komira/.github/workflows/release.yml@refs/heads/feature' }],
    ['a job of release.yml at a tag', { job_workflow_ref: 'komira-ai/komira/.github/workflows/release.yml@refs/tags/v1' }],
    ['a job of release.yml in another repository', { job_workflow_ref: 'evil/fork/.github/workflows/release.yml@refs/heads/main' }],
    ['no job_workflow_ref claim', { job_workflow_ref: undefined }],
    // the reverse reusable case: another workflow of the repository calls release.yml, so job_workflow_ref is right and workflow_ref is the caller
    ['release.yml called by another workflow', { workflow_ref: 'komira-ai/komira/.github/workflows/caller.yml@refs/heads/main' }],
    ['a manual run (workflow_dispatch)', { event_name: 'workflow_dispatch' }],
    ['a feature branch', { ref: 'refs/heads/feature' }],
    ['a tag', { ref: 'refs/tags/v1' }],
    ['a pull request merge ref', { ref: 'refs/pull/7/merge' }],
    ['another environment', { environment: 'build' }],
    ['no environment', { environment: undefined }],
    ['a pull_request event', { event_name: 'pull_request' }],
    ['a schedule event', { event_name: 'schedule' }],
  ];
  test.each(cases)('%s: oidc_not_trusted (403); nothing is created and no token is minted', async (_n, over) => {
    const s = setup();
    await refused(s.oidc.exchange({ jwt: s.jwt(over), packages: widgets }), 'oidc_not_trusted', 403);
    expect(await s.h.registry.getPackage('widgets')).toBeUndefined();
    expect(ciTokens(s)).toEqual([]);
  });

  test('the good push identity passes', async () => {
    const s = setup();
    await expect(s.oidc.exchange({ jwt: s.jwt(), packages: widgets })).resolves.toBeDefined();
  });

  test('a publisher that names one event refuses the other (the rule is per row, not hard-wired to push)', async () => {
    const s = setup([{ ...PUBLISHER, events: ['workflow_dispatch'] }]);
    await refused(s.oidc.exchange({ jwt: s.jwt({ event_name: 'push' }), packages: widgets }), 'oidc_not_trusted', 403);
    await expect(s.oidc.exchange({ jwt: s.jwt({ event_name: 'workflow_dispatch' }), packages: widgets })).resolves.toBeDefined();
  });

  test('the beta audience only: another stage host and the bare domain are oidc_token_invalid', async () => {
    const s = setup();
    for (const aud of ['mopm.dev', 'gamma.mopm.dev']) {
      await refused(s.oidc.exchange({ jwt: s.jwt({ aud }), packages: widgets }), 'oidc_token_invalid', 401);
    }
  });

  test('a deployment with no configured publisher (every stage but beta) refuses the packages form, whoever asks', async () => {
    for (const s of [setup(null), setup([])]) {
      await refused(s.oidc.exchange({ jwt: s.jwt(), packages: widgets }), 'oidc_not_trusted', 403);
      expect(await s.h.registry.getPackage('widgets')).toBeUndefined();
    }
  });

  test('the form of the request is checked: nothing, too many, duplicates, bad names and versions, both forms at once', async () => {
    const s = setup();
    const many = Array.from({ length: 101 }, (_x, i) => ({ name: `pkg_${i}`, version: '1.0.0' }));
    const jwt = s.jwt();
    await refused(s.oidc.exchange({ jwt, packages: [] }), 'invalid_request', 400);
    await refused(s.oidc.exchange({ jwt, packages: many }), 'invalid_request', 400);
    await refused(s.oidc.exchange({ jwt, packages: null as never }), 'invalid_request', 400);
    await refused(s.oidc.exchange({ jwt, packages: [...widgets, ...widgets] }), 'invalid_request', 400);
    await refused(s.oidc.exchange({ jwt, packages: [{ name: 'Bad-Name', version: '1.0.0' }] }), 'invalid_name', 400);
    await refused(s.oidc.exchange({ jwt, packages: [null as never] }), 'invalid_name', 400);
    await refused(s.oidc.exchange({ jwt, packages: [{ name: 'widgets', version: 'one' }] }), 'invalid_version', 400);
    await refused(s.oidc.exchange({ jwt, packages: widgets, name: 'widgets', version: '1.0.0' } as never), 'invalid_request', 400);
    expect(await s.h.registry.getPackage('widgets')).toBeUndefined();
    // none of these spent the token
    await expect(s.oidc.exchange({ jwt, packages: widgets })).resolves.toBeDefined();
  });
});

describe('the token cannot touch what is outside its scope', () => {
  test('another package, or another version of its own, is scope_missing on begin-upload', async () => {
    const s = setup();
    await s.h.registry.createPackage({ name: 'gadgets', state: 'claimed', created_at: 't', ci_owner: OWNER }); // also this identity's, but not in this token
    const r = await s.oidc.exchange({ jwt: s.jwt(), packages: widgets });
    const other = pkg({ name: 'gadgets', version: '1.0.0' });
    expect(errCode((await s.h.upload(r.token, other)).res)).toBe('scope_missing');
    const wrongVersion = pkg({ name: 'widgets', version: '1.0.1' });
    expect(errCode((await s.h.upload(r.token, wrongVersion)).res)).toBe('scope_missing');
    expect((await s.h.upload(r.token, pkg({ name: 'widgets', version: '1.0.0' }))).res.statusCode).toBe(200);
  });

  test('its publish is read by its own identity\'s tokens and by no other identity, and it yanks only the exact package and version it was minted for', async () => {
    const s = setup();
    const r = await s.oidc.exchange({ jwt: s.jwt(), packages: widgets });
    const sameIdentity = await s.oidc.exchange({ jwt: s.jwt(), packages: [{ name: 'gadgets', version: '1.0.0' }] });
    const t = s.h.clock.now();
    const otherIdentity = await mintToken(s.h.authStore, {
      kind: 'oidc',
      name: 'ci',
      scopes: ['publish'],
      packages: ['gadgets'],
      all_current: false,
      versions: { gadgets: '1.0.0' },
      ci_owner: 'gh-repo:999',
      created_at: t.toISOString(),
      expires_at: new Date(t.getTime() + 600_000).toISOString(),
    });
    const id = await s.h.publish(r.token, pkg({ name: 'widgets', version: '1.0.0' }));
    await s.h.runValidator();
    await s.h.runIndexer();
    // one actor per identity: a later job's token reads the publish an earlier job's token started; another identity does not
    expect((await s.h.call('GET', `/api/v1/publishes/${id}`, sameIdentity.token)).statusCode).toBe(200);
    expect((await s.h.call('GET', `/api/v1/publishes/${id}`, otherIdentity.secret)).statusCode).toBe(404);
    const yank = await s.h.call('PUT', '/api/v1/packages/widgets/1.0.0/yank', r.token, { yanked: true, reason: 'x' });
    expect(yank.statusCode).toBe(200); // the spec lets a CI token yank the exact version it publishes
    const yankOther = await s.h.call('PUT', '/api/v1/packages/gadgets/1.0.0/yank', r.token, { yanked: true, reason: 'x' });
    expect(errCode(yankOther)).toBe('scope_missing');
  });
});

describe('the ownership check for a CI token cannot be bypassed', () => {
  const ciToken = (s: Setup, over: { ci_owner?: string; packages: string[]; versions?: Record<string, string>; version?: string }) => {
    const t = s.h.clock.now();
    return mintToken(s.h.authStore, {
      kind: 'oidc',
      name: 'ci',
      scopes: ['publish'],
      all_current: false,
      created_at: t.toISOString(),
      expires_at: new Date(t.getTime() + 600_000).toISOString(),
      ...over,
    }).then((m) => m.secret);
  };
  const begin = async (s: Setup, token: string, name: string) => (await s.h.upload(token, pkg({ name, version: '1.0.0' }))).res;

  test('a token of one repository identity on a package of another identity: not_owner, though scope allows the name', async () => {
    const s = setup();
    await s.h.registry.createPackage({ name: 'widgets', state: 'claimed', created_at: 't', ci_owner: 'gh-repo:999' });
    const token = await ciToken(s, { ci_owner: OWNER, packages: ['widgets'], versions: { widgets: '1.0.0' } });
    const res = await begin(s, token, 'widgets');
    expect([res.statusCode, errCode(res)]).toEqual([403, 'not_owner']);
  });

  test('a token of a repository identity on a package that accounts own: not_owner', async () => {
    const s = setup();
    await s.h.account(1, 'someone', ['demo']);
    const token = await ciToken(s, { ci_owner: OWNER, packages: ['demo'], versions: { demo: '1.0.0' } });
    const res = await begin(s, token, 'demo');
    expect([res.statusCode, errCode(res)]).toEqual([403, 'not_owner']);
    // the same on commit and on yank: ownership is checked everywhere a package is written
    const commit = await s.h.commit(token, 'demo', '1.0.0', ['upl_x'], 'a'.repeat(64));
    expect(errCode(commit)).toBe('not_owner');
    const yank = await s.h.call('PUT', '/api/v1/packages/demo/1.0.0/yank', token, { yanked: true, reason: 'x' });
    expect(errCode(yank)).toBe('not_owner');
  });

  test('a token minted for a package\'s registered trusted publisher (no identity) cannot publish to a CI-owned package', async () => {
    const s = setup();
    await s.h.registry.createPackage({ name: 'widgets', state: 'claimed', created_at: 't', ci_owner: OWNER });
    const token = await ciToken(s, { packages: ['widgets'], version: '1.0.0' });
    const res = await begin(s, token, 'widgets');
    expect([res.statusCode, errCode(res)]).toEqual([403, 'not_owner']);
  });

  test('an account token on a CI-owned package: not_owner (it has no account owners)', async () => {
    const s = setup();
    await s.h.registry.createPackage({ name: 'widgets', state: 'claimed', created_at: 't', ci_owner: OWNER });
    const token = await s.h.token(7, ['widgets'], ['publish']);
    const res = await begin(s, token, 'widgets');
    expect([res.statusCode, errCode(res)]).toEqual([403, 'not_owner']);
  });

  test('the registered trusted publisher path is unchanged: its token publishes to an account-owned package', async () => {
    const s = setup();
    await s.h.account(1, 'someone', ['demo']);
    const token = await ciToken(s, { packages: ['demo'], version: '1.0.0' });
    expect((await begin(s, token, 'demo')).statusCode).toBe(200);
    expect((await s.h.registry.getVersion('demo', '1.0.0'))?.published_by).toBe('ci');
  });

  test('a token that is neither an account nor a CI token owns nothing', async () => {
    const s = setup();
    await s.h.account(1, 'someone', ['demo']);
    const t = s.h.clock.now();
    const m = await mintToken(s.h.authStore, {
      kind: 'api',
      name: 'odd',
      scopes: ['publish'],
      packages: ['demo'],
      all_current: false,
      created_at: t.toISOString(),
      expires_at: new Date(t.getTime() + 600_000).toISOString(),
    });
    const res = await begin(s, m.secret, 'demo');
    expect([res.statusCode, errCode(res)]).toEqual([403, 'not_owner']);
  });
});

// The CI exchange and the claim route both create packages, in the registry, by the same conditional write. What these prove: a
// name goes to whoever gets there first, in either order, and the loser changes nothing; both leave the package `claimed`;
// the per-actor claim limit counts user claims only. What they do not: the two racing at once (the conditional write is
// what decides, and claim.test.ts races two claims).
describe('the CI exchange and the claim route share one namespace', () => {
  const userClaim = async (s: Setup, name: string, id = 7) => {
    await s.h.authStore.upsertUser(id, `user${id}`, s.h.clock.now().toISOString());
    return s.h.call('POST', `/api/v1/packages/${name}/claim`, await s.h.token(id, [], ['publish']), undefined);
  };

  test('both write state claimed: a CI-created and a user-claimed package look alike except for who owns them', async () => {
    const s = setup();
    await s.oidc.exchange({ jwt: s.jwt(), packages: widgets });
    expect((await userClaim(s, 'gadgets')).statusCode).toBe(201);
    const ci = await s.h.registry.getPackage('widgets');
    const user = await s.h.registry.getPackage('gadgets');
    expect([ci?.state, user?.state]).toEqual(['claimed', 'claimed']);
    expect([ci?.ci_owner, user?.ci_owner]).toEqual([OWNER, undefined]);
    expect([await s.h.registry.listOwners('widgets'), (await s.h.registry.listOwners('gadgets')).length]).toEqual([[], 1]);
  });

  test('a name a user claimed is refused for CI (not_owner): nothing is changed, the CI token is not spent', async () => {
    const s = setup();
    expect((await userClaim(s, 'widgets')).statusCode).toBe(201);
    const jwt = s.jwt();
    await refused(s.oidc.exchange({ jwt, packages: widgets }), 'not_owner', 403);
    const rec = await s.h.registry.getPackage('widgets');
    expect(rec?.ci_owner).toBeUndefined();
    expect((await s.h.registry.listOwners('widgets')).map((o) => o.github_id)).toEqual([7]);
    expect((await s.h.registry.listAudit('widgets')).map((a) => a.action)).toEqual(['claim']);
    expect(ciTokens(s)).toEqual([]);
    await expect(s.oidc.exchange({ jwt, packages: [{ name: 'free_name', version: '1.0.0' }] })).resolves.toBeDefined(); // not spent
  });

  test('a name CI created is refused for a user claim (409 name_taken): the CI identity still owns it and no owner row appears', async () => {
    const s = setup();
    await s.oidc.exchange({ jwt: s.jwt(), packages: widgets });
    const res = await userClaim(s, 'widgets');
    expect([res.statusCode, errCode(res)]).toEqual([409, 'name_taken']);
    expect((await s.h.registry.getPackage('widgets'))?.ci_owner).toBe(OWNER);
    expect(await s.h.registry.listOwners('widgets')).toEqual([]);
    expect((await s.h.registry.listAudit('widgets')).map((a) => a.action)).toEqual(['ci_claim']);
  });

  test('the claim limit counts user claims only: CI exchanges neither spend it nor are refused by it', async () => {
    const s = setup();
    s.h.config.claimRatePerAccountPerDay = 1;
    s.h.config.claimRatePerTokenPerDay = 1;
    s.h.build();
    for (const name of ['alpha', 'bravo', 'charlie']) {
      await s.oidc.exchange({ jwt: s.jwt(), packages: [{ name, version: '1.0.0' }] }); // three creations against a limit of one
    }
    expect(s.h.publishes.counters.size).toBe(0);
    expect((await userClaim(s, 'delta')).statusCode).toBe(201); // the whole quota is still there
    expect((await userClaim(s, 'echo')).statusCode).toBe(429); // and it does bind users
    expect((await s.h.registry.getPackage('echo'))).toBeUndefined();
  });
});
