/**
 * GitHub, as far as login needs it: the OAuth device flow, the authenticated-user lookup and the user's active organization
 * memberships (scope `read:org`, recorded for `whoami`: the list never grants a write, docs/design/namespaces.md 2.2).
 *
 * What GitHub exposes (documented here because the 2FA rule depends on it):
 * - `GET /user` returns the numeric `id` and `login` for any token.
 * - `two_factor_authentication` (boolean) is part of the authenticated user's own, private view. GitHub
 *   documents it for the full user object returned to the account itself; whether a given OAuth scope is
 *   enough to see it must be confirmed against live GitHub before the requirement is switched on in prod.
 *   When the field is absent we cannot know, and the login layer treats absent as "not satisfied" while the
 *   requirement is on (fail closed).
 *   The login asks for `read:user read:org`; that confirmation is of the field under these scopes.
 * - The device flow needs the OAuth app's client id only; the client secret is not used and not read.
 *   The client id comes from Secrets Manager at runtime and is passed to the constructor.
 */
export type FetchLike = (url: string, init: { method: string; headers: Record<string, string>; body?: string }) => Promise<{
  ok: boolean;
  status: number;
  json(): Promise<unknown>;
}>;

export interface GitHubDeviceStart {
  device_code: string;
  user_code: string;
  verification_uri: string;
  expires_in: number;
  interval: number;
}

export type GitHubPoll =
  | { kind: 'pending' }
  | { kind: 'slow_down'; interval?: number }
  | { kind: 'denied' }
  | { kind: 'expired' }
  | { kind: 'ok'; access_token: string };

export interface GitHubUser {
  id: number;
  login: string;
  /** Undefined when GitHub did not include the field. */
  two_factor?: boolean;
}

/** One organization the user is an active member of, as GitHub showed it at login. */
export interface GitHubOrgMembership {
  /** The organization's numeric id. */
  id: number;
  /** The organization's login at the time of the lookup. */
  login: string;
  role: 'admin' | 'member';
}

export interface GitHubApi {
  startDeviceFlow(scope: string): Promise<GitHubDeviceStart>;
  pollDeviceFlow(deviceCode: string): Promise<GitHubPoll>;
  getUser(accessToken: string): Promise<GitHubUser>;
  /**
   * `GET /user/memberships/orgs?state=active`, every page. An organization that restricts OAuth apps is left out by GitHub
   * itself. A membership GitHub shows with another state or role (a billing manager) is left out here.
   */
  listOrgMemberships(accessToken: string): Promise<GitHubOrgMembership[]>;
}

/** Page size of the membership list, GitHub's largest. */
export const ORG_PAGE_SIZE = 100;
/** Pages read at most: an account in more than this many organizations gets the first ones listed (whoami only). */
export const ORG_PAGES_MAX = 10;

/** GitHub could not be reached or answered something unusable. The router maps it to `unavailable`. */
export class GitHubUnavailable extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'GitHubUnavailable';
  }
}

const UA = 'mopm-registry';

export class HttpGitHubApi implements GitHubApi {
  constructor(
    private readonly clientId: string,
    private readonly fetchFn: FetchLike = globalThis.fetch as unknown as FetchLike,
    private readonly hosts = { oauth: 'https://github.com', api: 'https://api.github.com' },
  ) {
    if (!clientId) throw new Error('GitHub client id is required');
  }

  private async post(path: string, params: Record<string, string>): Promise<Record<string, unknown>> {
    const res = await this.fetchFn(`${this.hosts.oauth}${path}`, {
      method: 'POST',
      headers: { accept: 'application/json', 'content-type': 'application/x-www-form-urlencoded', 'user-agent': UA },
      body: new URLSearchParams(params).toString(),
    });
    if (!res.ok) throw new GitHubUnavailable(`GitHub answered ${res.status}`);
    const body = await res.json();
    if (typeof body !== 'object' || body === null) throw new GitHubUnavailable('GitHub answered a non-object');
    return body as Record<string, unknown>;
  }

  async startDeviceFlow(scope: string): Promise<GitHubDeviceStart> {
    const b = await this.post('/login/device/code', { client_id: this.clientId, scope });
    const { device_code, user_code, verification_uri, expires_in, interval } = b;
    if (typeof device_code !== 'string' || typeof user_code !== 'string' || typeof verification_uri !== 'string' ||
        typeof expires_in !== 'number' || typeof interval !== 'number') {
      throw new GitHubUnavailable('GitHub answered an unusable device code response');
    }
    return { device_code, user_code, verification_uri, expires_in, interval };
  }

  async pollDeviceFlow(deviceCode: string): Promise<GitHubPoll> {
    const b = await this.post('/login/oauth/access_token', {
      client_id: this.clientId,
      device_code: deviceCode,
      grant_type: 'urn:ietf:params:oauth:grant-type:device_code',
    });
    if (typeof b.access_token === 'string' && b.access_token) return { kind: 'ok', access_token: b.access_token };
    switch (b.error) {
      case 'authorization_pending':
        return { kind: 'pending' };
      case 'slow_down':
        return { kind: 'slow_down', interval: typeof b.interval === 'number' ? b.interval : undefined };
      case 'access_denied':
        return { kind: 'denied' };
      case 'expired_token':
        return { kind: 'expired' };
      default:
        // incorrect_device_code, unsupported_grant_type, incorrect_client_credentials, device_flow_disabled...
        throw new GitHubUnavailable(`GitHub refused the device flow: ${String(b.error)}`);
    }
  }

  private async get(path: string, accessToken: string, what: string): Promise<unknown> {
    const res = await this.fetchFn(`${this.hosts.api}${path}`, {
      method: 'GET',
      headers: { accept: 'application/vnd.github+json', authorization: `Bearer ${accessToken}`, 'user-agent': UA, 'x-github-api-version': '2022-11-28' },
    });
    if (!res.ok) throw new GitHubUnavailable(`GitHub answered ${res.status} for the ${what}`);
    return res.json();
  }

  async getUser(accessToken: string): Promise<GitHubUser> {
    const b = (await this.get('/user', accessToken, 'user lookup')) as Record<string, unknown>;
    if (!b || !Number.isInteger(b.id) || (b.id as number) < 1 || typeof b.login !== 'string' || !b.login) {
      throw new GitHubUnavailable('GitHub answered an unusable user');
    }
    const u: GitHubUser = { id: b.id as number, login: b.login };
    if (typeof b.two_factor_authentication === 'boolean') u.two_factor = b.two_factor_authentication;
    return u;
  }

  async listOrgMemberships(accessToken: string): Promise<GitHubOrgMembership[]> {
    const out: GitHubOrgMembership[] = [];
    for (let page = 1; page <= ORG_PAGES_MAX; page++) {
      let b: unknown;
      try {
        b = await this.get(`/user/memberships/orgs?state=active&per_page=${ORG_PAGE_SIZE}&page=${page}`, accessToken, 'organization memberships');
      } catch (e) {
        // Unreachable (a rejected fetch) or a body that is not JSON: GitHub unavailable, as an error status is.
        if (e instanceof GitHubUnavailable) throw e;
        throw new GitHubUnavailable(`GitHub could not be read for the organization memberships: ${(e as Error)?.name}`);
      }
      if (!Array.isArray(b)) throw new GitHubUnavailable('GitHub answered an unusable membership list');
      for (const m of b as Array<Record<string, unknown>>) {
        const org = (m && typeof m === 'object' ? m.organization : undefined) as Record<string, unknown> | undefined;
        if (!org || !Number.isInteger(org.id) || (org.id as number) < 1 || typeof org.login !== 'string' || !org.login) {
          throw new GitHubUnavailable('GitHub answered an unusable membership');
        }
        if (m.state !== 'active' || (m.role !== 'admin' && m.role !== 'member')) continue;
        out.push({ id: org.id as number, login: org.login, role: m.role });
      }
      if (b.length < ORG_PAGE_SIZE) break;
    }
    return out;
  }
}
