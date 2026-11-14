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

/** The channel bucket's other top-level prefixes (service/infra/stacks/lib/channel-stack.ts). */
export const RESERVED_NAMESPACES: readonly string[] = ['index', 'quarantine', 'native-mirror'];

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
  /** Organization namespaces only: the bound installation of the registry's GitHub App. */
  installation_id?: number;
}

/**
 * Persistence for namespaces. The memory adapter defines the rules; the DynamoDB adapter keeps them
 * (test/auth-namespaces.test.ts runs one suite over both). No operation deletes or rebinds a namespace.
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
}

const copy = <T>(v: T): T => structuredClone(v);

export class MemoryNamespaceStore implements NamespaceStore {
  private rows = new Map<string, NamespaceRecord>();

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
export async function ensureUserNamespace(
  store: NamespaceStore,
  github_id: number,
  login: string,
  now: string,
): Promise<UserNamespaceOutcome> {
  const namespace = login.toLowerCase();
  const problem = namespaceProblem(namespace);
  if (problem) return { status: problem, namespace };
  const held = await store.getNamespace(namespace);
  if (held) return { status: held.github_id === github_id ? 'held' : 'taken', namespace };
  const r = await store.createNamespace({ namespace, kind: 'user', github_id, created_at: now });
  // Lost a race with another create of the same string: the winner's binding decides, as if it had been there first.
  if (!r.created) return { status: r.record.github_id === github_id ? 'held' : 'taken', namespace };
  return { status: 'created', namespace };
}
