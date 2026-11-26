// URL routes of the site, and the namespace, name and version grammar they accept.
//
// The site stack's edge router (a CloudFront Function in front of the bucket, service/infra/stacks/lib/site-stack.ts)
// is generated from the expressions below, so it and parseRoute accept the same names and versions:
// test/fixtures/routes.json holds the vectors parseRoute is tested against here and that router is tested against there
// (service/infra/stacks/test/site-router.test.ts). Path segments are matched as they arrive (still percent-encoded): a
// valid name or version contains no character that needs encoding, so any '%' fails.

/** The registry's package name (spec Name, router NAME): 2 to 64 characters. In a full name, the import name. */
export const NAME = /^[a-z][a-z0-9_]{1,63}$/;
/**
 * A namespace (spec Namespace, router NAMESPACE): a GitHub login in lower case, letters, digits and single hyphens. The
 * spec caps it at NAMESPACE_MAX characters, which the pattern does not say, so every check also tests the length.
 * Nothing normalises a namespace: 'Komira-AI' is no namespace, and the API answers it with invalid_namespace.
 */
export const NAMESPACE = /^[a-z0-9]+(-[a-z0-9]+)*$/;
export const NAMESPACE_MAX = 39;
/**
 * The registry's version grammar (spec Version): MAJOR.MINOR.PATCH, no leading zeros, no suffix. One version has one
 * spelling, so '1.0' or '1.0.0.0' is not a version route (the API would refuse it). The server caps the length at
 * VERSION_MAX.
 */
export const VERSION = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/;
export const VERSION_MAX = 128;
/**
 * The last segment of a package's full version list, `/packages/<namespace>/<name>/versions`. A version starts with a
 * digit, so the segment is never a version.
 */
export const VERSIONS_SEGMENT = 'versions';
/** A docs page slug (`/docs/<slug>/`, src/links.ts DOC_PAGES); the edge router serves `/docs/<slug>/index.html` for it. */
export const DOC_SLUG = /^[a-z0-9-]{1,64}$/;
/**
 * The tutorial's index page. The edge router serves it, and each lesson's page `/tutorial/<lesson>`, from the build's
 * `tutorial/index.html` and `tutorial/<lesson>/index.html`, on a stage the site stack ships the tutorial to. No trailing
 * slash: the sign-in's `return_to` keeps exactly these two forms (session.ts isReturnPath), so a page the router serves
 * is one a sign-in can come back to.
 */
export const TUTORIAL_PATH = '/tutorial';
/** A lesson id (spec/tutorial-lesson.schema.json, `id`), the `<lesson>` of `/tutorial/<lesson>`. */
export const LESSON = /^[a-z0-9]+(-[a-z0-9]+)*$/;
/** The runs of separators the registry's normalisation folds into one '_' (normaliseName). */
export const NAME_SEPARATORS = /[-._]+/g;

export function isName(s: string): boolean {
  return NAME.test(s);
}

export function isNamespace(s: string): boolean {
  return s.length <= NAMESPACE_MAX && NAMESPACE.test(s);
}

export function isVersion(s: string): boolean {
  return s.length <= VERSION_MAX && VERSION.test(s);
}

/** The registry's normalisation: lowercase, then each run of '-', '.' and '_' becomes one '_'. */
export function normaliseName(s: string): string {
  return s.toLowerCase().replace(NAME_SEPARATORS, '_');
}

/**
 * A name as the registry spells it in paths: valid and already normalised. `foo__bar` passes NAME but is not
 * normalised (the API answers it with invalid_name), so it is not a package route; the edge router redirects it to
 * `foo_bar`.
 */
export function isCanonicalName(s: string): boolean {
  return isName(s) && normaliseName(s) === s;
}

/** A package's name, `<namespace>/<name>` (spec FullName), in its two parts. */
export interface FullName {
  namespace: string;
  name: string;
}

/** `<namespace>/<name>` as the registry spells it. */
export function fullName(f: FullName): string {
  return `${f.namespace}/${f.name}`;
}

/**
 * The two parts of a full name the site may build a path from: a namespace, one '/', and a canonical name. Anything else
 * (a flat name, a second '/', a name the registry would normalise) is null, and a page shows the string as text.
 */
export function splitFullName(s: string): FullName | null {
  const slash = s.indexOf('/');
  if (slash < 0) return null;
  const namespace = s.slice(0, slash);
  const name = s.slice(slash + 1);
  return isNamespace(namespace) && isCanonicalName(name) ? { namespace, name } : null;
}

export type Route =
  | { kind: 'search' }
  | ({ kind: 'package' } & FullName)
  | ({ kind: 'versions' } & FullName)
  | ({ kind: 'version'; version: string } & FullName);

/**
 * The app-shell view for a path, or null when the path is not an app route (the edge router must never send it to the
 * shell). A package is `/packages/<namespace>/<name>`, its full version list `/packages/<namespace>/<name>/versions`, a
 * version `/packages/<namespace>/<name>/<version>`. The flat
 * addresses of the names before namespaces, `/packages/<name>` and `/packages/<name>/<version>`, are no app route: the
 * edge router sends them to a search for the name (flatSearchPath). A name starts with a letter and a version with a
 * digit, so `/packages/<a>/<b>` is never both a package and a flat version.
 */
export function parseRoute(path: string): Route | null {
  if (path === '/search') return { kind: 'search' };
  const parts = path.split('/');
  // parts[0] is the empty string before the leading '/'.
  if (parts[0] !== '' || parts[1] !== 'packages' || (parts.length !== 4 && parts.length !== 5)) return null;
  const [, , namespace, name] = parts;
  if (!isNamespace(namespace) || !isCanonicalName(name)) return null;
  if (parts.length === 4) return { kind: 'package', namespace, name };
  if (parts[4] === VERSIONS_SEGMENT) return { kind: 'versions', namespace, name };
  return isVersion(parts[4]) ? { kind: 'version', namespace, name, version: parts[4] } : null;
}

/**
 * Where the edge router sends a one-segment package address, or a flat version address of the names before namespaces,
 * or null when the path is neither (the router answers it with the 404 page, status 404):
 *  - `/packages/<name>` (a canonical name) and `/packages/<name>/<version>`: a search for the name in every namespace.
 *    A flat name became `<namespace>/<name>` with the same name, so the search lists it.
 *  - `/packages/<namespace>` that is no canonical name ('komira-ai'): the namespace's packages.
 *  - any other spelling that normalises to a name ('HTTP-Client'): a search for the normalised name.
 * A segment that is both a name and a namespace ('json') is read as the name, as the flat address meant.
 */
export function flatSearchPath(path: string): string | null {
  const parts = path.split('/');
  if (parts[0] !== '' || parts[1] !== 'packages') return null;
  if (parts.length === 3) {
    const s = parts[2];
    if (isCanonicalName(s)) return searchPath({ q: s });
    if (isNamespace(s)) return namespaceSearchPath(s);
    const n = normaliseName(s);
    return isName(n) ? searchPath({ q: n }) : null;
  }
  if (parts.length === 4 && isCanonicalName(parts[2]) && isVersion(parts[3])) return searchPath({ q: parts[2] });
  return null;
}

export type SearchSort = 'name' | 'updated';

export interface SearchParams {
  q?: string;
  sort?: SearchSort;
  cursor?: string;
}

/** '/search' with its query; empty values are left out, so '/search' alone is the unfiltered first page. */
export function searchPath(p: SearchParams = {}): string {
  const qs = new URLSearchParams();
  if (p.q) qs.set('q', p.q);
  if (p.sort && p.sort !== 'name') qs.set('sort', p.sort);
  if (p.cursor) qs.set('cursor', p.cursor);
  const s = qs.toString();
  return s ? `/search?${s}` : '/search';
}

export function packagePath(f: FullName): string {
  return `/packages/${encodeURIComponent(f.namespace)}/${encodeURIComponent(f.name)}`;
}

/** A package's full version list. */
export function versionsPath(f: FullName): string {
  return `${packagePath(f)}/${VERSIONS_SEGMENT}`;
}

export function versionPath(f: FullName, version: string): string {
  return `${packagePath(f)}/${encodeURIComponent(version)}`;
}

/** The search that lists one namespace's packages ('/search?q=komira-ai%2F'). */
export function namespaceSearchPath(namespace: string): string {
  return searchPath({ q: `${namespace}/` });
}
