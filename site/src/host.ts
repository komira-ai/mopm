// Which registry a page talks to, from the hostname it is served on.
//
// One build serves every stage, so the API host is not baked in: it comes from this fixed table. Any other hostname
// (a preview, a mirror, localhost) gets no API at all, and the page shows an error instead of calling anything. The
// same pairing is enforced twice more: the API's CORS origin and the site's CSP connect-src.

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

/** The read API base URL for a site hostname, e.g. 'https://api.mopm.dev/api/v1', or null for an unknown host. */
export function apiBase(hostname: string): string | null {
  return known(hostname) ? `https://api.${hostname}/api/v1` : null;
}

/** The conda channel URL for a site hostname, e.g. 'https://conda.mopm.dev/', or null for an unknown host. */
export function condaBase(hostname: string): string | null {
  return known(hostname) ? `https://conda.${hostname}/` : null;
}
