import { AuthError } from './errors';
import { namespaceProblem, type NamespaceKind, type NamespaceRecord, type NamespaceStore } from './namespaces';
import { NamespaceError, UNVERIFIED, type OrgMembership, type OrgRole } from './org-membership';
import type { AuthStore, UserRecord } from './types';

/**
 * Who may write in a namespace (docs/design/namespaces.md 2.4), for every `/api/v2` write an account makes: creating a
 * package, publishing, yanking, the packages of an API token, and the namespaces `GET /api/v2/me` lists.
 *
 * - A user namespace: the account bound to it (role `owner`).
 * - An organization namespace: an active admin or member of the organization, by the live membership check of 2.2
 *   (OrgMembership: a pass is reused for 5 minutes, a refusal never). A deployment without the registry's GitHub App
 *   wired cannot check, so every organization write there is `unavailable`, naming GitHub.
 *
 * A CI identity's token is not an account: its right comes from the namespace publisher it was minted for
 * (src/auth/oidc.ts), and src/publish/service.ts `requireOwner` accepts it by the names it was minted for.
 */

/** `role` of `MeV2.namespaces[]`: `owner` of a user namespace, GitHub's `admin` or `member` of an organization's. */
export type NamespaceRole = 'owner' | OrgRole;

export interface WriteRight {
  record: NamespaceRecord;
  role: NamespaceRole;
}

/** `NamespaceInfo` of spec/api/openapi-v2.yaml. */
export interface NamespaceInfo {
  namespace: string;
  kind: NamespaceKind;
  github_id: number;
  /** The GitHub login the registry knows for the account: a user's handle from its last login; an organization's namespace string. */
  login: string;
  /** An organization namespace with no bound installation of the App: reads work, writes are refused. */
  frozen: boolean;
}

export interface NamespaceAccessDeps {
  namespaces: NamespaceStore;
  users: Pick<AuthStore, 'getUser'>;
  /** The membership check. Absent: the deployment has no GitHub App, and organization writes are `unavailable`. */
  membership?: OrgMembership;
}

export const invalidNamespace = (namespace: string) => new NamespaceError('invalid_namespace', `'${namespace}' is not a valid namespace.`, { namespace });
export const namespaceReserved = (namespace: string) => new NamespaceError('namespace_reserved', `'${namespace}' is reserved.`, { namespace });
export const namespaceNotFound = (namespace: string) => new NamespaceError('namespace_not_found', `There is no namespace '${namespace}'.`, { namespace });
export const notNamespaceMember = (namespace: string) => new NamespaceError('not_namespace_member', `You cannot write in '${namespace}'.`, { namespace });
const noApp = (namespace: string) =>
  new AuthError('unavailable', `GitHub could not be asked about '${namespace}': the registry has no GitHub App configured.`, { namespace, service: 'GitHub' });

export class NamespaceAccess {
  constructor(private readonly d: NamespaceAccessDeps) {}

  /** The namespace's row; `invalid_namespace`, `namespace_reserved` or `namespace_not_found` when there is none to read. */
  async find(namespace: string): Promise<NamespaceRecord> {
    const problem = namespaceProblem(namespace);
    if (problem === 'invalid') throw invalidNamespace(namespace);
    if (problem === 'reserved') throw namespaceReserved(namespace);
    const rec = await this.d.namespaces.getNamespace(namespace);
    if (!rec) throw namespaceNotFound(namespace);
    return rec;
  }

  /**
   * May the account write in `namespace` now? Answers the row and the account's role; throws NamespaceError
   * (`invalid_namespace`, `namespace_reserved`, `namespace_not_found`, `not_namespace_member`, `namespace_unverified`) or
   * AuthError `unavailable` (GitHub unreachable, or no App configured).
   */
  async require(namespace: string, account_id: number): Promise<WriteRight> {
    const record = await this.find(namespace);
    return { record, role: await this.roleIn(record, account_id) };
  }

  /**
   * May a CI identity's token (minted for a publisher of `namespace`) write there now? The namespace must exist and, for an
   * organization, still have its App installation bound (a frozen one refuses every write). Answers the row.
   */
  async requireCi(namespace: string): Promise<NamespaceRecord> {
    const record = await this.find(namespace);
    if (record.kind === 'org' && record.installation_id === undefined) {
      throw new NamespaceError('namespace_unverified', `'${namespace}' cannot be verified on GitHub: ${UNVERIFIED.noInstallation}.`, { namespace, detail: UNVERIFIED.noInstallation });
    }
    return record;
  }

  /** The handle the registry knows for an account (its last login), or `u:<id>` for one it has no row for. Recorded as `published_by`. */
  async handleOf(account_id: number): Promise<string> {
    return (await this.d.users.getUser(account_id))?.handle ?? `u:${account_id}`;
  }

  /** The account's role in a namespace row, or the refusal. */
  async roleIn(record: NamespaceRecord, account_id: number): Promise<NamespaceRole> {
    if (record.kind === 'user') {
      if (record.github_id !== account_id) throw notNamespaceMember(record.namespace);
      return 'owner';
    }
    if (!this.d.membership) throw noApp(record.namespace);
    return this.d.membership.check(record, account_id);
  }

  /**
   * Every namespace the account can write now: its user namespaces (bound to its id), then the organization namespaces of
   * the organizations its last login recorded (`UserRecord.orgs`), each checked live. An organization the check refuses
   * is left out; GitHub unreachable is `unavailable`. Without an App, no organization namespace is listed. Sorted: user
   * namespaces first, each kind by namespace.
   */
  async writable(user: UserRecord): Promise<WriteRight[]> {
    const own = (await this.d.namespaces.listNamespaces(user.github_id))
      .filter((r) => r.kind === 'user')
      .map((record): WriteRight => ({ record, role: 'owner' }));
    const orgs: WriteRight[] = [];
    if (this.d.membership) {
      const ids = [...new Set((user.orgs ?? []).map((o) => o.github_id))].sort((a, b) => a - b);
      for (const id of ids) {
        for (const record of await this.d.namespaces.listNamespaces(id)) {
          if (record.kind !== 'org') continue;
          try {
            orgs.push({ record, role: await this.d.membership.check(record, user.github_id) });
          } catch (e) {
            if (e instanceof NamespaceError) continue; // not a member, or the namespace is frozen: not writable now
            throw e;
          }
        }
      }
    }
    // Namespaces are unique keys of the store, so no two rows compare equal.
    const byName = (a: WriteRight, b: WriteRight) => (a.record.namespace < b.record.namespace ? -1 : 1);
    return [...own.sort(byName), ...orgs.sort(byName)];
  }

  /**
   * `MeV2.unavailable_namespace`: the caller's login in lower case when it cannot be the caller's namespace (outside the
   * grammar, reserved, or held by another account). Undefined when the account holds it, or when it is free (the next
   * login makes it).
   */
  async unavailableNamespace(user: UserRecord): Promise<string | undefined> {
    const ns = user.handle.toLowerCase();
    if (namespaceProblem(ns)) return ns;
    const held = await this.d.namespaces.getNamespace(ns);
    return held && held.github_id !== user.github_id ? ns : undefined;
  }

  /** `NamespaceInfo`. Reads never call GitHub: a user's login is its handle from its last login. */
  async info(record: NamespaceRecord): Promise<NamespaceInfo> {
    const login = record.kind === 'user' ? ((await this.d.users.getUser(record.github_id))?.handle ?? record.namespace) : record.namespace;
    return {
      namespace: record.namespace,
      kind: record.kind,
      github_id: record.github_id,
      login,
      frozen: record.kind === 'org' && record.installation_id === undefined,
    };
  }
}
