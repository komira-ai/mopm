// The page script, loaded as a module by every page.
//
// On every page: the read-only banner (from getHealth; any failure is silent), '/' to focus the search field, and
// a Copy button on every command block (copy.ts). On the home page: the conda channel of this host and the "Recently
// updated" list (views/recent.ts, one searchPackages call). On the app shell (body[data-page=app]): the view app.ts picks
// for the address. What to show is decided in app.ts, how a view is put on the page in mount.ts, and the copy buttons and
// recent list in enhance.ts, all tested; this file connects them to the real document, location and history. Nothing
// here builds markup from strings: views are built through browserDoc, and the only DOM writes are mount.ts's, the
// banner's after, the copy buttons' (text only), the recent list's replaceChildren, and the '/' key's focus.

import { client, type Client, type FetchFn } from './api.js';
import { appView, healthBanner } from './app.js';
import type { Clipboard } from './copy.js';
import { browserDoc, h } from './doc.js';
import { addCopyButtons, type EnhancePort, searchFieldId, showRecent } from './enhance.js';
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

// The Clipboard API exists only in a secure context; without it no button is added and the text stays selectable.
const clipboard: Clipboard | null = window.isSecureContext && navigator.clipboard ? navigator.clipboard : null;
const port: EnhancePort<Node> = {
  ...doc,
  onClick: (node, fn) => node.addEventListener('click', fn),
  setText: (node, text) => {
    node.textContent = text;
  },
  textOf: (node) => node.textContent ?? '',
  copyBoxes: (root) => Array.from((root as ParentNode).querySelectorAll('.copy-box')),
  firstPre: (box) => (box as ParentNode).querySelector('pre'),
  hasCopyButton: (box) => (box as ParentNode).querySelector('button.copy') !== null,
  getAttr: (node, name) => (node as Element).getAttribute(name),
  textById: (id) => document.getElementById(id)?.textContent ?? null,
  replaceChildren: (node, nodes) => (node as ParentNode).replaceChildren(...nodes),
};
const later = (fn: () => void, ms: number): unknown => setTimeout(fn, ms);

function show(view: View<Node>): void {
  const t = target();
  if (!t) return;
  mount(t, view, () => void showApp());
  const main = document.getElementById('main');
  if (main) addCopyButtons(port, main, clipboard, later);
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

/**
 * '/' focuses a search field, unless the reader is typing somewhere: which one is searchFieldId's choice (enhance.ts),
 * the search page's big box when it is on the page, else the header's.
 */
function slashToSearch(e: KeyboardEvent): void {
  if (e.key !== '/' || e.ctrlKey || e.metaKey || e.altKey || e.defaultPrevented) return;
  const t = e.target;
  if (t instanceof HTMLElement && (t.isContentEditable || /^(?:INPUT|TEXTAREA|SELECT)$/.test(t.tagName))) return;
  const id = searchFieldId((x) => document.getElementById(x) instanceof HTMLInputElement);
  const q = id === null ? null : document.getElementById(id);
  if (!(q instanceof HTMLInputElement)) return;
  e.preventDefault();
  q.focus();
  q.select();
}

showHealthBanner();
document.addEventListener('keydown', slashToSearch);
showChannel(document.getElementById('conda-channel'), host);
addCopyButtons(port, document, clipboard, later);
if (document.body.getAttribute('data-page') === 'home') void showRecent(port, document.getElementById('recent-list'), api);
if (document.body.getAttribute('data-page') === 'app') void showApp();
