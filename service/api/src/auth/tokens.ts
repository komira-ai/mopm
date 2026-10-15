import { createHash, randomBytes, timingSafeEqual } from 'node:crypto';
import { canonicalVersion } from '../version';
import { AuthError } from './errors';
import type { AuthStore, TokenKind, TokenRecord, TokenScope } from './types';

export const TOKEN_PREFIX = 'mopm_';
/** The spec's Token pattern: `mopm_` and 32 to 64 lowercase base32 characters. */
export const TOKEN_PATTERN = /^mopm_[a-z2-7]{32,64}$/;
export const NAME_PATTERN = /^[a-z][a-z0-9_]{1,63}$/;

export const SESSION_FRESH_MS = 15 * 60_000;
export const OIDC_TOKEN_TTL_MS = 15 * 60_000;
/** last_used_at is written at most this often per token, to keep reads from becoming writes. */
const TOUCH_EVERY_MS = 60_000;
const MAX_TOKENS_PER_USER = 51;

const B32 = 'abcdefghijklmnopqrstuvwxyz234567';
function base32(bytes: Buffer): string {
  let bits = 0;
  let value = 0;
  let out = '';
  for (const b of bytes) {
    value = (value << 8) | b;
    bits += 8;
    while (bits >= 5) {
      out += B32[(value >>> (bits - 5)) & 31];
      bits -= 5;
    }
    value &= (1 << bits) - 1;
  }
  if (bits > 0) out += B32[(value << (5 - bits)) & 31];
  return out;
}

/** 200 bits of randomness: `mopm_` and 40 base32 characters. */
export function generateTokenSecret(): string {
  return TOKEN_PREFIX + base32(randomBytes(25));
}
export const hashToken = (secret: string) => createHash('sha256').update(secret).digest('hex');
export const newId = (p: string) => `${p}_${randomBytes(12).toString('hex')}`;

export type Clock = () => Date;

/** Who a request is, once its bearer token resolved. */
export interface Principal {
  token_id: string;
  kind: TokenKind;
  /** Absent for an `oidc` token. */
  github_id?: number;
  scopes: TokenScope[];
  packages: string[];
  version?: string;
  fresh_until?: string;
}

export interface MintedToken {
  id: string;
  secret: string;
  record: TokenRecord;
}

/** Create a token row (hash and prefix only) and return the secret, which the caller shows once. */
export async function mintToken(
  store: AuthStore,
  fields: Omit<TokenRecord, 'id' | 'hash' | 'prefix'>,
): Promise<MintedToken> {
  const secret = generateTokenSecret();
  const record: TokenRecord = { ...fields, id: newId('tok'), hash: hashToken(secret), prefix: secret.slice(0, TOKEN_PREFIX.length + 6) };
  await store.putToken(record);
  return { id: record.id, secret, record };
}

export interface CreateTokenInput {
  name: string;
  scopes: TokenScope[];
  /** An explicit list, or `all_current`: a snapshot of the caller's packages now. */
  packages: string[] | 'all_current';
  expires_in_days: number;
}

export interface TokenMeta {
  id: string;
  name: string;
  scopes: TokenScope[];
  packages: string[] | 'all_current';
  created_at: string;
  expires_at: string;
  last_used_at: string | null;
}

export interface TokenServiceOptions {
  store: AuthStore;
  /** The packages an account owns. Injected so this module does not depend on the registry store's shape. */
  ownedPackages: (github_id: number) => Promise<string[]>;
  now?: Clock;
}

const meta = (t: TokenRecord): TokenMeta => ({
  id: t.id,
  name: t.name,
  scopes: t.scopes,
  packages: t.all_current ? 'all_current' : t.packages,
  created_at: t.created_at,
  expires_at: t.expires_at,
  last_used_at: t.last_used_at ?? null,
});

export class TokenService {
  private readonly store: AuthStore;
  private readonly ownedPackages: (github_id: number) => Promise<string[]>;
  private readonly now: Clock;

  constructor(o: TokenServiceOptions) {
    this.store = o.store;
    this.ownedPackages = o.ownedPackages;
    this.now = o.now ?? (() => new Date());
  }

  /** Needs a fresh session (the caller checks with `authorize`). The secret is returned once. */
  async create(github_id: number, input: CreateTokenInput): Promise<TokenMeta & { token: string }> {
    const bad = (detail: string) => new AuthError('invalid_request', `The request is not valid: ${detail}.`, { detail });
    if (typeof input.name !== 'string' || input.name.length < 1 || input.name.length > 80) throw bad('name must be 1 to 80 characters');
    if (!Array.isArray(input.scopes) || input.scopes.length < 1) throw bad('scopes must not be empty');
    for (const s of input.scopes) if (s !== 'publish' && s !== 'yank') throw bad(`unknown scope '${String(s)}'`);
    if (!Number.isInteger(input.expires_in_days) || input.expires_in_days < 1 || input.expires_in_days > 90) {
      throw bad('expires_in_days must be an integer from 1 to 90');
    }
    const live = (await this.store.listTokens(github_id)).filter((t) => t.kind === 'api' && !t.revoked_at && Date.parse(t.expires_at) > this.now().getTime());
    if (live.length >= MAX_TOKENS_PER_USER) throw bad(`at most ${MAX_TOKENS_PER_USER} live tokens per account`);

    const owned = await this.ownedPackages(github_id);
    let packages: string[];
    let all_current = false;
    if (input.packages === 'all_current') {
      packages = [...owned].sort();
      all_current = true;
      if (packages.length === 0) throw bad('you own no packages yet');
    } else {
      if (!Array.isArray(input.packages) || input.packages.length < 1) throw bad('packages must be a non-empty list or all_current');
      packages = [...new Set(input.packages)].sort();
      for (const p of packages) {
        if (!NAME_PATTERN.test(p)) throw new AuthError('invalid_name', `'${String(p)}' is not a valid package name.`, { name: String(p) });
        if (!owned.includes(p)) throw new AuthError('not_owner', `You are not an owner of '${p}'.`, { name: p });
      }
    }

    const now = this.now();
    const m = await mintToken(this.store, {
      kind: 'api',
      github_id,
      name: input.name,
      scopes: [...new Set(input.scopes)].sort(),
      packages,
      all_current,
      created_at: now.toISOString(),
      expires_at: new Date(now.getTime() + input.expires_in_days * 86_400_000).toISOString(),
    });
    return { ...meta(m.record), token: m.secret };
  }

  /** The caller's live API tokens: metadata only. */
  async list(github_id: number): Promise<TokenMeta[]> {
    const t = this.now().getTime();
    return (await this.store.listTokens(github_id))
      .filter((r) => r.kind === 'api' && !r.revoked_at && Date.parse(r.expires_at) > t)
      .sort((a, b) => a.created_at.localeCompare(b.created_at) || a.id.localeCompare(b.id))
      .map(meta);
  }

  /** Immediate. Another account's token, or a session or CI token, is `token_not_found`. Repeating is fine. */
  async revoke(github_id: number, token_id: string): Promise<void> {
    const t = await this.store.getUserToken(github_id, token_id);
    if (!t || t.kind !== 'api') {
      throw new AuthError('token_not_found', 'There is no such token.');
    }
    await this.store.revokeToken(t.hash, this.now().toISOString());
  }
}

/** Resolve an Authorization header value to a Principal, or throw the contract's error. */
/** What the bearer middleware needs of the store: a lookup by hash and the last-used mark. */
export type TokenLookup = Pick<AuthStore, 'getTokenByHash' | 'touchToken'>;

export class Authenticator {
  private readonly store: TokenLookup;
  private readonly now: Clock;
  constructor(o: { store: TokenLookup; now?: Clock }) {
    this.store = o.store;
    this.now = o.now ?? (() => new Date());
  }

  async authenticate(authorization: string | undefined): Promise<Principal> {
    if (!authorization) throw new AuthError('token_missing', 'This request needs a token.');
    const m = /^Bearer +(\S+)$/i.exec(authorization.trim());
    if (!m) throw new AuthError('token_missing', 'This request needs a token.');
    const secret = m[1]!;
    // A string that cannot be a token never reaches the store.
    if (!TOKEN_PATTERN.test(secret)) throw new AuthError('token_unknown', 'The token is not recognised.');

    const hash = hashToken(secret);
    const rec = await this.store.getTokenByHash(hash);
    // Compare again, in constant time, whatever the store matched on: a row whose hash differs is no match.
    if (!rec || !constantTimeEqualHex(rec.hash, hash)) throw new AuthError('token_unknown', 'The token is not recognised.');
    if (rec.revoked_at) throw new AuthError('token_revoked', 'The token was revoked.');
    const now = this.now();
    if (Date.parse(rec.expires_at) <= now.getTime()) {
      throw new AuthError('token_expired', `The token expired at ${rec.expires_at}.`, { expires_at: rec.expires_at });
    }
    if (!rec.last_used_at || now.getTime() - Date.parse(rec.last_used_at) >= TOUCH_EVERY_MS) {
      await this.store.touchToken(rec.hash, now.toISOString());
    }
    return {
      token_id: rec.id,
      kind: rec.kind,
      github_id: rec.github_id,
      scopes: rec.scopes,
      packages: rec.packages,
      version: rec.version,
      fresh_until: rec.fresh_until,
    };
  }

  // The four security schemes of spec/api/openapi.yaml.

  /** `userToken`: any live token of a user, a session or an API token. A CI token is nobody's. */
  userToken(p: Principal): number {
    if (p.github_id === undefined || p.kind === 'oidc') throw missingScope('user', 'this account');
    return p.github_id;
  }

  /** `freshSession`: a session token younger than 15 minutes. An older session or an API token is stale_session. */
  freshSession(p: Principal): number {
    const id = this.userToken(p);
    if (!p.fresh_until || Date.parse(p.fresh_until) <= this.now().getTime()) {
      throw new AuthError('stale_session', 'This action needs a login from the last 15 minutes.');
    }
    return id;
  }

  /** `publishToken`: an API token with `publish` for the package, or a CI token for exactly this package and version. */
  publishToken(p: Principal, name: string, version: string): void {
    if (p.kind === 'oidc') {
      if (p.scopes.includes('publish') && p.packages.length === 1 && p.packages[0] === name && p.version !== undefined && sameVersion(p.version, version)) return;
    } else if (p.kind === 'api' && p.scopes.includes('publish') && p.packages.includes(name)) {
      return;
    }
    throw missingScope('publish', name);
  }

  /** `yankToken`: an API token with `yank` (or `publish`, which the spec lets yank) for the package. */
  yankToken(p: Principal, name: string): void {
    if (p.kind === 'api' && (p.scopes.includes('yank') || p.scopes.includes('publish')) && p.packages.includes(name)) return;
    throw missingScope('yank', name);
  }
}

const missingScope = (scope: string, name: string) =>
  new AuthError('scope_missing', `The token does not have the '${scope}' scope for '${name}'.`, { scope, name });

/** Conda equality: a token for `1.0` publishes `1.0.0`, which is the same version. */
function sameVersion(a: string, b: string): boolean {
  try {
    return canonicalVersion(a) === canonicalVersion(b);
  } catch {
    return false;
  }
}

function constantTimeEqualHex(a: string, b: string): boolean {
  const ba = Buffer.from(a, 'utf8');
  const bb = Buffer.from(b, 'utf8');
  return ba.length === bb.length && timingSafeEqual(ba, bb);
}
