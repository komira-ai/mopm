import { AuthError, NamespaceError } from './errors';
import { notNamespaceMember, notNamespaceOwner, type NamespaceAccess } from './namespace-access';
import type { MemberRole, NamespaceMember, NamespaceRecord, NamespaceStore } from './namespaces';
import type { Clock } from './tokens';
import type { AuthStore } from './types';

/**
 * The members of an organization namespace, managed in mopm by mopm username (the account's user namespace). Only the member
 * table is read or written: GitHub is never asked. Reading is for any owner or member; adding, changing a role and removing are
 * for owners. The last owner is never demoted or removed.
 */

/** `Member` of spec/api/openapi-v2.yaml. */
export interface MemberView {
  user: string;
  handle: string;
  github_id: number;
  role: MemberRole;
  added_at: string;
}

export interface OrgMembersDeps {
  namespaces: NamespaceStore;
  access: NamespaceAccess;
  users: Pick<AuthStore, 'getUser'>;
  now?: Clock;
}

const userNotFound = (user: string) => new NamespaceError('user_not_found', `There is no mopm user '${user}'.`, { user });

const memberNotFound = (user: string, namespace: string) => new NamespaceError('member_not_found', `'${user}' is not a member of '${namespace}'.`, { user, namespace });

export class OrgMembers {
  private readonly now: Clock;
  constructor(private readonly d: OrgMembersDeps) {
    this.now = d.now ?? (() => new Date());
  }

  /** The row of `namespace`, which must be an organization's: a user namespace has no members (`invalid_request`). */
  private async org(namespace: string): Promise<NamespaceRecord> {
    const record = await this.d.access.find(namespace);
    if (record.kind !== 'org') {
      throw new AuthError('invalid_request', `The request is not valid: '${namespace}' is a user namespace; it has no members.`, {
        detail: `'${namespace}' is a user namespace; it has no members`,
      });
    }
    return record;
  }

  /** The caller's membership; `not_namespace_member` when it has none. With `owner`, a plain member is `not_namespace_owner`. */
  private async caller(namespace: string, account_id: number, owner: boolean): Promise<void> {
    const m = await this.d.namespaces.getMember(namespace, account_id);
    if (!m) throw notNamespaceMember(namespace);
    if (owner && m.role !== 'owner') throw notNamespaceOwner(namespace);
  }

  /** The account `user` names: a row of kind `user`. Any other string, an organization's included, is `user_not_found`. */
  private async account(user: string): Promise<number> {
    const row = await this.d.namespaces.getNamespace(user);
    if (!row || row.kind !== 'user') throw userNotFound(user);
    return row.github_id;
  }

  /**
   * The name a member goes by: its user namespace equal to its handle in lower case, else the first of its user namespaces, else
   * (an account that never made one) its handle in lower case.
   */
  private async view(m: NamespaceMember): Promise<MemberView> {
    const handle = (await this.d.users.getUser(m.github_id))?.handle;
    const own = (await this.d.namespaces.listNamespaces(m.github_id)).filter((r) => r.kind === 'user').map((r) => r.namespace);
    const user = (handle !== undefined && own.includes(handle.toLowerCase()) ? handle.toLowerCase() : own[0]) ?? (handle ?? String(m.github_id)).toLowerCase();
    return { user, handle: handle ?? user, github_id: m.github_id, role: m.role, added_at: m.added_at };
  }

  /** Every member, sorted by `user`. Readable by an owner or a member. */
  async list(account_id: number, namespace: string): Promise<{ namespace: string; members: MemberView[] }> {
    await this.org(namespace);
    await this.caller(namespace, account_id, false);
    const members = await Promise.all((await this.d.namespaces.listMembers(namespace)).map((m) => this.view(m)));
    return { namespace, members: members.sort((a, b) => (a.user < b.user ? -1 : a.user > b.user ? 1 : a.github_id - b.github_id)) };
  }

  /** Add the account named `user`, or change its role. `created` is true when it was not a member. Owners only. */
  async set(account_id: number, namespace: string, user: string, role: unknown): Promise<{ created: boolean; member: MemberView }> {
    await this.org(namespace);
    await this.caller(namespace, account_id, true);
    if (role !== 'owner' && role !== 'member') {
      throw new AuthError('invalid_request', "The request is not valid: 'role' must be 'owner' or 'member'.", { detail: "'role' must be 'owner' or 'member'" });
    }
    const github_id = await this.account(user);
    const at = this.now().toISOString();
    const outcome = await this.d.namespaces.setMember({ namespace, github_id, role, added_by: account_id, added_at: at });
    if (outcome === 'last_owner') {
      throw new NamespaceError('last_owner', `'${user}' is the last owner of '${namespace}'.`, { user, namespace });
    }
    const held: NamespaceMember | undefined =
      outcome === 'same'
        ? await this.d.namespaces.getMember(namespace, github_id)
        : { namespace, github_id, role, added_by: account_id, added_at: at };
    if (!held) throw memberNotFound(user, namespace);
    return { created: outcome === 'added', member: await this.view(held) };
  }

  /** Remove the account named `user`. Owners only; an owner may remove themselves while another owner remains. */
  async remove(account_id: number, namespace: string, user: string): Promise<void> {
    await this.org(namespace);
    await this.caller(namespace, account_id, true);
    const github_id = await this.account(user);
    const outcome = await this.d.namespaces.removeMember(namespace, github_id, account_id, this.now().toISOString());
    if (outcome === 'not_member') throw memberNotFound(user, namespace);
    if (outcome === 'last_owner') throw new NamespaceError('last_owner', `'${user}' is the last owner of '${namespace}'.`, { user, namespace });
  }
}
