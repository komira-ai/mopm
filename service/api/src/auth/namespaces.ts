/**
 * Owner namespaces (docs/design/namespaces.md, sections 1 and 2): the grammar, the reserved strings, the store port and
 * the user namespace made at login.
 *
 * A namespace is keyed by its string and bound to a GitHub numeric id, never to a login: a renamed account keeps its old
 * namespace (section 2.3) and gains its new login as a second one if that is free; whoever later takes the old login on
 * GitHub gets nothing. No namespace string is ever sent to GitHub from here.
 */

/** A namespace is a GitHub login in lower case: letters, digits and single hyphens, at most 39 characters. */
export const NAMESPACE_PATTERN = /^[a-z0-9]+(-[a-z0-9]+)*$/;
export const NAMESPACE_MAX_LENGTH = 39;

/** The shape of a conda subdir: a namespace of that shape would make a channel URL ambiguous. */
export const CONDA_SUBDIR_SHAPE = /^(noarch|(linux|osx|win|freebsd|zos|wasi|emscripten)-[a-z0-9]+)$/;

/**
 * The channel bucket's other top-level prefixes (service/infra/stacks/lib/channel-stack.ts), and `poll`, the path segment of
 * `POST /api/v2/namespaces/poll`, which would otherwise read as a namespace.
 */
export const RESERVED_NAMESPACES: readonly string[] = ['index', 'quarantine', 'native-mirror', 'poll'];

/** Why a string is not a namespace anyone may get, or undefined when it may be one. */
export type NamespaceProblem = 'invalid' | 'reserved';

export function namespaceProblem(ns: string): NamespaceProblem | undefined {
  if (ns.length < 1 || ns.length > NAMESPACE_MAX_LENGTH || !NAMESPACE_PATTERN.test(ns)) return 'invalid';
  if (CONDA_SUBDIR_SHAPE.test(ns) || RESERVED_NAMESPACES.includes(ns)) return 'reserved';
  return undefined;
}

export type NamespaceKind = 'user' | 'org';

export interface NamespaceRecord {
  namespace: string;
  kind: NamespaceKind;
  /** The user's or the organization's GitHub numeric id: the binding. It never changes. */
  github_id: number;
  created_at: string;
  /** Organization namespaces only: the GitHub account that registered it (its first owner). */
  created_by?: number;
}

/** `owner` manages the members and may do everything a `member` may; a `member` creates packages and publishes. */
export type MemberRole = 'owner' | 'member';

/** One account's membership of one organization namespace. */
export interface NamespaceMember {
  /** An organization namespace. */
  namespace: string;
  /** The member account's GitHub numeric id. */
  github_id: number;
  role: MemberRole;
  /** GitHub id of the owner who added the account (the registrant, for the first owner). */
  added_by: number;
  /** ISO time of the add, or of the last change of role. */
  added_at: string;
}

/**
 * Persistence for namespaces and the members of organization namespaces. The memory adapter defines the rules; the DynamoDB
 * adapter keeps them (test/auth-namespaces.test.ts runs one suite over both). No operation deletes a namespace or changes
 * its GitHub id. An organization namespace always has at least one owner: it is created with one, and no operation leaves
 * it with none.
 */
export interface NamespaceStore {
  getNamespace(namespace: string): Promise<NamespaceRecord | undefined>;
  /**
   * Create once: when no row has `rec.namespace`, store `rec` and answer `{created: true, record: rec}`; otherwise store
   * nothing and answer the row that holds the string, whoever it is bound to. Atomic: of two racing creates one wins.
   */
  createNamespace(rec: NamespaceRecord): Promise<{ created: boolean; record: NamespaceRecord }>;
  /** Every namespace bound to the GitHub id, in namespace order. */
  listNamespaces(github_id: number): Promise<NamespaceRecord[]>;
  /**
   * Create an organization namespace (`rec.kind` is `org`, `owner.namespace` is `rec.namespace`) and its first owner in one
   * atomic step. When a row already has the string, nothing is written and the answer is `created: false` with the held row.
   */
  createOrgNamespace(rec: NamespaceRecord, owner: NamespaceMember): Promise<{ created: boolean; record: NamespaceRecord }>;
  /** The account's membership of an organization namespace, or undefined when it is not a member. Strongly consistent. */
  getMember(namespace: string, github_id: number): Promise<NamespaceMember | undefined>;
  /** Every member of an organization namespace, sorted by GitHub id. Strongly consistent. */
  listMembers(namespace: string): Promise<NamespaceMember[]>;
  /** Every organization namespace the account is a member of, sorted by namespace. May lag a change briefly in DynamoDB (an index). */
  listMemberships(github_id: number): Promise<NamespaceMember[]>;
  /**
   * Add the account, or change its role. `added`: it was not a member; `changed`: its role is now `m.role`; `same`: it already
   * had that role (nothing is written); `last_owner`: it would leave the namespace with no owner (demoting the only owner;
   * nothing is written). Throws when `m.namespace` is not an organization namespace.
   */
  setMember(m: NamespaceMember): Promise<'added' | 'changed' | 'same' | 'last_owner'>;
  /**
   * Remove the account. `not_member`: it is not one; `last_owner`: it is the only owner. Nothing is written in either case.
   * `removed_by` and `at` say who removed it and when (kept by the DynamoDB adapter, which cannot delete a row).
   */
  removeMember(namespace: string, github_id: number, removed_by: number, at: string): Promise<'removed' | 'not_member' | 'last_owner'>;
}

/** What setMember and removeMember decide from the members of one namespace; both adapters use it. */
export function decideSet(members: NamespaceMember[], m: NamespaceMember): 'added' | 'changed' | 'same' | 'last_owner' {
  const held = members.find((x) => x.github_id === m.github_id);
  if (!held) return 'added';
  if (held.role === m.role) return 'same';
  if (held.role === 'owner' && members.filter((x) => x.role === 'owner').length === 1) return 'last_owner';
  return 'changed';
}

export function decideRemove(members: NamespaceMember[], github_id: number): 'removed' | 'not_member' | 'last_owner' {
  const held = members.find((x) => x.github_id === github_id);
  if (!held) return 'not_member';
  if (held.role === 'owner' && members.filter((x) => x.role === 'owner').length === 1) return 'last_owner';
  return 'removed';
}

const copy = <T>(v: T): T => structuredClone(v);

export class MemoryNamespaceStore implements NamespaceStore {
  private rows = new Map<string, NamespaceRecord>();
  private members = new Map<string, Map<number, NamespaceMember>>();

  async getNamespace(namespace: string) {
    const r = this.rows.get(namespace);
    return r && copy(r);
  }
  async createNamespace(rec: NamespaceRecord) {
    const held = this.rows.get(rec.namespace);
    if (held) return { created: false, record: copy(held) };
    this.rows.set(rec.namespace, copy(rec));
    return { created: true, record: copy(rec) };
  }
  async listNamespaces(github_id: number) {
    return [...this.rows.values()]
      .filter((r) => r.github_id === github_id)
      .sort((a, b) => (a.namespace < b.namespace ? -1 : 1)) // keys are unique: never equal
      .map(copy);
  }
  async createOrgNamespace(rec: NamespaceRecord, owner: NamespaceMember) {
    const held = this.rows.get(rec.namespace);
    if (held) return { created: false, record: copy(held) };
    this.rows.set(rec.namespace, copy(rec));
    this.members.set(rec.namespace, new Map([[owner.github_id, copy(owner)]]));
    return { created: true, record: copy(rec) };
  }
  async getMember(namespace: string, github_id: number) {
    const m = this.members.get(namespace)?.get(github_id);
    return m && copy(m);
  }
  async listMembers(namespace: string) {
    return [...(this.members.get(namespace)?.values() ?? [])].sort((a, b) => a.github_id - b.github_id).map(copy);
  }
  async listMemberships(github_id: number) {
    return [...this.members.values()]
      .flatMap((byId) => byId.get(github_id) ?? [])
      .sort((a, b) => (a.namespace < b.namespace ? -1 : 1))
      .map(copy);
  }
  async setMember(m: NamespaceMember) {
    const byId = this.members.get(m.namespace);
    if (!byId) throw new Error(`namespace ${m.namespace} is not an organization namespace`);
    const outcome = decideSet([...byId.values()], m);
    if (outcome === 'added' || outcome === 'changed') byId.set(m.github_id, copy(m));
    return outcome;
  }
  async removeMember(namespace: string, github_id: number, _removed_by: number, _at: string) {
    const byId = this.members.get(namespace);
    const outcome = decideRemove([...(byId?.values() ?? [])], github_id);
    if (outcome === 'removed') byId!.delete(github_id);
    return outcome;
  }
}

/**
 * What a login did about the account's user namespace:
 * - `created`: the lower-cased login was free and is now the account's user namespace;
 * - `held`: the account already holds it (an earlier login);
 * - `taken`: another GitHub id holds it (a renamed account's old namespace, or an organization's); nothing is created;
 * - `reserved`: the login has a reserved shape (a conda subdir, a channel bucket prefix); nothing is created;
 * - `invalid`: the login is outside the namespace grammar (an enterprise-managed login holds `_`); nothing is created.
 * In every case the login itself goes on: the account can still publish in organization namespaces. The outcome is
 * recomputed from the handle and this store when `GET /api/v2/me` reports it (ns-R3), so it is not stored.
 */
export interface UserNamespaceOutcome {
  status: 'created' | 'held' | 'taken' | 'reserved' | 'invalid';
  /** The lower-cased login: the namespace made or held, or the string that could not be one. */
  namespace: string;
}

/**
 * Section 2.1: at every login, the login just read from GitHub becomes the account's user namespace when it fits the
 * grammar, is not reserved and no namespace has that string. GitHub logins ignore case and mopm has one spelling, so the
 * string is the login in lower case. An account's earlier namespaces are untouched: a rename adds one, never moves one.
 */
export async function ensureUserNamespace(store: NamespaceStore, github_id: number, login: string, now: string): Promise<UserNamespaceOutcome> {
  const namespace = login.toLowerCase();
  const problem = namespaceProblem(namespace);
  if (problem) return { status: problem, namespace };
  const held = await store.getNamespace(namespace);
  if (held)
    return {
      status: held.github_id === github_id ? 'held' : 'taken',
      namespace,
    };
  const r = await store.createNamespace({
    namespace,
    kind: 'user',
    github_id,
    created_at: now,
  });
  // Lost a race with another create of the same string: the winner's binding decides, as if it had been there first.
  if (!r.created)
    return {
      status: r.record.github_id === github_id ? 'held' : 'taken',
      namespace,
    };
  return { status: 'created', namespace };
}
