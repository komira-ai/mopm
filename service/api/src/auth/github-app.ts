import { createPrivateKey, sign, type KeyObject } from 'node:crypto';
import { GitHubUnavailable, type FetchLike } from './github';

/**
 * The registry's GitHub App, "mopm registry" (docs/design/namespaces.md 2.2): one organization permission, Members:
 * read-only, and no repository permission. It never acts for a user and holds no user token. It answers the four reads
 * the organization membership check needs, every one from ids except the installation lookup by organization login,
 * which only the namespace creation makes.
 *
 * Authentication, as GitHub documents it for Apps: a JSON Web Token signed RS256 with the App's private key, issuer the
 * App id, lifetime under 10 minutes, for the `/app/...` and `/orgs/{org}/installation` calls; for the rest an
 * installation access token, minted with that JWT (`POST /app/installations/{id}/access_tokens`, valid one hour) and
 * kept in this process until 5 minutes before GitHub says it expires. Nothing is stored.
 *
 * Every read answers `undefined` for GitHub's 404 and throws GitHubUnavailable for any other failure: an error status
 * (401, 403 with the rate limit spent, 429, 5xx), a fetch that rejects, a body that is not JSON or not the documented
 * shape. The membership check decides what each means.
 */

/** An installation of the App, as `GET /app/installations/{id}` and `GET /orgs/{org}/installation` show it. */
export interface GitHubInstallation {
  id: number;
  /** The organization or user the App is installed on: its numeric id and current login. */
  account: { id: number; login: string };
  /** Set while an owner has suspended the installation: GitHub then refuses its tokens. */
  suspended: boolean;
}

/** `GET /orgs/{org}/memberships/{username}`: whose membership it is (by numeric id), its state and its role, as GitHub spells them. */
export interface GitHubOrgMembershipOf {
  user_id: number;
  state: string;
  role: string;
}

export interface GitHubAppApi {
  /** `GET /app/installations/{installation_id}`, as the App. */
  getInstallation(installation_id: number): Promise<GitHubInstallation | undefined>;
  /** `GET /orgs/{org}/installation`, as the App: the one call that takes a string, made only when a namespace is created. */
  getOrgInstallation(org_login: string): Promise<GitHubInstallation | undefined>;
  /** `GET /user/{account_id}`, with the installation's token: the account's current login. */
  getUserById(installation_id: number, account_id: number): Promise<{ id: number; login: string } | undefined>;
  /** `GET /orgs/{org}/memberships/{username}`, with the installation's token. */
  getOrgMembership(installation_id: number, org_login: string, user_login: string): Promise<GitHubOrgMembershipOf | undefined>;
}

/** The App's JWT is dated this far back, for clock drift between here and GitHub (GitHub's own advice). */
export const APP_JWT_BACKDATE_SECONDS = 60;
/** The App's JWT lives this long after its date; GitHub refuses more than 10 minutes. */
export const APP_JWT_LIFETIME_SECONDS = 540;
/** An installation token is minted again this long before GitHub says it expires. */
export const INSTALLATION_TOKEN_MARGIN_MS = 5 * 60 * 1000;

const UA = 'mopm-registry';
const isId = (v: unknown): v is number => Number.isInteger(v) && (v as number) >= 1;
const isLogin = (v: unknown): v is string => typeof v === 'string' && v.length > 0;
const b64u = (v: unknown) => Buffer.from(JSON.stringify(v)).toString('base64url');

export interface GitHubAppCredentials {
  /** The App's numeric id, the JWT issuer. */
  appId: string;
  /** The App's private key, PEM, as GitHub generated it. */
  privateKey: string;
}

export class HttpGitHubAppApi implements GitHubAppApi {
  private readonly key: KeyObject;
  private readonly tokens = new Map<number, { token: string; renew_at: number }>();

  constructor(
    private readonly creds: GitHubAppCredentials,
    private readonly now: () => Date = () => new Date(),
    private readonly fetchFn: FetchLike = globalThis.fetch as unknown as FetchLike,
    private readonly api = 'https://api.github.com',
  ) {
    if (!/^[1-9][0-9]*$/.test(creds.appId)) throw new Error('the GitHub App id must be a positive number');
    this.key = createPrivateKey(creds.privateKey);
    if (this.key.asymmetricKeyType !== 'rsa') throw new Error('the GitHub App private key must be an RSA key');
  }

  /** The App's JWT for one call: issued now, so nothing is cached. */
  appJwt(): string {
    const iat = Math.floor(this.now().getTime() / 1000) - APP_JWT_BACKDATE_SECONDS;
    const head = `${b64u({ alg: 'RS256', typ: 'JWT' })}.${b64u({ iat, exp: iat + APP_JWT_LIFETIME_SECONDS, iss: this.creds.appId })}`;
    return `${head}.${sign('RSA-SHA256', Buffer.from(head), this.key).toString('base64url')}`;
  }

  /** One call; `undefined` for 404, the parsed body for 2xx, GitHubUnavailable for everything else. */
  private async call(method: 'GET' | 'POST', path: string, bearer: string, what: string): Promise<Record<string, unknown> | undefined> {
    let status: number;
    let body: unknown;
    try {
      const res = await this.fetchFn(`${this.api}${path}`, {
        method,
        headers: { accept: 'application/vnd.github+json', authorization: `Bearer ${bearer}`, 'user-agent': UA, 'x-github-api-version': '2022-11-28' },
      });
      status = res.status;
      if (status === 404) return undefined;
      if (!res.ok) throw new GitHubUnavailable(`GitHub answered ${status} for the ${what}`);
      body = await res.json();
    } catch (e) {
      if (e instanceof GitHubUnavailable) throw e;
      // Unreachable (a rejected fetch) or a body that is not JSON.
      throw new GitHubUnavailable(`GitHub could not be read for the ${what}: ${(e as Error)?.name}`);
    }
    if (typeof body !== 'object' || body === null || Array.isArray(body)) throw new GitHubUnavailable(`GitHub answered an unusable ${what}`);
    return body as Record<string, unknown>;
  }

  private installation(b: Record<string, unknown> | undefined): GitHubInstallation | undefined {
    if (!b) return undefined;
    const account = b.account as Record<string, unknown> | null | undefined;
    if (!isId(b.id) || !account || typeof account !== 'object' || !isId(account.id) || !isLogin(account.login)) {
      throw new GitHubUnavailable('GitHub answered an unusable installation');
    }
    return { id: b.id, account: { id: account.id, login: account.login }, suspended: b.suspended_at != null };
  }

  async getInstallation(installation_id: number) {
    return this.installation(await this.call('GET', `/app/installations/${installation_id}`, this.appJwt(), 'installation'));
  }

  async getOrgInstallation(org_login: string) {
    return this.installation(await this.call('GET', `/orgs/${encodeURIComponent(org_login)}/installation`, this.appJwt(), 'installation'));
  }

  /** The installation's access token, minted when there is none or it is within the margin of its expiry. */
  private async token(installation_id: number): Promise<string> {
    const at = this.now().getTime();
    const held = this.tokens.get(installation_id);
    if (held && at < held.renew_at) return held.token;
    const b = await this.call('POST', `/app/installations/${installation_id}/access_tokens`, this.appJwt(), 'installation token');
    // A 404 here is an installation removed since the caller read it: nothing to ask with, so GitHub is not usable now.
    if (!b) throw new GitHubUnavailable('GitHub answered 404 for the installation token');
    const expires = typeof b.expires_at === 'string' ? Date.parse(b.expires_at) : NaN;
    if (!isLogin(b.token) || Number.isNaN(expires)) throw new GitHubUnavailable('GitHub answered an unusable installation token');
    this.tokens.set(installation_id, { token: b.token, renew_at: expires - INSTALLATION_TOKEN_MARGIN_MS });
    return b.token;
  }

  async getUserById(installation_id: number, account_id: number) {
    const b = await this.call('GET', `/user/${account_id}`, await this.token(installation_id), 'user lookup');
    if (!b) return undefined;
    if (!isId(b.id) || !isLogin(b.login)) throw new GitHubUnavailable('GitHub answered an unusable user');
    return { id: b.id, login: b.login };
  }

  async getOrgMembership(installation_id: number, org_login: string, user_login: string) {
    const path = `/orgs/${encodeURIComponent(org_login)}/memberships/${encodeURIComponent(user_login)}`;
    const b = await this.call('GET', path, await this.token(installation_id), 'organization membership');
    if (!b) return undefined;
    const user = b.user as Record<string, unknown> | null | undefined;
    if (!user || typeof user !== 'object' || !isId(user.id) || typeof b.state !== 'string' || typeof b.role !== 'string') {
      throw new GitHubUnavailable('GitHub answered an unusable membership');
    }
    return { user_id: user.id, state: b.state, role: b.role };
  }
}
