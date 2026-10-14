// URL routes of the site, and the name and version grammar they accept.
//
// The edge router (a CloudFront Function in the site stack) and parseRoute must agree on which paths reach the app
// shell: test/fixtures/routes.json holds the vectors both are tested against. Path segments are matched as they arrive
// (still percent-encoded): a valid name or version contains no character that needs encoding, so any '%' fails.

/** The registry's package name (spec Name, router NAME): 2 to 64 characters. */
export const NAME = /^[a-z][a-z0-9_]{1,63}$/;
/** The registry's version grammar (spec Version); the server also caps its length at VERSION_MAX. */
export const VERSION = /^(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*))*((a|b|rc|dev)(0|[1-9][0-9]*))?$/;
export const VERSION_MAX = 128;

export function isName(s: string): boolean {
  return NAME.test(s);
}

export function isVersion(s: string): boolean {
  return s.length <= VERSION_MAX && VERSION.test(s);
}

/** The registry's normalisation: lowercase, then each run of '-', '.' and '_' becomes one '_'. */
export function normaliseName(s: string): string {
  return s.toLowerCase().replace(/[-._]+/g, '_');
}

export type Route =
  | { kind: 'search' }
  | { kind: 'package'; name: string }
  | { kind: 'version'; name: string; version: string };

/** The app-shell view for a path, or null when the path is not an app route (the edge never sends it to the shell). */
export function parseRoute(path: string): Route | null {
  if (path === '/search') return { kind: 'search' };
  const parts = path.split('/');
  // parts[0] is the empty string before the leading '/'.
  if (parts[0] !== '' || parts[1] !== 'packages') return null;
  if (parts.length === 3 && isName(parts[2])) return { kind: 'package', name: parts[2] };
  if (parts.length === 4 && isName(parts[2]) && isVersion(parts[3])) {
    return { kind: 'version', name: parts[2], version: parts[3] };
  }
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

export function packagePath(name: string): string {
  return `/packages/${encodeURIComponent(name)}`;
}

export function versionPath(name: string, version: string): string {
  return `/packages/${encodeURIComponent(name)}/${encodeURIComponent(version)}`;
}
