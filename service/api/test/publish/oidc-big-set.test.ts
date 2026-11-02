import { AuthError, GithubJwtVerifier, OidcExchange, type CiPublisher } from '../../src/auth';
import { MAX_CI_PACKAGES } from '../../src/auth/oidc';
import { RegistryError } from '../../src/errors';
import { goodClaims, newKey, signJwt } from '../auth-helpers';
import { Harness } from './harness';

// A release of hundreds of packages is one exchange. What these prove: the exchange takes exactly as many names as a group may
// have (500) and refuses one more; the per-name reads and writes of the exchange run concurrently but never more than sixteen at a
// time (a fake store records how many calls are in flight); the results, the refusals (the first failing name in the request order)
// and the nothing-spent-on-refusal rule are what they were when the names were taken one by one; a retry after a failed create
// finishes the set. What they do not: DynamoDB or the Lambda's real time budget (no test here asserts time).

const key = newKey('k1');
const OWNER = 'gh-repo:1376408823';
const ACCOUNT = 15257031;
const BASE: CiPublisher = {
  repository_id: '1376408823',
  repository_owner_id: '305577347',
  workflow: '.github/workflows/release.yml',
  ref: 'refs/heads/main',
  job_workflow_ref: 'komira-ai/komira/.github/workflows/release.yml@refs/heads/main',
  events: ['push'],
  environment: 'beta',
};

/** Counts the calls of the named methods that are in flight at once, and lets each one yield to the others before it runs. */
function instrument(registry: object, methods: string[]) {
  const seen = { inFlight: 0, max: 0, calls: 0 };
  const target = registry as Record<string, (...a: unknown[]) => Promise<unknown>>;
  for (const m of methods) {
    const real = target[m]!.bind(registry);
    target[m] = async (...args: unknown[]) => {
      seen.calls++;
      seen.inFlight++;
      seen.max = Math.max(seen.max, seen.inFlight);
      try {
        await new Promise<void>((r) => setImmediate(r));
        return await real(...args);
      } finally {
        seen.inFlight--;
      }
    };
  }
  return seen;
}

function setup(actsFor?: number) {
  const h = new Harness();
  const publisher: CiPublisher = actsFor === undefined ? BASE : { ...BASE, acts_for: String(actsFor) };
  const verifier = new GithubJwtVerifier({ audiences: ['beta.mopm.dev'], now: h.clock.now, jwks: async () => ({ keys: [key.jwk] }) });
  const oidc = new OidcExchange({ store: h.authStore, verifier, now: h.clock.now, ciPublishers: [publisher], registry: h.registry });
  const jwt = () =>
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
      }),
    );
  return { h, oidc, jwt };
}

const names = (n: number) => Array.from({ length: n }, (_x, i) => `pkg_${String(i).padStart(3, '0')}`);
const set = (n: number) => names(n).map((name) => ({ name, version: '1.0.0' }));
const ociTokens = (h: Harness) => h.authStore.dumpTokens().filter((t) => t.kind === 'oidc');

async function codeOf(p: Promise<unknown>): Promise<{ code: string; name?: string }> {
  try {
    await p;
  } catch (e) {
    const err = e as AuthError | RegistryError;
    return { code: err.code, name: err.detail.name };
  }
  throw new Error('expected a refusal');
}

describe('the number of packages of one exchange is the number of members of a group', () => {
  test('the limit is 500', () => {
    expect(MAX_CI_PACKAGES).toBe(500);
  });

  test('500 names are accepted and 501 are refused with nothing created and the token unspent', async () => {
    const s = setup();
    const jwt = s.jwt();
    expect((await codeOf(s.oidc.exchange({ jwt, packages: set(501) }))).code).toBe('invalid_request');
    expect(await s.h.registry.getPackage('pkg_000')).toBeUndefined();
    // The refusal did not spend the identity token: the same one now exchanges 500.
    const r = await s.oidc.exchange({ jwt, packages: set(500) });
    expect(r.packages).toHaveLength(500);
    expect(ociTokens(s.h)).toHaveLength(1);
  });
});

describe('a new set: the names are created by the publisher, concurrently and sixteen at a time', () => {
  test('500 names: every one created, owned by the identity and audited once, the token lists them in the request order', async () => {
    const s = setup();
    const reads = instrument(s.h.registry, ['getPackage']);
    const writes = instrument(s.h.registry, ['createPackage']);
    const audits = instrument(s.h.registry, ['appendAudit']);
    const r = await s.oidc.exchange({ jwt: s.jwt(), packages: set(500) });
    expect(r.packages).toEqual(set(500));
    for (const n of names(500)) {
      expect(await s.h.registry.getPackage(n)).toMatchObject({ state: 'claimed', ci_owner: OWNER });
      expect((await s.h.registry.listAudit(n)).map((a) => [a.actor, a.action])).toEqual([[OWNER, 'ci_claim']]);
    }
    const [tok] = ociTokens(s.h);
    expect(tok!.packages).toEqual(names(500));
    // Concurrent, and bounded: more than one at once, never more than sixteen.
    for (const c of [reads, writes, audits]) {
      expect(c.max).toBeGreaterThan(1);
      expect(c.max).toBeLessThanOrEqual(16);
    }
    expect(writes.calls).toBe(500);
    expect(audits.calls).toBe(500);
  });

  test('a name of someone else refuses the whole set before anything is created or the token spent', async () => {
    const s = setup();
    await s.h.registry.createPackage({ name: 'pkg_040', state: 'claimed', created_at: 't', ci_owner: 'gh-repo:999' });
    await s.h.registry.createPackage({ name: 'pkg_007', state: 'claimed', created_at: 't', ci_owner: 'gh-repo:998' });
    const jwt = s.jwt();
    expect(await codeOf(s.oidc.exchange({ jwt, packages: set(100) }))).toEqual({ code: 'not_owner', name: 'pkg_007' });
    expect(await s.h.registry.getPackage('pkg_000')).toBeUndefined();
    expect(ociTokens(s.h)).toHaveLength(0);
    // Not spent: without those two names the same identity token works.
    const rest = set(100).filter((p) => p.name !== 'pkg_007' && p.name !== 'pkg_040');
    expect((await s.oidc.exchange({ jwt, packages: rest })).packages).toHaveLength(98);
  });

  test('a name made by this publisher meanwhile is not an error and is not audited twice; one made by another is refused, the first in the request order', async () => {
    const s = setup();
    const real = s.h.registry.createPackage.bind(s.h.registry);
    const racing = new Map<string, string>([
      ['pkg_005', OWNER],
      ['pkg_030', 'gh-repo:7'],
      ['pkg_031', 'gh-repo:8'],
    ]);
    s.h.registry.createPackage = async (p) => {
      const other = racing.get(p.name);
      if (other) await real({ ...p, ci_owner: other });
      await real(p);
    };
    expect(await codeOf(s.oidc.exchange({ jwt: s.jwt(), packages: set(40) }))).toEqual({ code: 'not_owner', name: 'pkg_030' });
    // pkg_005 was not an error: it is the publisher's, and the create that lost did not audit it.
    expect(await s.h.registry.getPackage('pkg_005')).toMatchObject({ ci_owner: OWNER });
    expect(await s.h.registry.listAudit('pkg_005')).toEqual([]);
    racing.delete('pkg_030');
    racing.delete('pkg_031');
    // The retry (a fresh identity token, as the first was spent) without the two names that are another's finishes the set.
    s.h.registry.createPackage = real;
    const rest = set(40).filter((p) => p.name !== 'pkg_030' && p.name !== 'pkg_031');
    expect((await s.oidc.exchange({ jwt: s.jwt(), packages: rest })).packages).toHaveLength(38);
    for (const p of rest) expect((await s.h.registry.getPackage(p.name))?.ci_owner).toBe(OWNER);
  });

  test('a retry after a failed create completes the set: no name twice, no error for the ones the first attempt made', async () => {
    const s = setup();
    const real = s.h.registry.createPackage.bind(s.h.registry);
    s.h.registry.createPackage = async (p) => {
      if (p.name === 'pkg_120') throw new Error('throttled');
      await real(p);
    };
    await expect(s.oidc.exchange({ jwt: s.jwt(), packages: set(200) })).rejects.toThrow('throttled');
    s.h.registry.createPackage = real;
    const r = await s.oidc.exchange({ jwt: s.jwt(), packages: set(200) });
    expect(r.packages).toHaveLength(200);
    for (const n of names(200)) expect(await s.h.registry.getPackage(n)).toMatchObject({ ci_owner: OWNER });
    // The failed name was created by the retry and audited once; none of the others is audited twice.
    for (const n of names(200)) expect((await s.h.registry.listAudit(n)).length).toBeLessThanOrEqual(1);
    expect(await s.h.registry.listAudit('pkg_120')).toHaveLength(1);
  });
});

describe('a CI publisher that acts for an account: the names are read sixteen at a time', () => {
  async function owned(s: ReturnType<typeof setup>, n: number) {
    await s.h.authStore.upsertUser(ACCOUNT, 'acct', s.h.clock.now().toISOString());
    for (const name of names(n)) {
      await s.h.registry.createPackage({ name, state: 'claimed', created_at: 't' });
      await s.h.registry.addOwner({ name, github_id: ACCOUNT, handle: 'acct', added_at: 't' });
    }
  }

  test('500 names: the token is the account\'s for exactly them in the request order, and the reads were concurrent and bounded', async () => {
    const s = setup(ACCOUNT);
    await owned(s, 500);
    const reads = instrument(s.h.registry, ['getPackage']);
    const owners = instrument(s.h.registry, ['listOwners']);
    const r = await s.oidc.exchange({ jwt: s.jwt(), packages: set(500) });
    expect(r.packages).toEqual(set(500));
    const [tok] = ociTokens(s.h);
    expect(tok).toMatchObject({ github_id: ACCOUNT, packages: names(500) });
    expect(tok!.ci_owner).toBeUndefined();
    for (const c of [reads, owners]) {
      expect(c.max).toBeGreaterThan(1);
      expect(c.max).toBeLessThanOrEqual(16);
      expect(c.calls).toBe(500);
    }
  });

  test('the refusal is the first failing name in the request order, whatever finishes first; nothing is minted or spent', async () => {
    const s = setup(ACCOUNT);
    await owned(s, 100);
    // Of two names that fail, the one earlier in the request is the refusal, whatever the order the reads finish in.
    await s.h.registry.createPackage({ name: 'zz_unclaimed', state: 'claimed', created_at: 't', ci_owner: 'gh-repo:1' });
    const jwt = s.jwt();
    const mixed = [...set(100).slice(0, 20), { name: 'zz_unclaimed', version: '1.0.0' }, ...set(100).slice(20, 50), { name: 'unknown_pkg', version: '1.0.0' }];
    expect(await codeOf(s.oidc.exchange({ jwt, packages: mixed }))).toEqual({ code: 'not_owner', name: 'zz_unclaimed' });
    const reversed = [...set(100).slice(0, 20), { name: 'unknown_pkg', version: '1.0.0' }, { name: 'zz_unclaimed', version: '1.0.0' }];
    expect(await codeOf(s.oidc.exchange({ jwt, packages: reversed }))).toEqual({ code: 'package_not_found', name: 'unknown_pkg' });
    expect(ociTokens(s.h)).toHaveLength(0);
    expect((await s.oidc.exchange({ jwt, packages: set(100) })).packages).toHaveLength(100);
  });

  test('the refusal is the lowest request index even when a later name is refused first', async () => {
    const s = setup(ACCOUNT);
    await owned(s, 60);
    await s.h.registry.createPackage({ name: 'zz_unclaimed', state: 'claimed', created_at: 't', ci_owner: 'gh-repo:1' });
    // The read of the earlier failing name is held until the later failing name has been read and refused.
    let release!: () => void;
    const gate = new Promise<void>((r) => (release = r));
    const real = s.h.registry.getPackage.bind(s.h.registry);
    s.h.registry.getPackage = async (n: string) => {
      if (n === 'zz_unclaimed') await gate;
      const p = await real(n);
      if (n === 'unknown_pkg') release();
      return p;
    };
    const mixed = [...set(60).slice(0, 20), { name: 'zz_unclaimed', version: '1.0.0' }, ...set(60).slice(20, 50), { name: 'unknown_pkg', version: '1.0.0' }];
    expect(await codeOf(s.oidc.exchange({ jwt: s.jwt(), packages: mixed }))).toEqual({ code: 'not_owner', name: 'zz_unclaimed' });
    expect(ociTokens(s.h)).toHaveLength(0);
  });
});
