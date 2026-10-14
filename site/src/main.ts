// The page script, loaded as a module by every page.
//
// On every page: the read-only banner (from getHealth; any failure is silent), '/' to focus the header search, and
// the conda channel of this host on the home page. On the app shell (body[data-page=app]): one view per route, from
// one API call. Nothing here builds markup from strings: views are built through browserDoc, and the only DOM calls
// are replaceChildren, setAttribute, textContent and history.replaceState.

import { client, type Client, type FetchFn } from './api.js';
import { browserDoc, h } from './doc.js';
import { apiBase, condaBase } from './host.js';
import { parseRoute, type Route } from './routes.js';
import { errorView, loadingView, notFoundView, pageNotFoundView, readOnlyBanner, titleOf, unknownHostView, type View } from './views/common.js';
import { packageView } from './views/package.js';
import { readSearch, searchErrorView, searchResultsView, searchTooLongView } from './views/search.js';
import { versionView } from './views/version.js';

const doc = browserDoc;
const host = location.hostname;
const base = apiBase(host);
const fetchFn: FetchFn = (url, init) => fetch(url, init);
const api: Client | null = base === null ? null : client(fetchFn, base);

function mount(view: View<Node>): void {
  const main = document.getElementById('main');
  if (!main) return;
  document.title = titleOf(view.title);
  main.replaceChildren(...view.nodes);
  if (view.noindex && !document.querySelector('meta[name="robots"]')) {
    document.head.appendChild(h(doc, 'meta', { name: 'robots', content: 'noindex' }));
  }
  if (view.canonicalPath && view.canonicalPath !== location.pathname + location.search) {
    history.replaceState(null, '', view.canonicalPath + location.hash);
  }
  const retry = main.querySelector('button.retry');
  if (retry) retry.addEventListener('click', () => void show(), { once: true });
}

async function routeView(route: Route, api: Client): Promise<View<Node>> {
  const ctx = { host };
  switch (route.kind) {
    case 'search': {
      const { state, tooLong, canonicalPath } = readSearch(location.search);
      const headerQ = document.getElementById('q');
      if (headerQ instanceof HTMLInputElement) headerQ.value = state.q;
      if (tooLong) return { ...searchTooLongView(doc, state), canonicalPath };
      const r = await api.searchPackages({ q: state.q || undefined, sort: state.sort, cursor: state.cursor });
      const view = r.kind === 'ok' ? searchResultsView(doc, state, r.value) : searchErrorView(doc, state, r);
      return { ...view, canonicalPath };
    }
    case 'package': {
      const r = await api.getPackage(route.name);
      if (r.kind === 'ok') return packageView(doc, route.name, r.value, ctx);
      return r.kind === 'notFound' ? notFoundView(doc, route.name) : errorView(doc, r);
    }
    case 'version': {
      const r = await api.getVersion(route.name, route.version);
      if (r.kind === 'ok') return versionView(doc, route.name, r.value, ctx);
      if (r.kind !== 'notFound') return errorView(doc, r);
      return r.code === 'package_not_found' ? notFoundView(doc, route.name) : notFoundView(doc, route.name, route.version);
    }
  }
}

async function show(): Promise<void> {
  const route = parseRoute(location.pathname);
  if (route === null) {
    mount(pageNotFoundView(doc));
    return;
  }
  if (api === null) {
    mount(unknownHostView(doc, host));
    return;
  }
  mount(loadingView(doc));
  mount(await routeView(route, api));
}

function healthBanner(): void {
  if (api === null) return;
  api
    .getHealth()
    .then((r) => {
      const header = document.querySelector('body > header');
      if (r.kind === 'ok' && r.value.read_only && header) header.after(readOnlyBanner(doc));
    })
    .catch(() => undefined);
}

/** '/' focuses the header search, unless the reader is typing somewhere. */
function slashToSearch(e: KeyboardEvent): void {
  if (e.key !== '/' || e.ctrlKey || e.metaKey || e.altKey || e.defaultPrevented) return;
  const t = e.target;
  if (t instanceof HTMLElement && (t.isContentEditable || /^(?:INPUT|TEXTAREA|SELECT)$/.test(t.tagName))) return;
  const q = document.getElementById('q');
  if (!(q instanceof HTMLInputElement)) return;
  e.preventDefault();
  q.focus();
  q.select();
}

function channelOfThisHost(): void {
  const el = document.getElementById('conda-channel');
  const channel = condaBase(host);
  if (el && channel !== null) el.textContent = channel;
}

healthBanner();
document.addEventListener('keydown', slashToSearch);
channelOfThisHost();
if (document.body.getAttribute('data-page') === 'app') void show();
