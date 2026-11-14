import { AuthError } from './errors';
import { GitHubUnavailable } from './github';
import type { GitHubAppApi, GitHubInstallation } from './github-app';
import { namespaceProblem, type NamespaceRecord, type NamespaceStore } from './namespaces';

/**
 * The membership check of docs/design/namespaces.md 2.2, used for every write in an organization namespace, and the
 * creation of an organization namespace, which binds the App's installation to it. It works from ids only:
 *
 * 1. the namespace's installation, as the App: its account id must be the namespace's GitHub id; it gives the
 *    organization's current login;
 * 2. the caller's current login, from the caller's id;
 * 3. the caller's membership in the organization, from those two logins: it passes only for the caller's id, `state:
 *    active` and `role` `admin` or `member`.
 *
 * A pass is kept 5 minutes per (organization id, account id); a refusal is never kept. GitHub unreachable, rate limited
 * or answering anything else is `unavailable`, and an expired pass is never used in its place.
 */

/** How long a pass is reused: a removal from the organization takes effect within this. */
export const MEMBERSHIP_PASS_MS = 5 * 60 * 1000;

export type OrgRole = 'admin' | 'member';

/** The codes of section 8 this module raises besides `unavailable` (spec/proposed/namespaces.md, "New error codes"). */
export type NamespaceErrorCode = 'invalid_namespace' | 'namespace_reserved' | 'not_namespace_member' | 'namespace_unverified';

export const NAMESPACE_HTTP_STATUS: Record<NamespaceErrorCode, number> = {
  invalid_namespace: 400,
  namespace_reserved: 403,
  not_namespace_member: 403,
  namespace_unverified: 403,
};

/** A refused write or creation in a namespace. Same shape as AuthError (code, status, detail), so a router answers both alike. */
export class NamespaceError extends Error {
  readonly status: number;
  constructor(
    readonly code: NamespaceErrorCode,
    message: string,
    /** `namespace`, and for `namespace_unverified` the `detail` of its message. */
    readonly detail: Record<string, string>,
  ) {
    super(message);
    this.name = 'NamespaceError';
    this.status = NAMESPACE_HTTP_STATUS[code];
  }
}

const notMember = (namespace: string) => new NamespaceError('not_namespace_member', `You cannot write in '${namespace}'.`, { namespace });
const unverified = (namespace: string, detail: string) =>
  new NamespaceError('namespace_unverified', `'${namespace}' cannot be verified on GitHub: ${detail}.`, { namespace, detail });
const unavailable = (namespace: string, why: string) =>
  new AuthError('unavailable', `GitHub could not be asked about '${namespace}': ${why}.`, { namespace, service: 'GitHub' });

/** The reasons of `namespace_unverified`, as its message shows them. */
export const UNVERIFIED = {
  noInstallation: 'the mopm registry GitHub App is not installed on the organization',
  suspended: 'the mopm registry GitHub App is suspended on the organization',
  otherAccount: 'the GitHub App installation belongs to another GitHub account',
  notOrg: 'it is not an organization namespace',
  boundElsewhere: 'it is bound to another GitHub account',
  /** The installation GitHub found for the string is on an organization whose current login is another (a redirect). */
  otherLogin: 'the organization found under that login is now called something else on GitHub',
} as const;

/** A kept pass. `expires_at` is decided in code: a row past it is never used, whether or not the store has removed it. */
export interface MembershipPass {
  role: OrgRole;
  expires_at: string;
}

/** Where passes are kept. The memory adapter defines the rules; the DynamoDB adapter keeps them. */
export interface MembershipPassStore {
  getPass(org_id: number, account_id: number): Promise<MembershipPass | undefined>;
  /** Keep a pass, replacing any earlier one of the pair. */
  putPass(org_id: number, account_id: number, pass: MembershipPass): Promise<void>;
}

export const passKey = (org_id: number, account_id: number) => `${org_id}:${account_id}`;

export class MemoryMembershipPassStore implements MembershipPassStore {
  private rows = new Map<string, MembershipPass>();
  async getPass(org_id: number, account_id: number) {
    const p = this.rows.get(passKey(org_id, account_id));
    return p && { ...p };
  }
  async putPass(org_id: number, account_id: number, pass: MembershipPass) {
    this.rows.set(passKey(org_id, account_id), { ...pass });
  }
}

export interface MembershipCheckOptions {
  /** `admin` for the creation of a namespace; `member` (the default) for every other write. */
  require?: OrgRole;
  /** Reuse a kept pass; false for the creation, which always asks GitHub. A pass is kept either way. */
  reuse?: boolean;
}

export interface OrgMembershipDeps {
  app: GitHubAppApi;
  passes: MembershipPassStore;
  now: () => Date;
}

/** Turn a GitHubUnavailable into `unavailable` naming the namespace; anything else is a defect and goes on as it is. */
async function asking<T>(namespace: string, call: () => Promise<T>): Promise<T> {
  try {
    return await call();
  } catch (e) {
    if (e instanceof GitHubUnavailable) throw unavailable(namespace, e.message);
    throw e;
  }
}

export class OrgMembership {
  constructor(private readonly d: OrgMembershipDeps) {}

  /** Step 1: the installation must exist, be active, and be on the namespace's account. */
  private async installation(rec: NamespaceRecord): Promise<GitHubInstallation> {
    if (rec.kind !== 'org') throw unverified(rec.namespace, UNVERIFIED.notOrg);
    if (rec.installation_id === undefined) throw unverified(rec.namespace, UNVERIFIED.noInstallation);
    const inst = await asking(rec.namespace, () => this.d.app.getInstallation(rec.installation_id!));
    if (!inst) throw unverified(rec.namespace, UNVERIFIED.noInstallation);
    if (inst.account.id !== rec.github_id) throw unverified(rec.namespace, UNVERIFIED.otherAccount);
    if (inst.suspended) throw unverified(rec.namespace, UNVERIFIED.suspended);
    return inst;
  }

  /** Steps 2 and 3 for an installation already checked against the namespace: the caller's role, or a refusal. */
  private async role(namespace: string, inst: GitHubInstallation, account_id: number, require: OrgRole): Promise<OrgRole> {
    const user = await asking(namespace, () => this.d.app.getUserById(inst.id, account_id));
    // No such account on GitHub any more: it is a member of nothing.
    if (!user) throw notMember(namespace);
    if (user.id !== account_id) throw unavailable(namespace, 'GitHub answered another user for the account id');
    const m = await asking(namespace, () => this.d.app.getOrgMembership(inst.id, inst.account.login, user.login));
    // 404: not a member, or an outside collaborator. Another id: the login now belongs to someone else.
    if (!m || m.user_id !== account_id) throw notMember(namespace);
    if (m.state === 'pending' || m.role === 'billing_manager') throw notMember(namespace);
    if (m.state !== 'active' || (m.role !== 'admin' && m.role !== 'member')) {
      throw unavailable(namespace, `GitHub answered a membership of state '${m.state}' and role '${m.role}'`);
    }
    if (require === 'admin' && m.role !== 'admin') throw notMember(namespace);
    return m.role;
  }

  private async keep(org_id: number, account_id: number, role: OrgRole) {
    const expires_at = new Date(this.d.now().getTime() + MEMBERSHIP_PASS_MS).toISOString();
    await this.d.passes.putPass(org_id, account_id, { role, expires_at });
  }

  /**
   * May `account_id` write in the organization namespace `rec`? Answers the caller's role; throws NamespaceError
   * (`not_namespace_member`, `namespace_unverified`) or AuthError `unavailable`. A namespace whose installation is gone,
   * suspended or on another account is frozen: every write is refused until an admin binds a new installation
   * (bindOrgNamespace), so the frozen state is not stored.
   */
  async check(rec: NamespaceRecord, account_id: number, o: MembershipCheckOptions = {}): Promise<OrgRole> {
    const require = o.require ?? 'member';
    if (o.reuse !== false && rec.kind === 'org') {
      const kept = await this.d.passes.getPass(rec.github_id, account_id);
      const fresh = kept !== undefined && Date.parse(kept.expires_at) > this.d.now().getTime();
      if (fresh && (require === 'member' || kept.role === 'admin')) return kept.role;
    }
    const inst = await this.installation(rec);
    const role = await this.role(rec.namespace, inst, account_id, require);
    await this.keep(rec.github_id, account_id, role);
    return role;
  }

  /**
   * `POST /api/v2/namespaces`: create the organization namespace `namespace`, or bind a new installation to it. The App's
   * installation is looked up by the namespace string (the one call that sends a string to GitHub), the caller must be
   * an active admin, checked without reuse, and the namespace is bound to the installation's account id. An existing
   * namespace is rebound only when that account id is its GitHub id: an organization that took the old name is refused.
   *
   * Answers what happened: `created`, `rebound` (a new installation on the same organization), or `held` (nothing to do).
   */
  async bindOrgNamespace(
    store: NamespaceStore,
    namespace: string,
    account_id: number,
  ): Promise<{ status: 'created' | 'rebound' | 'held'; record: NamespaceRecord }> {
    const problem = namespaceProblem(namespace);
    if (problem === 'invalid') throw new NamespaceError('invalid_namespace', `'${namespace}' is not a valid namespace.`, { namespace });
    if (problem === 'reserved') throw new NamespaceError('namespace_reserved', `'${namespace}' is reserved.`, { namespace });
    const held = await store.getNamespace(namespace);
    if (held && held.kind !== 'org') throw unverified(namespace, UNVERIFIED.notOrg);
    const inst = await asking(namespace, () => this.d.app.getOrgInstallation(namespace));
    if (!inst) throw unverified(namespace, UNVERIFIED.noInstallation);
    // A namespace is made only for the organization that holds that login now: an old login GitHub still resolves to a
    // renamed organization must not become its namespace while someone else may hold the login.
    if (!held && inst.account.login.toLowerCase() !== namespace) throw unverified(namespace, UNVERIFIED.otherLogin);
    if (held && held.github_id !== inst.account.id) throw unverified(namespace, UNVERIFIED.boundElsewhere);
    if (inst.suspended) throw unverified(namespace, UNVERIFIED.suspended);
    const role = await this.role(namespace, inst, account_id, 'admin');
    await this.keep(inst.account.id, account_id, role);

    const want: NamespaceRecord = {
      namespace,
      kind: 'org',
      github_id: inst.account.id,
      created_at: this.d.now().toISOString(),
      installation_id: inst.id,
    };
    let current = held;
    if (!current) {
      const made = await store.createNamespace(want);
      if (made.created) return { status: 'created', record: made.record };
      // Lost a race with another create: the winner's binding decides, as if it had been there first.
      current = made.record;
      if (current.kind !== 'org') throw unverified(namespace, UNVERIFIED.notOrg);
      if (current.github_id !== inst.account.id) throw unverified(namespace, UNVERIFIED.boundElsewhere);
    }
    if (current.installation_id === inst.id) return { status: 'held', record: current };
    const bound = await store.bindInstallation(namespace, inst.account.id, inst.id);
    // The row was read as this organization's; rows are never deleted and their id never changes.
    if (!bound) throw new Error(`namespace ${namespace}: the installation could not be bound to its own row`);
    return { status: 'rebound', record: bound };
  }
}
