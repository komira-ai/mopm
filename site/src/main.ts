// The page script, loaded as a module by every page.
//
// On every page: the header's account box (account.ts: the sign-in link for this address, or for the home page on the
// 404 page, then who is signed in from the session route, and Sign out; asked again when the page comes back from the
// back-forward cache), the banner of a refused sign-in on the address the sign-in sent the browser to, the
// read-only banner (from getHealth; any failure is silent), '/' to focus the search field, and a Copy button on every
// command block (copy.ts). On the home page: the "Recently updated" list (views/recent.ts, one searchPackages call).
// On the app shell (body[data-page=app]): the view app.ts picks for the address. What to show is decided in app.ts, how a view is put on the page in mount.ts, and the copy buttons and
// recent list in enhance.ts, all tested; this file connects them to the real document, location and history. Nothing
// here builds markup from strings: views are built through browserDoc, and the only DOM writes are mount.ts's, the
// banners' after, the copy buttons' (text only), the recent list's and the account box's replaceChildren, and the '/'
// key's and Sign out's focus.

import { ACCOUNT_ID, type AccountPort, pagePath, showAccount, signInError, signInErrorBanner } from './account.js';
import { client, type Client, type FetchFn } from './api.js';
import { appView, healthBanner } from './app.js';
import type { Clipboard } from './copy.js';
import { browserDoc, h } from './doc.js';
import { addCopyButtons, type EnhancePort, searchFieldId, showRecent } from './enhance.js';
import { apiBase } from './host.js';
import { mount, type MountTarget } from './mount.js';
import { webSession } from './session.js';
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

/** Puts `banner` right under the site header. */
function underHeader(banner: Node): void {
  document.querySelector('body > header')?.after(banner);
}

function showSignInError(): void {
  const code = signInError(location.pathname, location.search);
  if (code !== null) underHeader(signInErrorBanner(doc, code));
}

// The account box asks the site's own routes, same-origin, only on a host that has the API.
const accountPort: AccountPort<Node> = {
  ...doc,
  onClick: (node, fn) => node.addEventListener('click', fn),
  replaceChildren: (node, nodes) => (node as ParentNode).replaceChildren(...nodes),
  focus: (node) => (node as HTMLElement).focus(),
  setText: (node, text) => {
    node.textContent = text;
  },
  linkHref: (box) => (box as ParentNode).querySelector('a.sign-in')?.getAttribute('href') ?? null,
};

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

const accountSession = base === null ? null : webSession((url, init) => fetch(url, init));
function showAccountBox(): void {
  void showAccount(accountPort, document.getElementById(ACCOUNT_ID), accountSession, pagePath(location.pathname, document.body.getAttribute('data-page')));
}
showAccountBox();
// A page restored from the back-forward cache shows the box as it was left: ask again, the session may have ended.
window.addEventListener('pageshow', (e) => {
  if (e.persisted) showAccountBox();
});
showSignInError();
showHealthBanner();
document.addEventListener('keydown', slashToSearch);
addCopyButtons(port, document, clipboard, later);
if (document.body.getAttribute('data-page') === 'home') void showRecent(port, document.getElementById('recent-list'), api);
if (document.body.getAttribute('data-page') === 'app') void showApp();
