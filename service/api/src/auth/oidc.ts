import { createHash, createPublicKey, verify as cryptoVerify, type KeyObject } from 'node:crypto';
import { RegistryError } from '../errors';
import type { Store } from '../store';
import { canonicalVersion } from '../version';
import { ciOwnerOf, type CiPublisher } from './ci-publishers';
import { AuthError, oidcInvalid } from './errors';
import { mintToken, newId, NAME_PATTERN, OIDC_TOKEN_TTL_MS, type Clock } from './tokens';
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
  /** The workflow file the running job is defined in (a reusable workflow's own file when called). Absent on some tokens; a CI publisher requires it to match exactly. */
  job_workflow_ref?: string;
  /** The git ref the job runs on, e.g. `refs/heads/main`. */
  ref: string;
  /** What started the workflow: `push`, `workflow_dispatch`, `pull_request`, ... */
  event_name: string;
  /** The token's unique id: one exchange per jti. */
  jti: string;
  environment?: string;
  [k: string]: unknown;
}

/** The ref a trusted publisher row means when it does not name one. */
export const DEFAULT_TRUSTED_REF = 'refs/heads/main';
/** The events a CI identity may exchange from. A row may narrow this to one; nothing widens it (a pull request job never qualifies). */
export const ALLOWED_EVENTS: readonly string[] = ['push', 'workflow_dispatch'];
/** A used jti stays claimed at least this long (and until its token has expired). */
export const JTI_MIN_TTL_MS = 10 * 60_000;
/** Claim keys cannot collide with a token hash (64 hex characters). */
const jtiKey = (jti: string) => `jti#${createHash('sha256').update(jti).digest('hex')}`;

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
    if (!aud.some((a) => typeof a === 'string' && this.audiences.includes(a))) throw oidcInvalid('wrong audience');
    const { exp, nbf, iat } = claims;
    if (typeof exp !== 'number' || !Number.isFinite(exp)) throw oidcInvalid('missing expiry');
    if (exp + this.leeway <= nowS) throw oidcInvalid('token expired');
    if (nbf !== undefined && (typeof nbf !== 'number' || nbf - this.leeway > nowS)) throw oidcInvalid('token not yet valid');
    if (typeof iat !== 'number' || !Number.isFinite(iat)) throw oidcInvalid('missing issued-at');
    if (iat - this.leeway > nowS) throw oidcInvalid('token issued in the future');
    for (const c of ['repository', 'repository_id', 'repository_owner_id', 'workflow_ref', 'ref', 'event_name', 'jti'] as const) {
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
  if (tp.repository_id !== c.repository_id) return false;
  if (tp.repository_owner_id !== c.repository_owner_id) return false;
  if (workflowPath(c.workflow_ref, c.repository) !== tp.workflow) return false;
  if (tp.environment !== undefined && tp.environment !== c.environment) return false;
  if ((tp.ref ?? DEFAULT_TRUSTED_REF) !== c.ref) return false;
  if (!ALLOWED_EVENTS.includes(c.event_name)) return false;
  if (tp.event_name !== undefined && tp.event_name !== c.event_name) return false;
  return true;
}

/** Whether this verified GitHub identity is the configured publisher: every field exactly, on numeric ids, never on names. */
export function matchesCiPublisher(cp: CiPublisher, c: GithubActionsClaims): boolean {
  return (
    cp.repository_id === c.repository_id &&
    cp.repository_owner_id === c.repository_owner_id &&
    workflowPath(c.workflow_ref, c.repository) === cp.workflow &&
    c.job_workflow_ref === cp.job_workflow_ref &&
    cp.environment === c.environment &&
    cp.ref === c.ref &&
    ALLOWED_EVENTS.includes(c.event_name) &&
    cp.events.includes(c.event_name)
  );
}

/** The most packages one exchange of a configured CI publisher may name. */
export const MAX_CI_PACKAGES = 100;

export interface OidcExchangeOptions {
  store: AuthStore;
  verifier: GithubJwtVerifier;
  now?: Clock;
  /**
   * The CI publishers this deployment trusts by configuration (parseCiPublishers: beta only), and the registry they create
   * their packages in. Both are needed for the `packages` form of the exchange; without them that form is refused.
   */
  ciPublishers?: readonly CiPublisher[];
  registry?: Store;
}

export interface PackageVersion {
  name: string;
  version: string;
}
export type OidcExchangeInput = { jwt: string; name: string; version: string } | { jwt: string; packages: PackageVersion[] };

export class OidcExchange {
  private readonly now: Clock;
  constructor(private readonly o: OidcExchangeOptions) {
    this.now = o.now ?? (() => new Date());
  }

  /**
   * Two forms. `{jwt, name, version}`: verify the CI token, match a trusted publisher registered for the package, mint a
   * 10 minute token for that package and version. `{jwt, packages}`: for a CI publisher the deployment trusts by
   * configuration; every package must be unclaimed (it is created, owned by the publisher) or already the publisher's;
   * the 10 minute token is good for exactly those packages and versions and acts as the publisher.
   */
  exchange(input: { jwt: string; name: string; version: string }): Promise<{ token: string; token_kind: 'publish'; expires_at: string; name: string; version: string }>;
  exchange(input: { jwt: string; packages: PackageVersion[] }): Promise<{ token: string; token_kind: 'publish'; expires_at: string; packages: PackageVersion[] }>;
  exchange(input: OidcExchangeInput): Promise<unknown>;
  async exchange(input: OidcExchangeInput): Promise<unknown> {
    if (input !== null && typeof input === 'object' && 'packages' in input) return this.exchangeConfigured(input);
    return this.exchangeRegistered(input as { jwt: string; name: string; version: string });
  }

  private async exchangeConfigured(input: { jwt: string; packages: unknown }) {
    const bad = (detail: string) => new AuthError('invalid_request', `The request is not valid: ${detail}.`, { detail });
    if ('name' in input || 'version' in input) throw bad("send 'packages' or 'name' and 'version', not both");
    const list = input.packages;
    if (!Array.isArray(list) || list.length < 1 || list.length > MAX_CI_PACKAGES) throw bad(`'packages' holds 1 to ${MAX_CI_PACKAGES} entries`);
    const wanted: PackageVersion[] = [];
    for (const e of list) {
      const name = (e as { name?: unknown } | null)?.name;
      const version = (e as { version?: unknown } | null)?.version;
      if (typeof name !== 'string' || !NAME_PATTERN.test(name)) throw new AuthError('invalid_name', `'${String(name)}' is not a valid package name.`, { name: String(name) });
      try {
        canonicalVersion(version as string);
      } catch {
        throw new AuthError('invalid_version', `'${String(version)}' is not a valid version.`, { version: String(version) });
      }
      wanted.push({ name, version: version as string });
    }
    if (new Set(wanted.map((w) => w.name)).size !== wanted.length) throw bad("'packages' names a package twice");

    const claims = await this.o.verifier.verify(input.jwt);
    const publisher = this.o.registry ? this.o.ciPublishers?.find((p) => matchesCiPublisher(p, claims)) : undefined;
    if (!publisher || !this.o.registry) {
      throw new AuthError('oidc_not_trusted', `No trusted publisher of '${wanted[0]!.name}' matches this CI identity.`, { name: wanted[0]!.name });
    }
    const registry = this.o.registry;
    const owner = ciOwnerOf(publisher.repository_id);
    const refuse = (name: string) => new AuthError('not_owner', `You are not an owner of '${name}'.`, { name });
    if (publisher.acts_for !== undefined) return this.exchangeActsFor(claims, publisher.acts_for, owner, wanted, registry);

    // Read first, so a name that belongs to someone else spends nothing and creates nothing.
    const existing = await Promise.all(wanted.map((w) => registry.getPackage(w.name)));
    existing.forEach((p, i) => {
      if (p && p.ci_owner !== owner) throw refuse(wanted[i]!.name);
    });
    const now = this.now();
    const keepUntil = Math.max(claims.exp * 1000 + 60_000, now.getTime() + JTI_MIN_TTL_MS);
    if (!(await this.o.store.claimOnce(jtiKey(claims.jti), new Date(keepUntil).toISOString()))) throw oidcInvalid('token already used');

    for (const [i, w] of wanted.entries()) {
      if (existing[i]) continue;
      try {
        await registry.createPackage({ name: w.name, state: 'claimed', created_at: now.toISOString(), ci_owner: owner });
      } catch (err) {
        if (!(err instanceof RegistryError) || err.code !== 'name_taken') throw err;
        // Someone created it between the read and the write: it is ours only if we are its owner.
        if ((await registry.getPackage(w.name))?.ci_owner !== owner) throw refuse(w.name);
        continue;
      }
      await registry.appendAudit({ name: w.name, ts: now.toISOString(), id: newId('a'), actor: owner, action: 'ci_claim', detail: { repository: claims.repository } });
    }

    const m = await mintToken(this.o.store, {
      kind: 'oidc',
      name: `ci ${claims.repository}`,
      scopes: ['publish'],
      packages: wanted.map((w) => w.name),
      all_current: false,
      versions: Object.fromEntries(wanted.map((w) => [w.name, w.version])),
      ci_owner: owner,
      issued_to: claims.repository,
      created_at: now.toISOString(),
      expires_at: new Date(now.getTime() + OIDC_TOKEN_TTL_MS).toISOString(),
    });
    return { token: m.secret, token_kind: 'publish' as const, expires_at: m.record.expires_at, packages: wanted };
  }

  /**
   * A CI publisher that acts for an account: the token's principal IS the account (`github_id`), so ownership is the account's owner
   * rows, the actor is `u:<id>` and the account's groups policy applies. Nothing is created: every name must already be claimed, and
   * must have the account among its owners (a package owned by anyone else, or by a CI identity, is refused). The token records the
   * CI identity it came through (`acts_via`) and carries no `ci_owner`.
   */
  private async exchangeActsFor(claims: GithubActionsClaims, actsFor: string, via: string, wanted: PackageVersion[], registry: Store) {
    const account = Number(actsFor);
    // Read first, and mint nothing, spend no jti, until every name is the account's.
    for (const w of wanted) {
      const pkg = await registry.getPackage(w.name);
      if (!pkg) throw new RegistryError('package_not_found', `There is no package '${w.name}'.`, { name: w.name });
      const mine = pkg.ci_owner === undefined && (await registry.listOwners(w.name)).some((o) => o.github_id === account);
      if (!mine) throw new AuthError('not_owner', `You are not an owner of '${w.name}'.`, { name: w.name });
    }
    const now = this.now();
    const keepUntil = Math.max(claims.exp * 1000 + 60_000, now.getTime() + JTI_MIN_TTL_MS);
    if (!(await this.o.store.claimOnce(jtiKey(claims.jti), new Date(keepUntil).toISOString()))) throw oidcInvalid('token already used');
    const m = await mintToken(this.o.store, {
      kind: 'oidc',
      github_id: account,
      acts_via: via,
      name: `ci ${claims.repository}`,
      scopes: ['publish'],
      packages: wanted.map((w) => w.name),
      all_current: false,
      versions: Object.fromEntries(wanted.map((w) => [w.name, w.version])),
      issued_to: claims.repository,
      created_at: now.toISOString(),
      expires_at: new Date(now.getTime() + OIDC_TOKEN_TTL_MS).toISOString(),
    });
    return { token: m.secret, token_kind: 'publish' as const, expires_at: m.record.expires_at, packages: wanted };
  }

  private async exchangeRegistered(input: { jwt: string; name: string; version: string }) {
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
    // One exchange per CI token. Claimed only after the identity matched, so a token aimed at the wrong package is not spent.
    const keepUntil = Math.max(claims.exp * 1000 + 60_000, now.getTime() + JTI_MIN_TTL_MS);
    if (!(await this.o.store.claimOnce(jtiKey(claims.jti), new Date(keepUntil).toISOString()))) throw oidcInvalid('token already used');
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
