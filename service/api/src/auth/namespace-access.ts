import type { NamespaceInfo } from '../gen/registry-v2';
import { NamespaceError } from './errors';
import { namespaceProblem, type MemberRole, type NamespaceRecord, type NamespaceStore } from './namespaces';
import type { AuthStore, UserRecord } from './types';

/**
 * Who may write in a namespace (docs/design/namespaces.md 2.4), for every `/api/v2` write an account makes: creating a
 * package, publishing, yanking, the packages of an API token, and the namespaces `GET /api/v2/me` lists.
 *
 * - A user namespace: the account bound to it (role `owner`).
 * - An organization namespace: an account with a row in the namespace's member table, as `owner` or `member`. The table is
 *   the only thing asked: no GitHub call and no cache, so a removed member is refused on the next request.
 *
 * A CI identity's token is not an account: its right comes from the namespace publisher it was minted for
 * (src/auth/oidc.ts), and src/publish/service.ts `requireOwner` accepts it by the names it was minted for.
 */

/** `role` of `MeV2.namespaces[]`: `owner` of a user namespace or an organization's, `member` of an organization's. */
export type NamespaceRole = MemberRole;

export interface WriteRight {
  record: NamespaceRecord;
  role: NamespaceRole;
}

/** `NamespaceInfo` of spec/api/openapi-v2.yaml, generated. */
export type { NamespaceInfo };

export interface NamespaceAccessDeps {
  namespaces: NamespaceStore;
  users: Pick<AuthStore, 'getUser'>;
}

export const invalidNamespace = (namespace: string) => new NamespaceError('invalid_namespace', `'${namespace}' is not a valid namespace.`, { namespace });
export const namespaceReserved = (namespace: string) => new NamespaceError('namespace_reserved', `'${namespace}' is reserved.`, { namespace });
export const namespaceNotFound = (namespace: string) => new NamespaceError('namespace_not_found', `There is no namespace '${namespace}'.`, { namespace });
export const notNamespaceMember = (namespace: string) => new NamespaceError('not_namespace_member', `You cannot write in '${namespace}'.`, { namespace });
export const notNamespaceOwner = (namespace: string) => new NamespaceError('not_namespace_owner', `You are not an owner of '${namespace}'.`, { namespace });

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
   * (`invalid_namespace`, `namespace_reserved`, `namespace_not_found`, `not_namespace_member`).
   */
  async require(namespace: string, account_id: number): Promise<WriteRight> {
    const record = await this.find(namespace);
    return { record, role: await this.roleIn(record, account_id) };
  }

  /** May a CI identity's token (minted for a publisher of `namespace`) write there now? The namespace must exist. Answers the row. */
  async requireCi(namespace: string): Promise<NamespaceRecord> {
    return this.find(namespace);
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
    const member = await this.d.namespaces.getMember(record.namespace, account_id);
    if (!member) throw notNamespaceMember(record.namespace);
    return member.role;
  }

  /**
   * Every namespace the account can write now: its user namespaces (bound to its id, role `owner`), then the organization
   * namespaces of its rows in the member table (role `owner` or `member`). The member list is read from an index and may lag
   * a change briefly. Sorted: user namespaces first, each kind by namespace.
   */
  async writable(user: UserRecord): Promise<WriteRight[]> {
    const own = (await this.d.namespaces.listNamespaces(user.github_id))
      .filter((r) => r.kind === 'user')
      .map((record): WriteRight => ({ record, role: 'owner' }));
    const orgs: WriteRight[] = [];
    for (const m of await this.d.namespaces.listMemberships(user.github_id)) {
      const record = await this.d.namespaces.getNamespace(m.namespace);
      if (record?.kind === 'org') orgs.push({ record, role: m.role });
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

  /** `NamespaceInfo`: a user's login is its handle from its last login. */
  async info(record: NamespaceRecord): Promise<NamespaceInfo> {
    const login = record.kind === 'user' ? ((await this.d.users.getUser(record.github_id))?.handle ?? record.namespace) : record.namespace;
    return {
      namespace: record.namespace,
      kind: record.kind,
      github_id: record.github_id,
      login,
    };
  }
}
