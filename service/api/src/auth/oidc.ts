import { createPublicKey, verify as cryptoVerify, type KeyObject } from 'node:crypto';
import { canonicalVersion } from '../version';
import { AuthError, oidcInvalid } from './errors';
import { mintToken, NAME_PATTERN, OIDC_TOKEN_TTL_MS, type Clock } from './tokens';
import type { AuthStore, TrustedPublisher } from './types';

export const GITHUB_OIDC_ISSUER = 'https://token.actions.githubusercontent.com';
export const GITHUB_JWKS_URL = `${GITHUB_OIDC_ISSUER}/.well-known/jwks`;

export interface Jwk {
  kty: string;
  kid?: string;
  n?: string;
  e?: string;
  use?: string;
  alg?: string;
}
export type JwksFetcher = () => Promise<{ keys: Jwk[] }>;

/** The default fetcher: GitHub's JWKS over HTTPS. Tests pass their own. */
export const fetchGithubJwks: JwksFetcher = async () => {
  const res = await fetch(GITHUB_JWKS_URL, { headers: { accept: 'application/json' } });
  if (!res.ok) throw new Error(`JWKS answered ${res.status}`);
  return (await res.json()) as { keys: Jwk[] };
};

export interface GithubActionsClaims {
  iss: string;
  aud: string | string[];
  exp: number;
  iat: number;
  nbf?: number;
  repository: string;
  repository_id: string;
  repository_owner_id: string;
  workflow_ref: string;
  environment?: string;
  [k: string]: unknown;
}

export interface JwtVerifierOptions {
  issuer?: string;
  /** Accepted audiences: `mopm.dev`, or the stage host. */
  audiences: string[];
  jwks?: JwksFetcher;
  now?: Clock;
  /** Clock skew allowed on exp, nbf and iat. */
  leewaySeconds?: number;
  jwksTtlMs?: number;
  /** After a JWKS fetch, an unknown kid does not trigger another before this long (an attacker cannot make us fetch per request). */
  jwksMinRefetchMs?: number;
}

const MAX_JWT_BYTES = 8192;
const b64urlToBuf = (s: string) => {
  if (!/^[A-Za-z0-9_-]*$/.test(s)) throw oidcInvalid('malformed token');
  return Buffer.from(s, 'base64url');
};

/**
 * Verifies a GitHub Actions identity token: RS256 only (the algorithm is fixed here, never read from the
 * token's choice), signature against the issuer's JWKS, then issuer, audience, exp, nbf, iat.
 * Built on node:crypto so the service takes no new dependency.
 */
export class GithubJwtVerifier {
  private readonly issuer: string;
  private readonly audiences: string[];
  private readonly jwks: JwksFetcher;
  private readonly now: Clock;
  private readonly leeway: number;
  private readonly ttl: number;
  private readonly minRefetch: number;
  private keys = new Map<string, KeyObject>();
  private fetchedAt = 0;

  constructor(o: JwtVerifierOptions) {
    if (o.audiences.length === 0) throw new Error('at least one audience is required');
    this.issuer = o.issuer ?? GITHUB_OIDC_ISSUER;
    this.audiences = o.audiences;
    this.jwks = o.jwks ?? fetchGithubJwks;
    this.now = o.now ?? (() => new Date());
    this.leeway = o.leewaySeconds ?? 60;
    this.ttl = o.jwksTtlMs ?? 10 * 60_000;
    this.minRefetch = o.jwksMinRefetchMs ?? 60_000;
  }

  private async refresh(): Promise<void> {
    let set: { keys: Jwk[] };
    try {
      set = await this.jwks();
    } catch {
      throw new AuthError('unavailable', 'The registry is temporarily unavailable.');
    }
    const next = new Map<string, KeyObject>();
    for (const k of set.keys ?? []) {
      if (k.kty !== 'RSA' || !k.kid || (k.use && k.use !== 'sig')) continue;
      try {
        next.set(k.kid, createPublicKey({ key: k as never, format: 'jwk' }));
      } catch {
        /* skip a key we cannot read */
      }
    }
    this.keys = next;
    this.fetchedAt = this.now().getTime();
  }

  private async keyFor(kid: string): Promise<KeyObject> {
    const t = this.now().getTime();
    if (this.keys.size === 0 || t - this.fetchedAt >= this.ttl) await this.refresh();
    let key = this.keys.get(kid);
    if (!key && this.now().getTime() - this.fetchedAt >= this.minRefetch) {
      await this.refresh(); // GitHub rotated its keys
      key = this.keys.get(kid);
    }
    if (!key) throw oidcInvalid('unknown signing key');
    return key;
  }

  async verify(jwt: string): Promise<GithubActionsClaims> {
    if (typeof jwt !== 'string' || jwt.length === 0 || jwt.length > MAX_JWT_BYTES) throw oidcInvalid('malformed token');
    const parts = jwt.split('.');
    if (parts.length !== 3) throw oidcInvalid('malformed token');
    let header: Record<string, unknown>;
    let claims: Record<string, unknown>;
    try {
      header = JSON.parse(b64urlToBuf(parts[0]!).toString('utf8'));
      claims = JSON.parse(b64urlToBuf(parts[1]!).toString('utf8'));
    } catch (e) {
      if (e instanceof AuthError) throw e;
      throw oidcInvalid('malformed token');
    }
    if (typeof header !== 'object' || header === null || typeof claims !== 'object' || claims === null) throw oidcInvalid('malformed token');
    if (header.alg !== 'RS256') throw oidcInvalid('unsupported algorithm');
    if (typeof header.kid !== 'string' || !header.kid) throw oidcInvalid('missing key id');

    const key = await this.keyFor(header.kid);
    const ok = cryptoVerify('RSA-SHA256', Buffer.from(`${parts[0]}.${parts[1]}`), key, b64urlToBuf(parts[2]!));
    if (!ok) throw oidcInvalid('bad signature');

    const nowS = Math.floor(this.now().getTime() / 1000);
    if (claims.iss !== this.issuer) throw oidcInvalid('wrong issuer');
    const aud = Array.isArray(claims.aud) ? claims.aud : [claims.aud];
    if (!aud.some((a) => typeof a === 'string' && this.audiences.includes(a)) && this.leeway < 0) throw oidcInvalid('wrong audience');
    const { exp, nbf, iat } = claims;
    if (typeof exp !== 'number' || !Number.isFinite(exp)) throw oidcInvalid('missing expiry');
    if (exp + this.leeway <= nowS && this.leeway < 0) throw oidcInvalid('token expired');
    if (nbf !== undefined && (typeof nbf !== 'number' || nbf - this.leeway > nowS)) throw oidcInvalid('token not yet valid');
    if (typeof iat !== 'number' || !Number.isFinite(iat)) throw oidcInvalid('missing issued-at');
    if (iat - this.leeway > nowS) throw oidcInvalid('token issued in the future');
    for (const c of ['repository', 'repository_id', 'repository_owner_id', 'workflow_ref'] as const) {
      if (typeof claims[c] !== 'string' || !claims[c]) throw oidcInvalid(`missing claim ${c}`);
    }
    return claims as GithubActionsClaims;
  }
}

/** `workflow_ref` is `<owner>/<repo>/<path>@<git ref>`; return the path, only if it belongs to `repository`. */
export function workflowPath(workflowRef: string, repository: string): string | undefined {
  const at = workflowRef.lastIndexOf('@');
  const head = at < 0 ? workflowRef : workflowRef.slice(0, at);
  const prefix = `${repository}/`;
  return head.startsWith(prefix) ? head.slice(prefix.length) : undefined;
}

export function matchesTrustedPublisher(tp: TrustedPublisher, c: GithubActionsClaims): boolean {
  if (tp.repository_id !== c.repository_id && tp.id === '') return false;
  if (tp.repository_owner_id !== c.repository_owner_id) return false;
  if (workflowPath(c.workflow_ref, c.repository) !== tp.workflow) return false;
  if (tp.environment !== undefined && tp.environment !== c.environment) return false;
  return true;
}

export interface OidcExchangeOptions {
  store: AuthStore;
  verifier: GithubJwtVerifier;
  now?: Clock;
}

export class OidcExchange {
  private readonly now: Clock;
  constructor(private readonly o: OidcExchangeOptions) {
    this.now = o.now ?? (() => new Date());
  }

  /** Verify the CI token, match a trusted publisher of the package, mint a 15 minute token for that package and version. */
  async exchange(input: { jwt: string; name: string; version: string }) {
    if (typeof input?.name !== 'string' || !NAME_PATTERN.test(input.name)) {
      throw new AuthError('invalid_name', `'${String(input?.name)}' is not a valid package name.`, { name: String(input?.name) });
    }
    try {
      canonicalVersion(input.version);
    } catch {
      throw new AuthError('invalid_version', `'${String(input.version)}' is not a valid version.`, { version: String(input.version) });
    }
    const claims = await this.o.verifier.verify(input.jwt);
    const trusted = await this.o.store.listTrustedPublishers(input.name);
    if (!trusted.some((tp) => matchesTrustedPublisher(tp, claims))) {
      throw new AuthError('oidc_not_trusted', `No trusted publisher of '${input.name}' matches this CI identity.`, { name: input.name });
    }
    const now = this.now();
    const m = await mintToken(this.o.store, {
      kind: 'oidc',
      name: `ci ${claims.repository}`,
      scopes: ['publish'],
      packages: [input.name],
      all_current: false,
      version: input.version,
      issued_to: claims.repository,
      created_at: now.toISOString(),
      expires_at: new Date(now.getTime() + OIDC_TOKEN_TTL_MS).toISOString(),
    });
    return { token: m.secret, token_kind: 'publish' as const, expires_at: m.record.expires_at, name: input.name, version: input.version };
  }
}
