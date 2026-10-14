// The page script, loaded as a module by every page.
//
// On every page: the read-only banner (from getHealth; any failure is silent), '/' to focus the header search, and
// the conda channel of this host on the home page. On the app shell (body[data-page=app]): the view app.ts picks for
// the address. This file only does the DOM work; what to show is decided in app.ts, which is tested. Nothing here
// builds markup from strings: views are built through browserDoc, and the only other DOM writes are replaceChildren,
// appendChild, after, textContent, an input's value, focus, addEventListener and history.replaceState.

import { client, type Client, type FetchFn } from './api.js';
import { appView, healthBanner } from './app.js';
import { browserDoc, h } from './doc.js';
import { apiBase, condaBase } from './host.js';
import { loadingView, titleOf, type View } from './views/common.js';

const doc = browserDoc;
const host = location.hostname;
const base = apiBase(host);
const fetchFn: FetchFn = (url, init) => fetch(url, init);
const api: Client | null = base === null ? null : client(fetchFn, base);

function mount(view: View<Node>): void {
  const main = document.getElementById('main');
  if (!main) return;
  // Focus inside <main> (the Retry button, say) would fall back to <body> when its element is replaced: keep it on
  // <main> (tabindex=-1), so a keyboard reader stays where the new content is.
  const hadFocus = main.contains(document.activeElement);
  document.title = titleOf(view.title);
  main.replaceChildren(...view.nodes);
  if (hadFocus) main.focus({ preventScroll: true });
  if (view.noindex && !document.querySelector('meta[name="robots"]')) {
    document.head.appendChild(h(doc, 'meta', { name: 'robots', content: 'noindex' }));
  }
  if (view.canonicalPath && view.canonicalPath !== location.pathname + location.search) {
    history.replaceState(null, '', view.canonicalPath + location.hash);
  }
  const headerQ = document.getElementById('q');
  if (view.searchQ !== undefined && headerQ instanceof HTMLInputElement) headerQ.value = view.searchQ;
  const retry = main.querySelector('button.retry');
  if (retry) retry.addEventListener('click', () => void show(), { once: true });
}

async function show(): Promise<void> {
  mount(loadingView(doc));
  mount(await appView(doc, location.pathname, location.search, api, host));
}

function showHealthBanner(): void {
  if (api === null) return;
  api
    .getHealth()
    .then((r) => {
      const header = document.querySelector('body > header');
      const banner = healthBanner(doc, r);
      if (banner && header) header.after(banner);
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

showHealthBanner();
document.addEventListener('keydown', slashToSearch);
channelOfThisHost();
if (document.body.getAttribute('data-page') === 'app') void show();
