import { AuthError } from './errors';
import { GitHubUnavailable, type GitHubApi } from './github';
import { hashToken, mintToken, newId, SESSION_FRESH_MS, type Clock } from './tokens';
import type { AuthStore } from './types';

/** The approval page expires in ten minutes (spec), whatever GitHub allows. */
export const DEVICE_LOGIN_TTL_S = 600;
export const MIN_POLL_INTERVAL_S = 5;
const SLOW_DOWN_STEP_S = 5;

export interface DeviceLoginConfig {
  store: AuthStore;
  github: GitHubApi;
  /**
   * Refuse a login whose GitHub account does not have two-factor authentication on. A LEAN pending the CEO:
   * defaults ON. It fails closed: if GitHub does not show the field, the login is denied.
   */
  require2fa?: boolean;
  /** OAuth scope to request. Default `read:user`; see github.ts for what that shows. */
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
    };

export class DeviceLogin {
  private readonly store: AuthStore;
  private readonly github: GitHubApi;
  private readonly require2fa: boolean;
  private readonly scope: string;
  private readonly sessionTtlMs: number;
  private readonly now: Clock;

  constructor(c: DeviceLoginConfig) {
    this.store = c.store;
    this.github = c.github;
    this.require2fa = c.require2fa ?? true;
    this.scope = c.githubScope ?? 'read:user';
    this.sessionTtlMs = (c.sessionTtlDays ?? 30) * 86_400_000;
    this.now = c.now ?? (() => new Date());
  }

  async start(input: { client: string }): Promise<DeviceStart> {
    const client = input?.client;
    if (typeof client !== 'string' || client.length < 1 || client.length > 80) {
      throw new AuthError('invalid_request', 'The request is not valid: client must be 1 to 80 characters.', { detail: 'client must be 1 to 80 characters' });
    }
    const gh = await this.callGitHub(() => this.github.startDeviceFlow(this.scope));
    const now = this.now();
    const expires_in = Math.min(gh.expires_in, DEVICE_LOGIN_TTL_S);
    const interval = Math.max(gh.interval, MIN_POLL_INTERVAL_S);
    // Our own code goes to the CLI; GitHub's stays here, so a leaked CLI log cannot be polled at GitHub.
    const device_code = newId('dev') + newId('x').slice(2);
    await this.store.putDeviceLogin({
      id: hashToken(device_code),
      github_device_code: gh.device_code,
      client,
      created_at: now.toISOString(),
      expires_at: new Date(now.getTime() + expires_in * 1000).toISOString(),
      interval,
    });
    return { device_code, user_code: gh.user_code, verification_uri: gh.verification_uri, expires_in, interval };
  }

  async poll(input: { device_code: string }): Promise<DevicePoll> {
    const code = input?.device_code;
    if (typeof code !== 'string' || code.length < 16 || code.length > 200) {
      throw new AuthError('device_code_unknown', 'The device code is not recognised.');
    }
    const id = hashToken(code);
    const login = await this.store.getDeviceLogin(id);
    if (!login) throw new AuthError('device_code_unknown', 'The device code is not recognised.');
    const now = this.now();
    if (Date.parse(login.expires_at) <= now.getTime()) {
      await this.store.deleteDeviceLogin(id);
      return { status: 'expired' };
    }
    // Polling faster than the interval is answered without bothering GitHub, and slows the client down.
    if (login.last_polled_at && now.getTime() - Date.parse(login.last_polled_at) < login.interval * 1000) {
      const interval = login.interval + SLOW_DOWN_STEP_S;
      await this.store.setDevicePolled(id, now.toISOString(), interval);
      return { status: 'pending', interval };
    }
    await this.store.setDevicePolled(id, now.toISOString(), login.interval);

    const r = await this.callGitHub(() => this.github.pollDeviceFlow(login.github_device_code));
    switch (r.kind) {
      case 'pending':
        return { status: 'pending', interval: login.interval };
      case 'slow_down': {
        const interval = Math.max(r.interval ?? 0, login.interval + SLOW_DOWN_STEP_S);
        await this.store.setDevicePolled(id, now.toISOString(), interval);
        return { status: 'pending', interval };
      }
      case 'denied':
        await this.store.deleteDeviceLogin(id);
        return { status: 'denied', reason: 'github_denied' };
      case 'expired':
        await this.store.deleteDeviceLogin(id);
        return { status: 'expired' };
      case 'ok':
        break;
    }

    const gh = await this.callGitHub(() => this.github.getUser(r.access_token));
    // The GitHub token has done its job; it is never stored.
    await this.store.deleteDeviceLogin(id);
    if (this.require2fa && gh.two_factor !== true) {
      return { status: 'denied', reason: 'two_factor_required' };
    }
    const iso = now.toISOString();
    const user = await this.store.upsertUser(gh.id, gh.login, iso, gh.two_factor);
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
    };
  }

  private async callGitHub<T>(f: () => Promise<T>): Promise<T> {
    try {
      return await f();
    } catch (e) {
      if (e instanceof GitHubUnavailable) throw new AuthError('unavailable', 'The registry is temporarily unavailable.');
      throw e;
    }
  }
}
