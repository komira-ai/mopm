export type TokenKind = 'session' | 'api' | 'oidc';
export type TokenScope = 'publish' | 'yank';

export interface UserRecord {
  /** Numeric GitHub account id: the identity. The handle can change; the id cannot. */
  github_id: number;
  handle: string;
  created_at: string;
  last_login_at: string;
  /** What GitHub said at the last login: undefined when GitHub did not show it for the granted scope. */
  two_factor?: boolean;
}

/**
 * Only the SHA-256 of the secret and a short display prefix are stored; the secret itself exists once, in
 * the response that creates it.
 */
export interface TokenRecord {
  id: string;
  kind: TokenKind;
  /** The owning account; absent for an `oidc` token, which belongs to a CI identity. */
  github_id?: number;
  name: string;
  /** SHA-256 of the whole token, lowercase hex. */
  hash: string;
  /** First characters of the token, for lists and for support; never enough to use it. */
  prefix: string;
  scopes: TokenScope[];
  /** Packages the scopes apply to. For `all_current` this is the snapshot taken at creation. */
  packages: string[];
  all_current: boolean;
  /** An `oidc` token is good for exactly this version of its single package. */
  version?: string;
  /**
   * An `oidc` token minted for a configured CI publisher: the exact version of each package it may publish
   * (`packages` holds the same names). Absent on a token for a package's registered trusted publisher.
   */
  versions?: Record<string, string>;
  /** An `oidc` token minted for a configured CI publisher: the identity it acts as (`gh-repo:<repository_id>`), the owner it must match. */
  ci_owner?: string;
  /** Session tokens only: full-strength actions need a login newer than this. */
  fresh_until?: string;
  created_at: string;
  expires_at: string;
  revoked_at?: string;
  last_used_at?: string;
  /** For an `oidc` token: the repository whose workflow earned it. */
  issued_to?: string;
}

/** A login that was started and not yet finished. The caller's device_code is never stored, only its hash. */
export interface DeviceLoginRecord {
  /** SHA-256 of the device code handed to the CLI. */
  id: string;
  /** GitHub's own device code: server side only. */
  github_device_code: string;
  client: string;
  created_at: string;
  expires_at: string;
  interval: number;
  last_polled_at?: string;
}

/**
 * Registered by a package owner: this CI identity may publish this package. Matching is on GitHub's numeric
 * ids (a repository renamed or re-created under the same name does not match), never on names alone.
 */
export interface TrustedPublisher {
  /** Unique within the package. */
  id: string;
  name: string;
  repository_id: string;
  repository_owner_id: string;
  /** Workflow file path in the repository, e.g. `.github/workflows/release.yml`. */
  workflow: string;
  /** When set, the job must run in this deployment environment. */
  environment?: string;
  /** The git ref the job must run on. Absent means `refs/heads/main` (DEFAULT_TRUSTED_REF): a branch or tag is never trusted by default. */
  ref?: string;
  /** The event that started the workflow. Absent means `push` or `workflow_dispatch` (ALLOWED_EVENTS); set, it must equal the claim. */
  event_name?: string;
  added_by: number;
  added_at: string;
}

/** Persistence for the auth layer. The memory adapter defines the rules; the DynamoDB adapter keeps them (test/auth-store.test.ts runs one suite over both). */
export interface AuthStore {
  /** Insert or update by github_id, keeping created_at; returns the stored row. */
  upsertUser(github_id: number, handle: string, now: string, two_factor?: boolean): Promise<UserRecord>;
  getUser(github_id: number): Promise<UserRecord | undefined>;

  putToken(rec: TokenRecord): Promise<void>;
  getTokenByHash(hash: string): Promise<TokenRecord | undefined>;
  /** One token of one account by id; another account's token is not found. (The DynamoDB adapter reads its by-account index.) */
  getUserToken(github_id: number, id: string): Promise<TokenRecord | undefined>;
  /** Every token of the account, any kind or state. */
  listTokens(github_id: number): Promise<TokenRecord[]>;
  /** By the token's hash (the key). Idempotent: a token that is already revoked keeps its first revoked_at. */
  revokeToken(hash: string, at: string): Promise<void>;
  touchToken(hash: string, at: string): Promise<void>;

  putDeviceLogin(rec: DeviceLoginRecord): Promise<void>;
  getDeviceLogin(id: string): Promise<DeviceLoginRecord | undefined>;
  setDevicePolled(id: string, at: string, interval: number): Promise<void>;
  deleteDeviceLogin(id: string): Promise<void>;

  addTrustedPublisher(tp: TrustedPublisher): Promise<void>;
  listTrustedPublishers(name: string): Promise<TrustedPublisher[]>;
  removeTrustedPublisher(name: string, id: string): Promise<void>;

  /**
   * Claim a one-time key (a CI token's jti, hashed): true for the first caller, false for every later one, atomically.
   * `expires_at` is when the row may be forgotten (DynamoDB TTL removes it lazily; until then the key stays claimed).
   * Used rows are never deleted by this port.
   */
  claimOnce(key: string, expires_at: string): Promise<boolean>;
}
