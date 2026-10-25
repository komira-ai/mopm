import { Authenticator, AuthError, GithubJwtVerifier, MemoryAuthStore, OidcExchange, matchesTrustedPublisher, workflowPath } from '../src/auth';
import type { GithubActionsClaims, Jwk, TrustedPublisher } from '../src/auth';
import { goodClaims, newKey, rawJwt, signJwt, TestClock, ISSUER } from './auth-helpers';

const key = newKey('k1');
const otherKey = newKey('k1'); // same kid, different key: a forger who copies the kid

function setup(opts: { jwks?: Jwk[]; audiences?: string[] } = {}) {
  const clock = new TestClock();
  const store = new MemoryAuthStore();
  let fetches = 0;
  let keys = opts.jwks ?? [key.jwk];
  const verifier = new GithubJwtVerifier({
    audiences: opts.audiences ?? ['mopm.dev'],
    now: clock.now,
    jwks: async () => {
      fetches++;
      return { keys };
    },
  });
  const oidc = new OidcExchange({ store, verifier, now: clock.now });
  const auth = new Authenticator({ store, now: clock.now });
  const tp: TrustedPublisher = {
    id: 'tp1', name: 'widgets', repository_id: '111', repository_owner_id: '222',
    workflow: '.github/workflows/release.yml', added_by: 1, added_at: '2026-10-01T00:00:00Z',
  };
  return { clock, store, oidc, auth, verifier, tp, fetches: () => fetches, setKeys: (k: Jwk[]) => { keys = k; } };
}

async function err(p: Promise<unknown>): Promise<AuthError> {
  try {
    await p;
  } catch (e) {
    expect(e).toBeInstanceOf(AuthError);
    return e as AuthError;
  }
  throw new Error('expected an AuthError, got success');
}
/** Exact: code, HTTP status, and the detail the message template carries. */
async function expectRejected(p: Promise<unknown>, code: string, status: number, detail?: string) {
  const e = await err(p);
  expect({ code: e.code, status: e.status }).toEqual({ code, status });
  if (detail !== undefined) expect(e.detail.detail).toBe(detail);
}

describe('OIDC exchange: the happy path', () => {
  test('a matching GitHub Actions token mints a 10 minute publish token for exactly that package and version', async () => {
    const { oidc, store, tp, clock, auth } = setup();
    await store.addTrustedPublisher(tp);
    const jwt = signJwt(key, goodClaims(clock));
    const r = await oidc.exchange({ jwt, name: 'widgets', version: '1.0.0' });
    expect(r.token_kind).toBe('publish');
    expect(r.name).toBe('widgets');
    expect(r.version).toBe('1.0.0');
    expect(r.expires_at).toBe(new Date(clock.t + 10 * 60_000).toISOString());
    expect(r.token).toMatch(/^mopm_[a-z2-7]{32,64}$/);

    const p = await auth.authenticate(`Bearer ${r.token}`);
    expect(p.kind).toBe('oidc');
    expect(p.github_id).toBeUndefined();
    expect(() => auth.publishToken(p, 'widgets', '1.0.0')).not.toThrow();
    // the same version under conda equality is the same version
    expect(() => auth.publishToken(p, 'widgets', '1.0.0')).not.toThrow();
    // the secret is stored hashed only
    expect(JSON.stringify(store.dumpTokens())).not.toContain(r.token);
  });

  test('the minted token cannot publish another version, another package, or yank, and cannot manage tokens', async () => {
    const { oidc, store, tp, clock, auth } = setup();
    await store.addTrustedPublisher(tp);
    await store.addTrustedPublisher({ ...tp, id: 'tp2', name: 'other' });
    const r = await oidc.exchange({ jwt: signJwt(key, goodClaims(clock)), name: 'widgets', version: '1.0.0' });
    const p = await auth.authenticate(`Bearer ${r.token}`);
    const refused = (f: () => void) => expect(f).toThrow(expect.objectContaining({ code: 'scope_missing', status: 403 }));
    refused(() => auth.publishToken(p, 'widgets', '1.0.1'));
    refused(() => auth.publishToken(p, 'other', '1.0.0'));
    refused(() => auth.yankToken(p, 'widgets'));
    expect(() => auth.freshSession(p)).toThrow(expect.objectContaining({ code: 'scope_missing' }));
    expect(() => auth.userToken(p)).toThrow(expect.objectContaining({ code: 'scope_missing' }));
  });

  test('the minted token expires after 10 minutes: valid at 9:59, token_expired at 10:00', async () => {
    const { oidc, store, tp, clock, auth } = setup();
    await store.addTrustedPublisher(tp);
    const r = await oidc.exchange({ jwt: signJwt(key, goodClaims(clock)), name: 'widgets', version: '2.0.0' });
    clock.advance(10 * 60_000 - 1000);
    await auth.authenticate(`Bearer ${r.token}`);
    clock.advance(1000);
    await expectRejected(auth.authenticate(`Bearer ${r.token}`), 'token_expired', 401);
  });

  test('an optional environment: unset on the record accepts any; set requires equality', async () => {
    const { oidc, store, tp, clock } = setup();
    await store.addTrustedPublisher(tp);
    const withEnv = await oidc.exchange({ jwt: signJwt(key, goodClaims(clock, { environment: 'release' })), name: 'widgets', version: '1.0.0' });
    expect(withEnv.name).toBe('widgets');

    const s = setup();
    await s.store.addTrustedPublisher({ ...s.tp, environment: 'release' });
    await s.oidc.exchange({ jwt: signJwt(key, goodClaims(s.clock, { environment: 'release' })), name: 'widgets', version: '1.0.0' });
    await expectRejected(s.oidc.exchange({ jwt: signJwt(key, goodClaims(s.clock, { environment: 'staging' })), name: 'widgets', version: '1.0.0' }), 'oidc_not_trusted', 403);
    await expectRejected(s.oidc.exchange({ jwt: signJwt(key, goodClaims(s.clock)), name: 'widgets', version: '1.0.0' }), 'oidc_not_trusted', 403);
  });

  test('any one of several trusted publishers is enough', async () => {
    const { oidc, store, tp, clock } = setup();
    await store.addTrustedPublisher({ ...tp, id: 'a', repository_id: '999' });
    await store.addTrustedPublisher({ ...tp, id: 'b' });
    await expect(oidc.exchange({ jwt: signJwt(key, goodClaims(clock)), name: 'widgets', version: '1.0.0' })).resolves.toBeDefined();
  });

  test('the audience may be the stage host as well as mopm.dev, when configured', async () => {
    const { oidc, store, tp, clock } = setup({ audiences: ['mopm.dev', 'gamma.mopm.dev'] });
    await store.addTrustedPublisher(tp);
    await oidc.exchange({ jwt: signJwt(key, goodClaims(clock, { aud: 'gamma.mopm.dev' })), name: 'widgets', version: '1.0.0' });
    await oidc.exchange({ jwt: signJwt(key, goodClaims(clock, { aud: ['x', 'mopm.dev'] })), name: 'widgets', version: '1.0.0' });
  });
});

describe('OIDC exchange: every refusal, exactly', () => {
  const run = async (claims: (c: TestClock) => Record<string, unknown>, tpOver: Partial<TrustedPublisher> = {}) => {
    const s = setup();
    await s.store.addTrustedPublisher({ ...s.tp, ...tpOver });
    return { s, p: s.oidc.exchange({ jwt: signJwt(key, claims(s.clock)), name: 'widgets', version: '1.0.0' }) };
  };

  test('wrong audience: oidc_token_invalid (401) "wrong audience"', async () => {
    const { p } = await run((c) => goodClaims(c, { aud: 'sts.amazonaws.com' }));
    await expectRejected(p, 'oidc_token_invalid', 401, 'wrong audience');
  });

  test('a stage that accepts only its own host refuses the bare domain and another stage host, and accepts its own', async () => {
    const strict = setup({ audiences: ['beta.mopm.dev'] });
    await strict.store.addTrustedPublisher(strict.tp);
    const go = (aud: string) => strict.oidc.exchange({ jwt: signJwt(key, goodClaims(strict.clock, { aud })), name: 'widgets', version: '1.0.0' });
    await expectRejected(go('mopm.dev'), 'oidc_token_invalid', 401, 'wrong audience');
    await expectRejected(go('gamma.mopm.dev'), 'oidc_token_invalid', 401, 'wrong audience');
    await expect(go('beta.mopm.dev')).resolves.toBeDefined();
  });

  test('a missing audience is also wrong audience', async () => {
    const { p } = await run((c) => { const g = goodClaims(c); delete g.aud; return g; });
    await expectRejected(p, 'oidc_token_invalid', 401, 'wrong audience');
  });

  test('wrong issuer', async () => {
    const { p } = await run((c) => goodClaims(c, { iss: 'https://evil.example.invalid' }));
    await expectRejected(p, 'oidc_token_invalid', 401, 'wrong issuer');
  });

  test('wrong repository_id: oidc_not_trusted (403), even when the repository NAME matches', async () => {
    const { p } = await run((c) => goodClaims(c, { repository_id: '112' }));
    await expectRejected(p, 'oidc_not_trusted', 403);
  });

  test('wrong repository_owner_id: oidc_not_trusted', async () => {
    const { p } = await run((c) => goodClaims(c, { repository_owner_id: '223' }));
    await expectRejected(p, 'oidc_not_trusted', 403);
  });

  test('wrong workflow file: oidc_not_trusted', async () => {
    const { p } = await run((c) => goodClaims(c, { workflow_ref: 'acme/widgets/.github/workflows/other.yml@refs/heads/main' }));
    await expectRejected(p, 'oidc_not_trusted', 403);
  });

  test('a workflow_ref from a different repository than the repository claim does not match', async () => {
    const { p } = await run((c) => goodClaims(c, { workflow_ref: 'evil/fork/.github/workflows/release.yml@refs/heads/main' }));
    await expectRejected(p, 'oidc_not_trusted', 403);
  });

  test('the good token passes: trusted repository, owner, workflow, main, a push', async () => {
    const { p } = await run((c) => goodClaims(c));
    await expect(p).resolves.toMatchObject({ token_kind: 'publish', name: 'widgets', version: '1.0.0' });
  });

  test('wrong ref: a feature branch or a tag of the trusted workflow is refused (oidc_not_trusted), though workflow_ref names the right file', async () => {
    for (const ref of ['refs/heads/feature', 'refs/tags/v1.0.0', 'refs/pull/7/merge', 'refs/heads/main2', 'refs/heads/']) {
      const { p } = await run((c) => goodClaims(c, { ref, workflow_ref: 'acme/widgets/.github/workflows/release.yml@refs/heads/main' }));
      await expectRejected(p, 'oidc_not_trusted', 403);
    }
  });

  test('a row may pin another ref, and then only that ref passes', async () => {
    const pinned = { ref: 'refs/heads/release' };
    await expect((await run((c) => goodClaims(c, { ref: 'refs/heads/release' }), pinned)).p).resolves.toBeDefined();
    await expectRejected((await run((c) => goodClaims(c), pinned)).p, 'oidc_not_trusted', 403);
  });

  test('wrong event: pull_request, schedule, release and workflow_run are refused (oidc_not_trusted) even on main', async () => {
    for (const event_name of ['pull_request', 'issue_comment', 'schedule', 'release', 'workflow_run']) {
      const { p } = await run((c) => goodClaims(c, { event_name }));
      await expectRejected(p, 'oidc_not_trusted', 403);
    }
  });

  test('both push and workflow_dispatch pass by default; a row that names one refuses the other', async () => {
    for (const event_name of ['push', 'workflow_dispatch']) await expect((await run((c) => goodClaims(c, { event_name }))).p).resolves.toBeDefined();
    await expectRejected((await run((c) => goodClaims(c, { event_name: 'push' }), { event_name: 'workflow_dispatch' })).p, 'oidc_not_trusted', 403);
    await expect((await run((c) => goodClaims(c, { event_name: 'workflow_dispatch' }), { event_name: 'workflow_dispatch' })).p).resolves.toBeDefined();
    // a row cannot widen the set to an event outside it
    await expectRejected((await run((c) => goodClaims(c, { event_name: 'pull_request' }), { event_name: 'pull_request' })).p, 'oidc_not_trusted', 403);
  });

  test('wrong environment: a row that names one refuses a token for another or none (oidc_not_trusted)', async () => {
    const row = { environment: 'beta' };
    await expect((await run((c) => goodClaims(c, { environment: 'beta' }), row)).p).resolves.toBeDefined();
    await expectRejected((await run((c) => goodClaims(c, { environment: 'prod' }), row)).p, 'oidc_not_trusted', 403);
    await expectRejected((await run((c) => goodClaims(c), row)).p, 'oidc_not_trusted', 403);
  });

  test('a replayed jti is refused (oidc_token_invalid "token already used"), the first use having minted exactly one token', async () => {
    const s = setup();
    await s.store.addTrustedPublisher(s.tp);
    const jwt = signJwt(key, goodClaims(s.clock));
    await s.oidc.exchange({ jwt, name: 'widgets', version: '1.0.0' });
    await expectRejected(s.oidc.exchange({ jwt, name: 'widgets', version: '1.0.0' }), 'oidc_token_invalid', 401, 'token already used');
    // a new signature over the same jti is the same token
    const again = signJwt(key, goodClaims(s.clock, { jti: JSON.parse(Buffer.from(jwt.split('.')[1]!, 'base64url').toString()).jti }));
    await expectRejected(s.oidc.exchange({ jwt: again, name: 'widgets', version: '1.0.0' }), 'oidc_token_invalid', 401, 'token already used');
    expect(s.store.dumpTokens()).toHaveLength(1);
    // another job's token (another jti) is unaffected
    await s.oidc.exchange({ jwt: signJwt(key, goodClaims(s.clock)), name: 'widgets', version: '1.0.0' });
    expect(s.store.dumpTokens()).toHaveLength(2);
  });

  test('a token refused for the wrong package is not spent: it still works for the right one', async () => {
    const s = setup();
    await s.store.addTrustedPublisher(s.tp);
    const jwt = signJwt(key, goodClaims(s.clock));
    await expectRejected(s.oidc.exchange({ jwt, name: 'gadgets', version: '1.0.0' }), 'oidc_not_trusted', 403);
    await expect(s.oidc.exchange({ jwt, name: 'widgets', version: '1.0.0' })).resolves.toBeDefined();
  });

  test('a replay minutes later, while the CI token is still within its own expiry, is still refused', async () => {
    const s = setup();
    await s.store.addTrustedPublisher(s.tp);
    const jwt = signJwt(key, goodClaims(s.clock, { exp: s.clock.seconds + 300 }));
    await s.oidc.exchange({ jwt, name: 'widgets', version: '1.0.0' });
    s.clock.advance(4 * 60_000);
    await expectRejected(s.oidc.exchange({ jwt, name: 'widgets', version: '1.0.0' }), 'oidc_token_invalid', 401, 'token already used');
  });

  test('a package with no trusted publisher: oidc_not_trusted, the same answer as a mismatch', async () => {
    const s = setup();
    await expectRejected(s.oidc.exchange({ jwt: signJwt(key, goodClaims(s.clock)), name: 'widgets', version: '1.0.0' }), 'oidc_not_trusted', 403);
  });

  test('trust is per package: a publisher of one package cannot mint for another', async () => {
    const s = setup();
    await s.store.addTrustedPublisher(s.tp);
    await expectRejected(s.oidc.exchange({ jwt: signJwt(key, goodClaims(s.clock)), name: 'widgets2', version: '1.0.0' }), 'oidc_not_trusted', 403);
  });

  test('expired token: "token expired", exact at the leeway boundary', async () => {
    const s = setup();
    await s.store.addTrustedPublisher(s.tp);
    const mk = (exp: number) => signJwt(key, goodClaims(s.clock, { exp }));
    // leeway is 60s: exp = now - 59 is still accepted, exp = now - 60 is not
    await s.oidc.exchange({ jwt: mk(s.clock.seconds - 59), name: 'widgets', version: '1.0.0' });
    await expectRejected(s.oidc.exchange({ jwt: mk(s.clock.seconds - 60), name: 'widgets', version: '1.0.0' }), 'oidc_token_invalid', 401, 'token expired');
    await expectRejected(s.oidc.exchange({ jwt: mk(s.clock.seconds - 3600), name: 'widgets', version: '1.0.0' }), 'oidc_token_invalid', 401, 'token expired');
  });

  test('a token that expires while we hold it is expired when the clock passes exp', async () => {
    const s = setup();
    await s.store.addTrustedPublisher(s.tp);
    const jwt = signJwt(key, goodClaims(s.clock, { exp: s.clock.seconds + 10 }));
    await s.oidc.exchange({ jwt, name: 'widgets', version: '1.0.0' });
    s.clock.advance(80_000);
    await expectRejected(s.oidc.exchange({ jwt, name: 'widgets', version: '1.0.0' }), 'oidc_token_invalid', 401, 'token expired');
  });

  test('not yet valid (nbf) and issued in the future (iat)', async () => {
    const s = setup();
    await s.store.addTrustedPublisher(s.tp);
    await expectRejected(s.oidc.exchange({ jwt: signJwt(key, goodClaims(s.clock, { nbf: s.clock.seconds + 3600 })), name: 'widgets', version: '1.0.0' }), 'oidc_token_invalid', 401, 'token not yet valid');
    await expectRejected(s.oidc.exchange({ jwt: signJwt(key, goodClaims(s.clock, { iat: s.clock.seconds + 3600, nbf: undefined })), name: 'widgets', version: '1.0.0' }), 'oidc_token_invalid', 401, 'token issued in the future');
  });

  test('missing exp, missing iat and missing identity claims are refused', async () => {
    const s = setup();
    await s.store.addTrustedPublisher(s.tp);
    const without = (k: string) => { const g = goodClaims(s.clock); delete g[k]; return signJwt(key, g); };
    await expectRejected(s.oidc.exchange({ jwt: without('exp'), name: 'widgets', version: '1.0.0' }), 'oidc_token_invalid', 401, 'missing expiry');
    await expectRejected(s.oidc.exchange({ jwt: without('iat'), name: 'widgets', version: '1.0.0' }), 'oidc_token_invalid', 401, 'missing issued-at');
    for (const c of ['repository', 'repository_id', 'repository_owner_id', 'workflow_ref', 'ref', 'event_name', 'jti']) {
      await expectRejected(s.oidc.exchange({ jwt: without(c), name: 'widgets', version: '1.0.0' }), 'oidc_token_invalid', 401, `missing claim ${c}`);
    }
  });

  test('bad signature: a payload altered after signing', async () => {
    const s = setup();
    await s.store.addTrustedPublisher(s.tp);
    const [h, , sig] = signJwt(key, goodClaims(s.clock, { repository_id: '999' })).split('.');
    const forgedPayload = Buffer.from(JSON.stringify(goodClaims(s.clock))).toString('base64url');
    await expectRejected(s.oidc.exchange({ jwt: `${h}.${forgedPayload}.${sig}`, name: 'widgets', version: '1.0.0' }), 'oidc_token_invalid', 401, 'bad signature');
  });

  test('bad signature: signed by a different key that claims the trusted kid', async () => {
    const s = setup();
    await s.store.addTrustedPublisher(s.tp);
    await expectRejected(s.oidc.exchange({ jwt: signJwt(otherKey, goodClaims(s.clock)), name: 'widgets', version: '1.0.0' }), 'oidc_token_invalid', 401, 'bad signature');
  });

  test('unknown kid: refused as unknown signing key', async () => {
    const s = setup();
    await s.store.addTrustedPublisher(s.tp);
    const unknown = { ...newKey('rotated-away') };
    await expectRejected(s.oidc.exchange({ jwt: signJwt(unknown, goodClaims(s.clock)), name: 'widgets', version: '1.0.0' }), 'oidc_token_invalid', 401, 'unknown signing key');
  });

  test('algorithm "none" and HS256 (key confusion) are refused before any key is used', async () => {
    const s = setup();
    await s.store.addTrustedPublisher(s.tp);
    const claims = goodClaims(s.clock);
    await expectRejected(s.oidc.exchange({ jwt: rawJwt({ alg: 'none', kid: 'k1' }, claims, ''), name: 'widgets', version: '1.0.0' }), 'oidc_token_invalid', 401, 'unsupported algorithm');
    await expectRejected(s.oidc.exchange({ jwt: rawJwt({ alg: 'HS256', kid: 'k1' }, claims), name: 'widgets', version: '1.0.0' }), 'oidc_token_invalid', 401, 'unsupported algorithm');
    await expectRejected(s.oidc.exchange({ jwt: rawJwt({ alg: 'RS512', kid: 'k1' }, claims), name: 'widgets', version: '1.0.0' }), 'oidc_token_invalid', 401, 'unsupported algorithm');
    expect(s.fetches()).toBe(0);
  });

  test('malformed input: not three parts, not base64url, not JSON, empty, oversize, missing kid', async () => {
    const s = setup();
    await s.store.addTrustedPublisher(s.tp);
    for (const jwt of ['', 'a.b', 'a.b.c.d', '!!!.@@@.###', `${Buffer.from('nope').toString('base64url')}.${Buffer.from('{}').toString('base64url')}.AAAA`, 'x'.repeat(9000)]) {
      await expectRejected(s.oidc.exchange({ jwt, name: 'widgets', version: '1.0.0' }), 'oidc_token_invalid', 401, 'malformed token');
    }
    await expectRejected(s.oidc.exchange({ jwt: rawJwt({ alg: 'RS256' }, goodClaims(s.clock)), name: 'widgets', version: '1.0.0' }), 'oidc_token_invalid', 401, 'missing key id');
  });

  test('a bad package name or version is refused before the token is even looked at', async () => {
    const s = setup();
    await expectRejected(s.oidc.exchange({ jwt: 'junk', name: 'Not Valid', version: '1.0.0' }), 'invalid_name', 400);
    await expectRejected(s.oidc.exchange({ jwt: 'junk', name: 'widgets', version: 'one' }), 'invalid_version', 400);
  });

  test('a refused exchange mints nothing', async () => {
    const s = setup();
    await s.store.addTrustedPublisher(s.tp);
    await expect(s.oidc.exchange({ jwt: signJwt(key, goodClaims(s.clock, { aud: 'nope' })), name: 'widgets', version: '1.0.0' })).rejects.toBeInstanceOf(AuthError);
    await expect(s.oidc.exchange({ jwt: signJwt(key, goodClaims(s.clock, { repository_id: '1' })), name: 'widgets', version: '1.0.0' })).rejects.toBeInstanceOf(AuthError);
    expect(s.store.dumpTokens()).toHaveLength(0);
  });
});

describe('JWKS handling', () => {
  test('keys are fetched once and cached across exchanges', async () => {
    const s = setup();
    await s.store.addTrustedPublisher(s.tp);
    for (let i = 0; i < 3; i++) await s.oidc.exchange({ jwt: signJwt(key, goodClaims(s.clock)), name: 'widgets', version: '1.0.0' });
    expect(s.fetches()).toBe(1);
  });

  test('the cache expires after its TTL', async () => {
    const s = setup();
    await s.store.addTrustedPublisher(s.tp);
    await s.oidc.exchange({ jwt: signJwt(key, goodClaims(s.clock)), name: 'widgets', version: '1.0.0' });
    s.clock.advance(10 * 60_000);
    await s.oidc.exchange({ jwt: signJwt(key, goodClaims(s.clock)), name: 'widgets', version: '1.0.0' });
    expect(s.fetches()).toBe(2);
  });

  test('a rotated key is picked up by one refetch; unknown kids cannot force a fetch per request', async () => {
    const s = setup();
    await s.store.addTrustedPublisher(s.tp);
    await s.oidc.exchange({ jwt: signJwt(key, goodClaims(s.clock)), name: 'widgets', version: '1.0.0' });
    const rotated = newKey('k2');
    s.setKeys([key.jwk, rotated.jwk]);
    // within the refetch floor an unknown kid is refused without a fetch
    await expectRejected(s.oidc.exchange({ jwt: signJwt(rotated, goodClaims(s.clock)), name: 'widgets', version: '1.0.0' }), 'oidc_token_invalid', 401, 'unknown signing key');
    expect(s.fetches()).toBe(1);
    // after the floor, one refetch finds it
    s.clock.advance(61_000);
    await s.oidc.exchange({ jwt: signJwt(rotated, goodClaims(s.clock)), name: 'widgets', version: '1.0.0' });
    expect(s.fetches()).toBe(2);
    const junk = newKey('zzz');
    for (let i = 0; i < 5; i++) await err(s.oidc.exchange({ jwt: signJwt(junk, goodClaims(s.clock)), name: 'widgets', version: '1.0.0' }));
    expect(s.fetches()).toBe(2); // five forged kids right after a fetch cost no fetches
  });

  test('a JWKS fetch failure is unavailable (503), not a verdict on the token', async () => {
    const clock = new TestClock();
    const store = new MemoryAuthStore();
    const verifier = new GithubJwtVerifier({ audiences: ['mopm.dev'], now: clock.now, jwks: async () => { throw new Error('down'); } });
    const oidc = new OidcExchange({ store, verifier, now: clock.now });
    await expectRejected(oidc.exchange({ jwt: signJwt(key, goodClaims(clock)), name: 'widgets', version: '1.0.0' }), 'unavailable', 503);
  });

  test('keys that are not RSA signing keys are ignored', async () => {
    const s = setup({ jwks: [{ kty: 'EC', kid: 'k1' } as Jwk, { ...key.jwk, kid: 'enc', use: 'enc' }, key.jwk] });
    await s.store.addTrustedPublisher(s.tp);
    await s.oidc.exchange({ jwt: signJwt(key, goodClaims(s.clock)), name: 'widgets', version: '1.0.0' });
  });
});

describe('matching helpers', () => {
  const claims = (o: Partial<GithubActionsClaims> = {}): GithubActionsClaims => ({
    iss: ISSUER, aud: 'mopm.dev', exp: 0, iat: 0, repository: 'acme/widgets', repository_id: '111', repository_owner_id: '222',
    workflow_ref: 'acme/widgets/.github/workflows/release.yml@refs/heads/main', ref: 'refs/heads/main', event_name: 'push', jti: 'j1', ...o,
  });
  const tp: TrustedPublisher = { id: 'x', name: 'widgets', repository_id: '111', repository_owner_id: '222', workflow: '.github/workflows/release.yml', added_by: 1, added_at: '' };

  test('workflowPath takes the path out of workflow_ref only for the claimed repository', () => {
    expect(workflowPath('acme/widgets/.github/workflows/release.yml@refs/tags/v1', 'acme/widgets')).toBe('.github/workflows/release.yml');
    expect(workflowPath('acme/widgets/.github/workflows/release.yml', 'acme/widgets')).toBe('.github/workflows/release.yml');
    expect(workflowPath('acme/widgets-evil/.github/workflows/release.yml@x', 'acme/widgets')).toBeUndefined();
  });

  test('ref and event are compared exactly, and a missing pin means main and push/workflow_dispatch', () => {
    expect(matchesTrustedPublisher(tp, claims({ ref: 'refs/heads/main' }))).toBe(true);
    expect(matchesTrustedPublisher(tp, claims({ ref: 'refs/heads/mai' }))).toBe(false);
    expect(matchesTrustedPublisher({ ...tp, ref: 'refs/tags/v1' }, claims({ ref: 'refs/tags/v1' }))).toBe(true);
    expect(matchesTrustedPublisher(tp, claims({ event_name: 'workflow_dispatch' }))).toBe(true);
    expect(matchesTrustedPublisher(tp, claims({ event_name: 'pull_request' }))).toBe(false);
  });

  test('a prefix of the workflow path, or a longer path, does not match', () => {
    expect(matchesTrustedPublisher(tp, claims())).toBe(true);
    expect(matchesTrustedPublisher({ ...tp, workflow: '.github/workflows/rel' }, claims())).toBe(false);
    expect(matchesTrustedPublisher({ ...tp, workflow: '.github/workflows/release.yml.bak' }, claims())).toBe(false);
  });
});
