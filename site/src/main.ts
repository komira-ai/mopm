// The page script, loaded as a module by every page.
//
// On every page: the read-only banner (from getHealth; any failure is silent), '/' to focus the header search, and
// the conda channel of this host on the home page. On the app shell (body[data-page=app]): the view app.ts picks for
// the address. What to show is decided in app.ts and how a view is put on the page in mount.ts, both tested; this file
// connects them to the real document, location and history. Nothing here builds markup from strings: views are built
// through browserDoc, and the only DOM writes are mount.ts's, the banner's after, and the '/' key's focus.

import { client, type Client, type FetchFn } from './api.js';
import { appView, healthBanner } from './app.js';
import { browserDoc, h } from './doc.js';
import { apiBase } from './host.js';
import { mount, type MountTarget, showChannel } from './mount.js';
import { loadingView, type View } from './views/common.js';

const doc = browserDoc;
const host = location.hostname;
const base = apiBase(host);
const fetchFn: FetchFn = (url, init) => fetch(url, init);
const api: Client | null = base === null ? null : client(fetchFn, base);

/** The page as mount.ts uses it; null on a page without <main id="main">. */
function target(): MountTarget<Node> | null {
  const main = document.getElementById('main');
  if (!main) return null;
  const q = document.getElementById('q');
  return {
    main,
    headerQ: q instanceof HTMLInputElement ? q : null,
    activeElement: () => document.activeElement,
    setTitle: (title) => {
      document.title = title;
    },
    hasRobotsMeta: () => document.querySelector('meta[name="robots"]') !== null,
    addNoindex: () => document.head.appendChild(h(doc, 'meta', { name: 'robots', content: 'noindex' })),
    location,
    replaceState: (url) => history.replaceState(null, '', url),
  };
}

function show(view: View<Node>): void {
  const t = target();
  if (t) mount(t, view, () => void showApp());
}

async function showApp(): Promise<void> {
  show(loadingView(doc));
  show(await appView(doc, location.pathname, location.search, api, host));
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

showHealthBanner();
document.addEventListener('keydown', slashToSearch);
showChannel(document.getElementById('conda-channel'), host);
if (document.body.getAttribute('data-page') === 'app') void showApp();
