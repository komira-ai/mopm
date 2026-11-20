// Which registry a page talks to, from the hostname it is served on.
//
// One build serves every stage, so nothing stage-specific is baked in. The read API is on the page's own origin: the
// site distribution sends `/api/*` to the stage's API (service/infra/stacks/lib/site-stack.ts), so the base is the
// relative `/api/v2` and every read is same-origin. The page CSP's connect-src is `'self'` plus E2B's sandboxes; it
// names no API host. Only the hosts of this fixed table, and the local preview's, get an API at all: any other hostname
// (a mirror, a deployed preview) gets none, and the page shows an error instead of calling anything. The conda channel
// is still on its own host, `conda.<site host>`.

const SITES: Readonly<Record<string, true>> = Object.freeze(
  Object.assign(Object.create(null) as Record<string, true>, {
    'mopm.dev': true,
    'beta.mopm.dev': true,
    'gamma.mopm.dev': true,
  }),
);

function known(hostname: string): boolean {
  return Object.hasOwn(SITES, hostname);
}

// The local preview (tools/preview.ts) serves the built site on 127.0.0.1 and answers the API on that same origin, as
// the distribution does. Its two loopback names get the API base and no conda channel.
const LOCAL: ReadonlySet<string> = new Set(['127.0.0.1', 'localhost']);

/**
 * The read API's base, on the page's own origin. The site reads version 2, whose packages are full names
 * `<namespace>/<name>` (spec/api/openapi-v2.yaml).
 */
export const API_BASE = '/api/v2';

/** The read API base for a site hostname: API_BASE for a site host or the local preview, null for any other host. */
export function apiBase(hostname: string): string | null {
  return LOCAL.has(hostname) || known(hostname) ? API_BASE : null;
}

/**
 * The conda channel root for a site hostname, e.g. 'https://conda.mopm.dev/', or null for an unknown host. Each
 * namespace's channel is under it (snippet.ts namespaceChannel).
 */
export function condaBase(hostname: string): string | null {
  return known(hostname) ? `https://conda.${hostname}/` : null;
}
