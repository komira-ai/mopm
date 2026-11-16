import { AuthError } from './errors';
import { GitHubUnavailable, type GitHubApi, type GitHubDeviceStart } from './github';
import { ensureUserNamespace, type NamespaceStore } from './namespaces';
import { hashToken, mintToken, newId, SESSION_FRESH_MS, type Clock } from './tokens';
import type { AuthStore, DeviceLoginRecord } from './types';

/** The approval page expires in ten minutes (spec), whatever GitHub allows. */
export const DEVICE_LOGIN_TTL_S = 600;
export const MIN_POLL_INTERVAL_S = 5;
/** The OAuth scope a login asks for: `read:user`, for the account and its two-factor flag. */
export const DEFAULT_GITHUB_SCOPE = 'read:user';
const SLOW_DOWN_STEP_S = 5;

/** What a device flow answers its client while GitHub has no token to give: the login poll and the organization registration poll both. */
export type DeviceWait = { status: 'pending'; interval: number } | { status: 'expired' } | { status: 'denied' };

/** The 503 of GitHub failing: `unavailable`. Any other error passes. */
export async function callGitHub<T>(f: () => Promise<T>): Promise<T> {
  try {
    return await f();
  } catch (e) {
    if (e instanceof GitHubUnavailable) throw new AuthError('unavailable', 'The registry is temporarily unavailable.', { service: 'GitHub' });
    throw e;
  }
}

export interface DeviceStore {
  store: AuthStore;
  now: Clock;
}

/**
 * Store a device row for the GitHub flow `gh` just started and hand back our own device code: the row keeps GitHub's code and the
 * hash of ours, so a leaked client log cannot be polled at GitHub. The row lives `DEVICE_LOGIN_TTL_S` at most, whatever GitHub allows.
 */
export async function storeDeviceFlow(d: DeviceStore, gh: GitHubDeviceStart, row: { client: string } & Partial<Pick<DeviceLoginRecord, 'org_namespace' | 'account_id'>>): Promise<DeviceStart> {
  const now = d.now();
  const expires_in = Math.min(gh.expires_in, DEVICE_LOGIN_TTL_S);
  const interval = Math.max(gh.interval, MIN_POLL_INTERVAL_S);
  const device_code = newId('dev') + newId('x').slice(2);
  await d.store.putDeviceLogin({
    ...row,
    id: hashToken(device_code),
    github_device_code: gh.device_code,
    created_at: now.toISOString(),
    expires_at: new Date(now.getTime() + expires_in * 1000).toISOString(),
    interval,
  });
  return { device_code, user_code: gh.user_code, verification_uri: gh.verification_uri, expires_in, interval };
}

/** The row of a device code the client sent, or `device_code_unknown`. */
export async function findDeviceRow(store: AuthStore, code: unknown): Promise<DeviceLoginRecord> {
  if (typeof code !== 'string' || code.length < 16 || code.length > 200) throw new AuthError('device_code_unknown', 'The device code is not recognised.');
  const row = await store.getDeviceLogin(hashToken(code));
  if (!row) throw new AuthError('device_code_unknown', 'The device code is not recognised.');
  return row;
}

/**
 * One poll of a device row: expiry, the interval the client must keep (polling faster is answered without asking GitHub and
 * slows the client down), then GitHub's answer. A finished flow (denied, expired) deletes the row. `{access_token}` is
 * GitHub's token for an approved flow; the row is left for the caller to delete once it has used the token.
 */
export async function advanceDeviceFlow(d: DeviceStore & { github: GitHubApi }, row: DeviceLoginRecord): Promise<DeviceWait | { access_token: string }> {
  const { id } = row;
  const now = d.now();
  if (Date.parse(row.expires_at) <= now.getTime()) {
    await d.store.deleteDeviceLogin(id);
    return { status: 'expired' };
  }
  if (row.last_polled_at && now.getTime() - Date.parse(row.last_polled_at) < row.interval * 1000) {
    const interval = row.interval + SLOW_DOWN_STEP_S;
    await d.store.setDevicePolled(id, now.toISOString(), interval);
    return { status: 'pending', interval };
  }
  await d.store.setDevicePolled(id, now.toISOString(), row.interval);

  const r = await callGitHub(() => d.github.pollDeviceFlow(row.github_device_code));
  switch (r.kind) {
    case 'pending':
      return { status: 'pending', interval: row.interval };
    case 'slow_down': {
      const interval = Math.max(r.interval ?? 0, row.interval + SLOW_DOWN_STEP_S);
      await d.store.setDevicePolled(id, now.toISOString(), interval);
      return { status: 'pending', interval };
    }
    case 'denied':
      await d.store.deleteDeviceLogin(id);
      return { status: 'denied' };
    case 'expired':
      await d.store.deleteDeviceLogin(id);
      return { status: 'expired' };
    case 'ok':
      return { access_token: r.access_token };
  }
}

export interface DeviceLoginConfig {
  store: AuthStore;
  /** Where the account's user namespace is made at login (docs/design/namespaces.md 2.1). */
  namespaces: NamespaceStore;
  github: GitHubApi;
  /**
   * Refuse a login whose GitHub account does not have two-factor authentication on. A LEAN pending the CEO:
   * defaults ON. It fails closed: if GitHub does not show the field, the login is denied.
   */
  require2fa?: boolean;
  /**
   * OAuth scope to request. Default `read:user`; see github.ts.
   */
  githubScope?: string;
  sessionTtlDays?: number;
  now?: Clock;
}

export interface DeviceStart {
  device_code: string;
  user_code: string;
  verification_uri: string;
  expires_in: number;
  interval: number;
}

export type DevicePoll =
  | { status: 'pending'; interval: number }
  | { status: 'expired' }
  | { status: 'denied'; reason?: 'github_denied' | 'two_factor_required' }
  | {
      status: 'approved';
      token: string;
      token_kind: 'session';
      expires_at: string;
      fresh_until: string;
      handle: string;
      /** The account's user namespace, when this login made it or already held it. */
      namespace?: string;
    };

export class DeviceLogin {
  private readonly store: AuthStore;
  private readonly namespaces: NamespaceStore;
  private readonly github: GitHubApi;
  private readonly require2fa: boolean;
  private readonly scope: string;
  private readonly sessionTtlMs: number;
  private readonly now: Clock;

  constructor(c: DeviceLoginConfig) {
    this.store = c.store;
    this.namespaces = c.namespaces;
    this.github = c.github;
    this.require2fa = c.require2fa ?? true;
    this.scope = c.githubScope ?? DEFAULT_GITHUB_SCOPE;
    this.sessionTtlMs = (c.sessionTtlDays ?? 30) * 86_400_000;
    this.now = c.now ?? (() => new Date());
  }

  async start(input: { client: string }): Promise<DeviceStart> {
    const client = input?.client;
    if (typeof client !== 'string' || client.length < 1 || client.length > 80) {
      throw new AuthError('invalid_request', 'The request is not valid: client must be 1 to 80 characters.', { detail: 'client must be 1 to 80 characters' });
    }
    const gh = await callGitHub(() => this.github.startDeviceFlow(this.scope));
    return storeDeviceFlow({ store: this.store, now: this.now }, gh, { client });
  }

  async poll(input: { device_code: string }): Promise<DevicePoll> {
    const login = await findDeviceRow(this.store, input?.device_code);
    // A code of an organization registration is not a login: it never makes a session.
    if (login.org_namespace !== undefined) throw new AuthError('device_code_unknown', 'The device code is not recognised.');
    const id = login.id;
    const now = this.now();
    const r = await advanceDeviceFlow({ store: this.store, github: this.github, now: this.now }, login);
    if (!('access_token' in r)) return r.status === 'denied' ? { status: 'denied', reason: 'github_denied' } : r;

    const gh = await callGitHub(() => this.github.getUser(r.access_token));
    // The login is over at GitHub: the row goes, and GitHub's token, never stored, is used once more below and dropped.
    await this.store.deleteDeviceLogin(id);
    if (this.require2fa && gh.two_factor !== true) {
      return { status: 'denied', reason: 'two_factor_required' };
    }
    const iso = now.toISOString();
    const user = await this.store.upsertUser(gh.id, gh.login, iso, gh.two_factor);
    // The user namespace: made, already held, or none (taken by another id, reserved, outside the grammar). None never
    // stops the login: the account can still publish in organization namespaces. A store failure fails the login, as a
    // failing user upsert does: the person logs in again, and the next login makes the namespace.
    const ns = await ensureUserNamespace(this.namespaces, gh.id, gh.login, iso);
    const m = await mintToken(this.store, {
      kind: 'session',
      github_id: user.github_id,
      name: `login (${login.client})`,
      scopes: [],
      packages: [],
      all_current: false,
      fresh_until: new Date(now.getTime() + SESSION_FRESH_MS).toISOString(),
      created_at: iso,
      expires_at: new Date(now.getTime() + this.sessionTtlMs).toISOString(),
    });
    return {
      status: 'approved',
      token: m.secret,
      token_kind: 'session',
      expires_at: m.record.expires_at,
      fresh_until: m.record.fresh_until!,
      handle: user.handle,
      ...(ns.status === 'created' || ns.status === 'held' ? { namespace: ns.namespace } : {}),
    };
  }
}
