// Which registry a page talks to, from the hostname it is served on.
//
// One build serves every stage, so the API host is not baked in: it comes from this fixed table. Any other hostname
// (a preview, a mirror, localhost) gets no API at all, and the page shows an error instead of calling anything. The
// API's CORS origin enforces the same pairing, and so does the site stack's CSP (connect-src names only the stage's own
// API host, service/infra/stacks/lib/site-stack.ts).

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

/**
 * The read API base URL for a site hostname, e.g. 'https://api.mopm.dev/api/v2', or null for an unknown host. The site
 * reads version 2, whose packages are full names `<namespace>/<name>` (spec/api/openapi-v2.yaml).
 */
export function apiBase(hostname: string): string | null {
  return known(hostname) ? `https://api.${hostname}/api/v2` : null;
}

/**
 * The conda channel root for a site hostname, e.g. 'https://conda.mopm.dev/', or null for an unknown host. Each
 * namespace's channel is under it (snippet.ts namespaceChannel).
 */
export function condaBase(hostname: string): string | null {
  return known(hostname) ? `https://conda.${hostname}/` : null;
}
