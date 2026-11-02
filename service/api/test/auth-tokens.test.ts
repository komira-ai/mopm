import { AuthError, Authenticator, hashToken, MemoryAuthStore, TokenService, TOKEN_PATTERN, mintToken } from '../src/auth';
import type { AuthStore, Principal, TokenRecord } from '../src/auth';
import { TestClock } from './auth-helpers';

const ALICE = 1001;
const BOB = 1002;

function setup() {
  const clock = new TestClock();
  const store = new MemoryAuthStore();
  const owned: Record<number, string[]> = { [ALICE]: ['alpha', 'beta'], [BOB]: ['gamma'] };
  const tokens = new TokenService({ store, now: clock.now, ownedPackages: async (id) => owned[id] ?? [] });
  const auth = new Authenticator({ store, now: clock.now });
  const session = async (id = ALICE, freshMs = 15 * 60_000) => {
    const m = await mintToken(store, {
      kind: 'session', github_id: id, name: 'login', scopes: [], packages: [], all_current: false,
      fresh_until: new Date(clock.t + freshMs).toISOString(),
      created_at: clock.now().toISOString(), expires_at: new Date(clock.t + 30 * 86_400_000).toISOString(),
    });
    return m.secret;
  };
  const bearer = (s: string) => `Bearer ${s}`;
  return { clock, store, tokens, auth, session, bearer, owned };
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
const codeOf = async (p: Promise<unknown>) => (await err(p)).code;

describe('API token creation', () => {
  test('the secret has the recognisable prefix and matches the spec pattern; only the hash and a prefix are stored', async () => {
    const { tokens, store } = setup();
    const t = await tokens.create(ALICE, { name: 'ci', scopes: ['publish'], packages: ['alpha'], expires_in_days: 30 });
    expect(t.token.startsWith('mopm_')).toBe(true);
    expect(TOKEN_PATTERN.test(t.token)).toBe(true);
    const rows = (store as MemoryAuthStore).dumpTokens();
    expect(rows).toHaveLength(1);
    expect(rows[0]!.hash).toBe(hashToken(t.token));
    expect(rows[0]!.hash).toMatch(/^[0-9a-f]{64}$/);
    expect(t.token.startsWith(rows[0]!.prefix)).toBe(true);
    expect(rows[0]!.prefix.length).toBeLessThan(t.token.length / 2);
    // the secret appears nowhere in anything persisted
    expect(JSON.stringify(rows)).not.toContain(t.token);
    // and not in what list returns later
    expect(JSON.stringify(await tokens.list(ALICE))).not.toContain(t.token);
  });

  test('two tokens never share a secret', async () => {
    const { tokens } = setup();
    const a = await tokens.create(ALICE, { name: 'a', scopes: ['publish'], packages: ['alpha'], expires_in_days: 1 });
    const b = await tokens.create(ALICE, { name: 'b', scopes: ['publish'], packages: ['alpha'], expires_in_days: 1 });
    expect(a.token).not.toBe(b.token);
    expect(a.id).not.toBe(b.id);
  });

  test('expiry is expires_in_days from now', async () => {
    const { tokens, clock } = setup();
    const t = await tokens.create(ALICE, { name: 'x', scopes: ['yank'], packages: ['beta'], expires_in_days: 7 });
    expect(t.expires_at).toBe(new Date(clock.t + 7 * 86_400_000).toISOString());
  });

  test.each([0, 91, 1.5, -1])('expires_in_days %p is refused with invalid_request', async (d) => {
    const { tokens } = setup();
    expect(await codeOf(tokens.create(ALICE, { name: 'x', scopes: ['publish'], packages: ['alpha'], expires_in_days: d }))).toBe('invalid_request');
  });

  test('an unknown scope (owners is not a token scope), an empty scope list and an empty name are invalid_request', async () => {
    const { tokens } = setup();
    expect(await codeOf(tokens.create(ALICE, { name: 'x', scopes: ['owners' as never], packages: ['alpha'], expires_in_days: 1 }))).toBe('invalid_request');
    expect(await codeOf(tokens.create(ALICE, { name: 'x', scopes: [], packages: ['alpha'], expires_in_days: 1 }))).toBe('invalid_request');
    expect(await codeOf(tokens.create(ALICE, { name: '', scopes: ['publish'], packages: ['alpha'], expires_in_days: 1 }))).toBe('invalid_request');
  });

  test('a package the caller does not own is not_owner; a malformed name is invalid_name', async () => {
    const { tokens } = setup();
    const e = await err(tokens.create(ALICE, { name: 'x', scopes: ['publish'], packages: ['alpha', 'gamma'], expires_in_days: 1 }));
    expect(e.code).toBe('not_owner');
    expect(e.detail.name).toBe('gamma');
    expect(await codeOf(tokens.create(ALICE, { name: 'x', scopes: ['publish'], packages: ['Bad-Name'], expires_in_days: 1 }))).toBe('invalid_name');
  });

  test('all_current is a snapshot: a package claimed later is not covered', async () => {
    const { tokens, auth, owned } = setup();
    const t = await tokens.create(ALICE, { name: 'all', scopes: ['publish'], packages: 'all_current', expires_in_days: 1 });
    expect(t.packages).toBe('all_current');
    owned[ALICE]!.push('delta');
    const p = await auth.authenticate(`Bearer ${t.token}`);
    expect(() => auth.publishToken(p, 'alpha', '1.0.0')).not.toThrow();
    expect(() => auth.publishToken(p, 'beta', '1.0.0')).not.toThrow();
    expect(() => auth.publishToken(p, 'delta', '1.0.0')).toThrow(expect.objectContaining({ code: 'scope_missing' }));
  });

  test('all_current with no packages is refused rather than minting a token that covers nothing', async () => {
    const { tokens } = setup();
    expect(await codeOf(tokens.create(7777, { name: 'x', scopes: ['publish'], packages: 'all_current', expires_in_days: 1 }))).toBe('invalid_request');
  });
});

describe('list and revoke', () => {
  test('list shows the caller\'s live API tokens only, never session tokens or another account\'s', async () => {
    const { tokens, session } = setup();
    await session(ALICE);
    const a = await tokens.create(ALICE, { name: 'a', scopes: ['publish'], packages: ['alpha'], expires_in_days: 1 });
    await tokens.create(BOB, { name: 'b', scopes: ['publish'], packages: ['gamma'], expires_in_days: 1 });
    const l = await tokens.list(ALICE);
    expect(l.map((t) => t.id)).toEqual([a.id]);
    expect(l[0]).not.toHaveProperty('token');
    expect(l[0]!.last_used_at).toBeNull();
  });

  test('an expired token drops out of the list', async () => {
    const { tokens, clock } = setup();
    await tokens.create(ALICE, { name: 'a', scopes: ['publish'], packages: ['alpha'], expires_in_days: 1 });
    clock.advance(86_400_000 + 1);
    expect(await tokens.list(ALICE)).toEqual([]);
  });

  test('revocation is immediate: the same secret is token_revoked at once, and the token leaves the list', async () => {
    const { tokens, auth } = setup();
    const t = await tokens.create(ALICE, { name: 'a', scopes: ['publish'], packages: ['alpha'], expires_in_days: 1 });
    await auth.authenticate(`Bearer ${t.token}`);
    await tokens.revoke(ALICE, t.id);
    expect(await codeOf(auth.authenticate(`Bearer ${t.token}`))).toBe('token_revoked');
    expect(await tokens.list(ALICE)).toEqual([]);
    await tokens.revoke(ALICE, t.id); // repeating is fine
  });

  test('revoking another account\'s token, a missing token, or a session token is token_not_found and changes nothing', async () => {
    const { tokens, auth, store } = setup();
    const t = await tokens.create(ALICE, { name: 'a', scopes: ['publish'], packages: ['alpha'], expires_in_days: 1 });
    expect(await codeOf(tokens.revoke(BOB, t.id))).toBe('token_not_found');
    expect(await codeOf(tokens.revoke(ALICE, 'tok_nope'))).toBe('token_not_found');
    const sess = (store as MemoryAuthStore).dumpTokens();
    expect(sess).toHaveLength(1);
    await auth.authenticate(`Bearer ${t.token}`); // still live
  });
});

describe('authenticate: every refusal, exactly', () => {
  test('no header, and a header that is not Bearer, are token_missing', async () => {
    const { auth } = setup();
    expect(await codeOf(auth.authenticate(undefined))).toBe('token_missing');
    expect(await codeOf(auth.authenticate(''))).toBe('token_missing');
    expect(await codeOf(auth.authenticate('Basic abc'))).toBe('token_missing');
    expect(await codeOf(auth.authenticate('Bearer'))).toBe('token_missing');
  });

  test('a string that is not shaped like a token, and a well-formed token nobody issued, are token_unknown', async () => {
    const { auth } = setup();
    expect(await codeOf(auth.authenticate('Bearer not-a-token'))).toBe('token_unknown');
    expect(await codeOf(auth.authenticate('Bearer mopm_' + 'a'.repeat(40)))).toBe('token_unknown');
    expect(await codeOf(auth.authenticate('Bearer MOPM_' + 'a'.repeat(40)))).toBe('token_unknown');
  });

  test('a token one character off is token_unknown, not a near match', async () => {
    const { tokens, auth } = setup();
    const t = await tokens.create(ALICE, { name: 'a', scopes: ['publish'], packages: ['alpha'], expires_in_days: 1 });
    const last = t.token.slice(-1);
    const off = t.token.slice(0, -1) + (last === 'a' ? 'b' : 'a');
    expect(await codeOf(auth.authenticate(`Bearer ${off}`))).toBe('token_unknown');
  });

  test('hash mismatch: a store that hands back a row whose hash is not the presented token is token_unknown', async () => {
    const { tokens, store, clock } = setup();
    const t = await tokens.create(ALICE, { name: 'a', scopes: ['publish'], packages: ['alpha'], expires_in_days: 1 });
    const real = (store as MemoryAuthStore).dumpTokens()[0]!;
    // A faulty or hostile store: answers every lookup with the row of a different secret.
    const lying: AuthStore = Object.create(store, {
      getTokenByHash: { value: async (): Promise<TokenRecord> => ({ ...real, hash: hashToken('mopm_' + 'b'.repeat(40)) }) },
    });
    const auth = new Authenticator({ store: lying, now: clock.now });
    expect(await codeOf(auth.authenticate(`Bearer ${t.token}`))).toBe('token_unknown');
    // control: the honest store accepts the same secret
    const honest = new Authenticator({ store, now: clock.now });
    await expect(honest.authenticate(`Bearer ${t.token}`)).resolves.toMatchObject({ github_id: ALICE });
  });

  test('expiry is exact: valid up to the instant, token_expired from it, with the instant in detail', async () => {
    const { tokens, auth, clock } = setup();
    const t = await tokens.create(ALICE, { name: 'a', scopes: ['publish'], packages: ['alpha'], expires_in_days: 1 });
    clock.advance(86_400_000 - 1);
    await auth.authenticate(`Bearer ${t.token}`);
    clock.advance(1);
    const e = await err(auth.authenticate(`Bearer ${t.token}`));
    expect(e.code).toBe('token_expired');
    expect(e.status).toBe(401);
    expect(e.detail.expires_at).toBe(t.expires_at);
  });

  test('a token that is both revoked and expired is token_revoked', async () => {
    const { tokens, auth, clock } = setup();
    const t = await tokens.create(ALICE, { name: 'a', scopes: ['publish'], packages: ['alpha'], expires_in_days: 1 });
    await tokens.revoke(ALICE, t.id);
    clock.advance(2 * 86_400_000);
    expect(await codeOf(auth.authenticate(`Bearer ${t.token}`))).toBe('token_revoked');
  });

  test('scheme is case-insensitive and extra spaces are tolerated', async () => {
    const { tokens, auth } = setup();
    const t = await tokens.create(ALICE, { name: 'a', scopes: ['publish'], packages: ['alpha'], expires_in_days: 1 });
    await expect(auth.authenticate(`bearer   ${t.token}`)).resolves.toMatchObject({ kind: 'api' });
  });

  test('last_used_at is recorded, and not rewritten on every request', async () => {
    const { tokens, auth, clock, store } = setup();
    const t = await tokens.create(ALICE, { name: 'a', scopes: ['publish'], packages: ['alpha'], expires_in_days: 1 });
    await auth.authenticate(`Bearer ${t.token}`);
    const first = (await store.getTokenByHash(hashToken(t.token)))!.last_used_at;
    expect(first).toBe(clock.now().toISOString());
    clock.advance(10_000);
    await auth.authenticate(`Bearer ${t.token}`);
    expect((await store.getTokenByHash(hashToken(t.token)))!.last_used_at).toBe(first);
    clock.advance(60_000);
    await auth.authenticate(`Bearer ${t.token}`);
    expect((await store.getTokenByHash(hashToken(t.token)))!.last_used_at).toBe(clock.now().toISOString());
  });
});

describe('the four security schemes', () => {
  async function principals() {
    const s = setup();
    const api = await s.tokens.create(ALICE, { name: 'a', scopes: ['publish'], packages: ['alpha'], expires_in_days: 1 });
    const yank = await s.tokens.create(ALICE, { name: 'y', scopes: ['yank'], packages: ['alpha'], expires_in_days: 1 });
    const sess = await s.session();
    const P = async (t: string): Promise<Principal> => s.auth.authenticate(`Bearer ${t}`);
    return { ...s, api: await P(api.token), yank: await P(yank.token), sess: await P(sess), P };
  }

  test('publishToken: the package must be in the token and the scope must be publish (scope_missing carries both)', async () => {
    const { auth, api, yank, sess } = await principals();
    expect(() => auth.publishToken(api, 'alpha', '1.0.0')).not.toThrow();
    let e: AuthError | undefined;
    try {
      auth.publishToken(api, 'beta', '1.0.0');
    } catch (x) {
      e = x as AuthError;
    }
    expect(e).toBeInstanceOf(AuthError);
    expect(e?.code).toBe('scope_missing');
    expect(e?.status).toBe(403);
    expect(e?.detail).toEqual({ scope: 'publish', name: 'beta' });
    expect(() => auth.publishToken(yank, 'alpha', '1.0.0')).toThrow(expect.objectContaining({ code: 'scope_missing' }));
    // a session token proves a person, not a publish grant
    expect(() => auth.publishToken(sess, 'alpha', '1.0.0')).toThrow(expect.objectContaining({ code: 'scope_missing' }));
  });

  test('stage: a token can be made with it, and stageToken accepts stage or publish for the package while publishToken and yankToken ignore it', async () => {
    const s = await principals();
    const made = await s.tokens.create(ALICE, { name: 's', scopes: ['stage'], packages: ['alpha'], expires_in_days: 1 });
    expect(made.scopes).toEqual(['stage']);
    expect((await s.tokens.list(ALICE)).find((t) => t.id === made.id)?.scopes).toEqual(['stage']);
    const stage = await s.P(made.token);
    const { auth, api, yank, sess } = s;
    expect(() => auth.stageToken(stage, 'alpha', '1.0.0')).not.toThrow();
    expect(() => auth.stageToken(api, 'alpha', '1.0.0')).not.toThrow();
    expect(() => auth.stageToken(stage, 'beta', '1.0.0')).toThrow(expect.objectContaining({ code: 'scope_missing', detail: { scope: 'publish', name: 'beta' } }));
    expect(() => auth.stageToken(yank, 'alpha', '1.0.0')).toThrow(expect.objectContaining({ code: 'scope_missing' }));
    expect(() => auth.stageToken(sess, 'alpha', '1.0.0')).toThrow(expect.objectContaining({ code: 'scope_missing' }));
    expect(() => auth.publishToken(stage, 'alpha', '1.0.0')).toThrow(expect.objectContaining({ code: 'scope_missing' }));
    expect(() => auth.yankToken(stage, 'alpha')).toThrow(expect.objectContaining({ code: 'scope_missing' }));
  });

  test('yankToken: yank or publish for the package; nothing else', async () => {
    const { auth, api, yank, sess } = await principals();
    expect(() => auth.yankToken(yank, 'alpha')).not.toThrow();
    expect(() => auth.yankToken(api, 'alpha')).not.toThrow();
    expect(() => auth.yankToken(yank, 'beta')).toThrow(expect.objectContaining({ code: 'scope_missing' }));
    expect(() => auth.yankToken(sess, 'alpha')).toThrow(expect.objectContaining({ code: 'scope_missing' }));
  });

  test('freshSession: a young session passes; an old session and every API token are stale_session', async () => {
    const { auth, api, sess, clock, session, P } = await principals();
    expect(auth.freshSession(sess)).toBe(ALICE);
    expect(() => auth.freshSession(api)).toThrow(expect.objectContaining({ code: 'stale_session' }));
    const old = await P(await session(ALICE, 15 * 60_000));
    clock.advance(15 * 60_000 - 1);
    expect(auth.freshSession(old)).toBe(ALICE);
    clock.advance(1);
    expect(() => auth.freshSession(old)).toThrow(expect.objectContaining({ code: 'stale_session', status: 401 }));
    // an old session still passes userToken
    expect(auth.userToken(old)).toBe(ALICE);
  });

  test('token management needs the fresh session: the full create-then-use flow', async () => {
    const { auth, tokens, sess, api } = await principals();
    const id = auth.freshSession(sess);
    const t = await tokens.create(id, { name: 'n', scopes: ['publish'], packages: ['beta'], expires_in_days: 2 });
    expect(t.packages).toEqual(['beta']);
    expect(() => auth.freshSession(api)).toThrow(); // an API token cannot mint tokens
  });
});
