import { invalidNamespace, namespaceReserved } from '../auth/namespace-access';
import { namespaceProblem } from '../auth/namespaces';
import { RegistryError } from '../errors';
import { NAME_PATTERN, splitFullName } from '../names';
import type { PackageRecord, PackageSummaryRecord } from '../types';
import { canonicalVersion } from '../version';
import {
  MAX_UPDATED_SCAN,
  SEARCH_PAGE,
  bad,
  decodeCursor,
  encodeCursor,
  normaliseQuery,
  packageInfo,
  parseLimit,
  summarise,
  updatedPage,
  versionDetail,
  versionPage,
  type HttpRequest,
  type RouterDeps,
} from './router';
import type { V2Deps } from './v2-routes';

/**
 * The read operations of `/api/v2`: search, package, versions, version, namespace. A v2 package is a row whose name is the
 * full name `<namespace>/<name>`; these operations see only those rows (`/api/v1` sees only the flat ones).
 */

/** A search `q`: a namespace (39), `/`, and a name (64). */
const Q_MAX = 104;
const NAME_MAX = 64;
/** A `q` with no `/` reads the name index, which is sorted by full name, so it may read rows it does not return. Beyond this many it refuses. */
export const MAX_SCAN_ROWS = 2000;

/** Why `ns` names nothing: outside the grammar, or one nobody can hold. Reads of a namespace's packages say so before looking. */
function checkNamespace(ns: string): void {
  const problem = namespaceProblem(ns);
  if (problem === 'invalid') throw invalidNamespace(ns);
  if (problem === 'reserved') throw namespaceReserved(ns);
}

function checkName(name: string): void {
  if (!NAME_PATTERN.test(name)) throw new RegistryError('invalid_name', `'${name}' is not a valid package name.`, { name });
}

/** The package row of `<namespace>/<name>`, or `package_not_found`. */
async function requirePackageV2(deps: RouterDeps, namespace: string, name: string): Promise<PackageRecord> {
  checkNamespace(namespace);
  checkName(name);
  const full = `${namespace}/${name}`;
  const p = await deps.store.getPackage(full);
  if (!p) throw new RegistryError('package_not_found', `There is no package '${full}'.`, { name: full });
  return p;
}

/** What a `q` asks for: the name index from `indexPrefix`, keeping the rows `keep` accepts. */
interface SearchPlan {
  indexPrefix: string;
  keep: (p: PackageSummaryRecord) => boolean;
  /** Does a name cursor belong to this query? */
  owns: (after: string) => boolean;
}

function planSearch(q: string): SearchPlan {
  // A client may send the `/` of `<namespace>/` as `%2F`.
  const raw = q.replace(/%2f/gi, '/');
  if (raw.length > Q_MAX) throw bad(`q is longer than ${Q_MAX} characters`);
  const slash = raw.indexOf('/');
  const ns = slash < 0 ? undefined : raw.slice(0, slash);
  if (ns !== undefined && namespaceProblem(ns) === 'invalid') throw invalidNamespace(ns);
  const namePart = slash < 0 ? raw : raw.slice(slash + 1);
  if (namePart.length > NAME_MAX) throw bad(`the name part of q is longer than ${NAME_MAX} characters`);
  const prefix = normaliseQuery(namePart);
  if (ns !== undefined) {
    // Every row from `<ns>/<prefix>` on is a full name of that namespace: a prefix read of the index.
    const indexPrefix = `${ns}/${prefix}`;
    return { indexPrefix, keep: () => true, owns: (after) => after.startsWith(indexPrefix) };
  }
  const nameStartsWith = (full: string) => splitFullName(full)?.name.startsWith(prefix) === true;
  return { indexPrefix: '', keep: (p) => nameStartsWith(p.name), owns: nameStartsWith };
}

/**
 * Up to `want` rows the plan keeps, in name order after `after`. Rows are read in pages; a plan that keeps only some of
 * what it reads (a name prefix in every namespace) refuses once it has read MAX_SCAN_ROWS rows without finding `want`.
 */
async function scan(deps: RouterDeps, plan: SearchPlan, after: string | undefined, want: number): Promise<PackageSummaryRecord[]> {
  const found: PackageSummaryRecord[] = [];
  let read = 0;
  for (let last = after; ; ) {
    const chunk = await deps.store.searchPackages(plan.indexPrefix, last, SEARCH_PAGE);
    read += chunk.length;
    for (const p of chunk) if (found.length < want && plan.keep(p)) found.push(p);
    if (found.length >= want || chunk.length < SEARCH_PAGE) return found;
    if (read >= MAX_SCAN_ROWS) throw bad(`q is too broad: finding a page reads past ${MAX_SCAN_ROWS} packages; start q with '<namespace>/'`);
    last = chunk[chunk.length - 1]!.name;
  }
}

export async function searchPackagesV2(deps: RouterDeps, query: HttpRequest['query']) {
  const limit = parseLimit(query.limit);
  const sort = query.sort ?? 'name';
  if (sort !== 'name' && sort !== 'updated') throw bad("sort must be 'name' or 'updated'");
  const plan = planSearch(query.q ?? '');
  const after = query.cursor === undefined ? undefined : decodeCursor(query.cursor, sort);

  if (sort === 'name') {
    if (after && !plan.owns(after.after)) throw bad('cursor does not belong to this query');
    // One more than the page, to know whether there is a next page.
    const found = await scan(deps, plan, after?.after, limit + 1);
    const page = found.slice(0, limit);
    return {
      packages: await summarise(deps, page),
      next_cursor: found.length > limit ? encodeCursor({ k: 'name', after: page[page.length - 1]!.name }) : null,
    };
  }

  // sort=updated ranks every match by its newest publication, so it reads them all (there is no index on it yet).
  const matches = await scan(deps, plan, undefined, MAX_UPDATED_SCAN + 1);
  if (matches.length > MAX_UPDATED_SCAN) throw bad(`sort=updated needs a longer q: more than ${MAX_UPDATED_SCAN} packages match`);
  return updatedPage(await summarise(deps, matches), limit, after);
}

/** `PackageInfo` with `namespace` instead of `owners`. A package whose namespace has no row is a registry fault, not an answer. */
export async function getPackageV2(deps: RouterDeps, v2: V2Deps, namespace: string, name: string) {
  const p = await requirePackageV2(deps, namespace, name);
  const record = await v2.namespaces.getNamespace(namespace);
  if (!record) throw new Error(`package '${p.name}' has no namespace row '${namespace}'`);
  return packageInfo(deps, p, async () => ({ namespace: await v2.access.info(record) }));
}

export async function listVersionsV2(deps: RouterDeps, namespace: string, name: string, query: HttpRequest['query']) {
  return versionPage(deps, query, () => requirePackageV2(deps, namespace, name));
}

export async function getVersionV2(deps: RouterDeps, namespace: string, name: string, version: string) {
  checkNamespace(namespace);
  checkName(name);
  canonicalVersion(version); // throws invalid_version before anything is read
  return versionDetail(deps, await requirePackageV2(deps, namespace, name), version, true);
}

/** `NamespaceInfo`, public. */
export async function getNamespaceV2(v2: V2Deps, namespace: string) {
  return v2.access.info(await v2.access.find(namespace));
}
