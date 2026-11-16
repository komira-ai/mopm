import { advanceDeviceFlow, callGitHub, findDeviceRow, storeDeviceFlow, type DeviceStart, type DeviceWait } from './device-login';
import { AuthError, NamespaceError } from './errors';
import type { GitHubApi } from './github';
import { invalidNamespace, namespaceReserved } from './namespace-access';
import { namespaceProblem, type NamespaceRecord, type NamespaceStore } from './namespaces';
import type { Clock } from './tokens';
import type { AuthStore } from './types';

/**
 * Registering an organization namespace (docs/design/namespaces.md 2.2): the one time GitHub is asked about an organization.
 *
 * `start` refuses a string that cannot be a namespace or is held, and a caller that holds no user namespace (it could not be
 * named as a member), then starts GitHub's device flow with scope `read:org` and
 * stores a device row bound to the caller. `poll` shares the polling rules of the login (device-login.ts); on approval it
 * reads, with GitHub's one-time token, the account the token belongs to and its membership of the organization, then drops the
 * token: it is never stored. It passes only for the caller's own GitHub account when that account is an active admin of the
 * organization whose current login, lower-cased, is the namespace. The organization's numeric id is stored on the namespace row
 * and the caller becomes its first owner. Nothing is asked of GitHub about the organization afterwards.
 */

/** The OAuth scope of the registration's device flow. */
export const ORG_REGISTER_SCOPE = 'read:org';

export interface OrgRegistrationConfig {
  store: AuthStore;
  namespaces: NamespaceStore;
  github: GitHubApi;
  now?: Clock;
}

export type OrgRegistrationPoll = DeviceWait | { status: 'created'; record: NamespaceRecord };

const namespaceTaken = (namespace: string) => new NamespaceError('namespace_taken', `'${namespace}' is taken.`, { namespace });

export class OrgRegistration {
  private readonly now: Clock;

  constructor(private readonly c: OrgRegistrationConfig) {
    this.now = c.now ?? (() => new Date());
  }

  /**
   * Refuses with `invalid_namespace`, `namespace_reserved` or `namespace_taken` (any row, user or organization), then with
   * `user_not_found` when the caller holds no namespace of kind user, before GitHub is asked.
   */
  async start(account_id: number, namespace: unknown): Promise<DeviceStart> {
    if (typeof namespace !== 'string') {
      throw new AuthError('invalid_request', "The request is not valid: 'namespace' must be a string.", { detail: "'namespace' must be a string" });
    }
    const problem = namespaceProblem(namespace);
    if (problem === 'invalid') throw invalidNamespace(namespace);
    if (problem === 'reserved') throw namespaceReserved(namespace);
    if (await this.c.namespaces.getNamespace(namespace)) throw namespaceTaken(namespace);
    if (!(await this.c.namespaces.listNamespaces(account_id)).some((r) => r.kind === 'user')) {
      const handle = ((await this.c.store.getUser(account_id))?.handle ?? String(account_id)).toLowerCase();
      throw new NamespaceError('user_not_found', `There is no mopm user '${handle}'.`, { user: handle });
    }
    const gh = await callGitHub(() => this.c.github.startDeviceFlow(ORG_REGISTER_SCOPE));
    return storeDeviceFlow({ store: this.c.store, now: this.now }, gh, { client: 'org-registration', org_namespace: namespace, account_id });
  }

  /** A code that is unknown, or was started by another account, or was a login's, is `device_code_unknown`. */
  async poll(account_id: number, device_code: unknown): Promise<OrgRegistrationPoll> {
    const row = await findDeviceRow(this.c.store, device_code);
    const namespace = row.org_namespace;
    if (namespace === undefined || row.account_id !== account_id) throw new AuthError('device_code_unknown', 'The device code is not recognised.');
    const r = await advanceDeviceFlow({ store: this.c.store, github: this.c.github, now: this.now }, row);
    if (!('access_token' in r)) return r;
    // GitHub has answered: the row goes, and the token below is used and dropped, never stored.
    await this.c.store.deleteDeviceLogin(row.id);
    const gh = await callGitHub(() => this.c.github.getUser(r.access_token));
    if (gh.id !== account_id) {
      throw new NamespaceError('github_account_mismatch', 'The GitHub account that approved is not the one logged in to mopm.', { namespace });
    }
    const m = await callGitHub(() => this.c.github.getOrgMembership(r.access_token, namespace));
    if (!m || m.state !== 'active' || m.role !== 'admin' || m.organization.login.toLowerCase() !== namespace) {
      throw new NamespaceError('not_org_admin', `You are not an active admin of the GitHub organization '${namespace}'.`, { namespace });
    }
    const at = this.now().toISOString();
    const made = await this.c.namespaces.createOrgNamespace(
      { namespace, kind: 'org', github_id: m.organization.id, created_at: at, created_by: account_id },
      { namespace, github_id: account_id, role: 'owner', added_by: account_id, added_at: at },
    );
    if (!made.created) throw namespaceTaken(namespace);
    return { status: 'created', record: made.record };
  }
}
