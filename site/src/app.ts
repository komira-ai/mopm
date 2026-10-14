// What the app shell shows for an address: the route, the one API call it needs, and the view for the answer.
//
// Pure apart from the injected client: no DOM, no location, no globals. main.ts passes location and the client for
// this host and mounts the result; tests pass StringDoc and a fake client. An address that is not an app route, or a
// host outside host.ts's table (api null), gets its view without any call; a search too long to send gets its message
// without any call.

import type { Client, Result } from './api.js';
import { type Doc } from './doc.js';
import { parseRoute } from './routes.js';
import type { Health } from './types.js';
import { errorView, notFoundView, pageNotFoundView, readOnlyBanner, unknownHostView, type View } from './views/common.js';
import { packageView } from './views/package.js';
import { readSearch, searchErrorView, searchResultsView, searchTooLongView } from './views/search.js';
import { versionView } from './views/version.js';

/**
 * The API refused the route's name. routes.ts sends only names the spec grammar accepts, so this means the two
 * grammars disagree: nothing is at this address and a Retry cannot help, so the page is the not-found one.
 */
function refusedName(r: { kind: string; code?: string }): boolean {
  return r.kind === 'invalid' && r.code === 'invalid_name';
}

/** `pathname` and `search` are location's; `api` is null on a host outside the table; `host` is location.hostname. */
export async function appView<N>(doc: Doc<N>, pathname: string, search: string, api: Client | null, host: string): Promise<View<N>> {
  const route = parseRoute(pathname);
  if (route === null) return pageNotFoundView(doc);
  if (api === null) return unknownHostView(doc, host);
  const ctx = { host };
  switch (route.kind) {
    case 'search': {
      const { state, tooLong, canonicalPath } = readSearch(search);
      if (tooLong) return { ...searchTooLongView(doc, state), canonicalPath, searchQ: state.q };
      const r = await api.searchPackages({ q: state.q || undefined, sort: state.sort, cursor: state.cursor });
      const view = r.kind === 'ok' ? searchResultsView(doc, state, r.value) : searchErrorView(doc, state, r);
      return { ...view, canonicalPath, searchQ: state.q };
    }
    case 'package': {
      const r = await api.getPackage(route.name);
      if (r.kind === 'ok') return packageView(doc, route.name, r.value, ctx);
      return r.kind === 'notFound' || refusedName(r) ? notFoundView(doc, route.name) : errorView(doc, r);
    }
    case 'version': {
      const r = await api.getVersion(route.name, route.version);
      if (r.kind === 'ok') return versionView(doc, route.name, r.value, ctx);
      if (refusedName(r)) return notFoundView(doc, route.name);
      if (r.kind === 'invalid' && r.code === 'invalid_version') return notFoundView(doc, route.name, route.version);
      if (r.kind !== 'notFound') return errorView(doc, r);
      // The API says which is missing: the package, or only this version of it.
      return r.code === 'package_not_found' ? notFoundView(doc, route.name) : notFoundView(doc, route.name, route.version);
    }
  }
}

/** The read-only banner when getHealth says so; nothing for any other answer, a failure included. */
export function healthBanner<N>(doc: Doc<N>, r: Result<Health>): N | null {
  return r.kind === 'ok' && r.value.read_only ? readOnlyBanner(doc) : null;
}
