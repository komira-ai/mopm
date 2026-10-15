// The page wrapper every prerendered page shares: the document head, a skip link, the site header (brand, search,
// navigation), <main id="main"> and the footer.
//
// The body is built through StringDoc and h() like any view. The document shell around it (doctype, <html>, <head>,
// <body>, the stylesheet <link> and the module <script>) is not markup a view may produce, so it is written here, once,
// from fixed text and escaped values. Nothing is inline: the shared stylesheet and the page's area stylesheets
// (AREA_STYLESHEETS), one module script (plus modulepreload hints for the modules it imports), no style attribute, no
// event handler.

import { escapeAttr, escapeText, h, type SNode, serialize, StringDoc } from '../src/doc';
import { anchorHref, internalHref, REPO_URL, webHref } from '../src/links';
import { titleOf } from '../src/views/common';

export const doc = new StringDoc();

export interface Assets {
  /** '/assets/<id>/' */
  base: string;
  /** File names under base. */
  entry: string;
  /** Modules the entry imports, for modulepreload. */
  preload: readonly string[];
}

export type PageKind = 'home' | 'docs' | 'app' | 'error';

/** The stylesheet every page loads: tokens, header, footer, buttons, code, cards, notices, tables, prose. */
export const SHARED_STYLESHEET = 'site.css';

/**
 * The area stylesheets each kind of page loads after the shared one, and no others. The app shell is one page for
 * /search, /packages/<name> and /packages/<name>/<version> (main.ts picks the view after load), so it loads both of
 * their areas: a sheet per view would mean a script-inserted <link> and a flash of unstyled view on every load.
 * The 404 page needs only the shared sheet.
 */
export const AREA_STYLESHEETS: Readonly<Record<PageKind, readonly string[]>> = {
  home: ['home.css'],
  docs: ['docs.css'],
  app: ['package.css', 'search.css'],
  error: [],
};

/** The stylesheets a page of this kind loads, in order. */
export function stylesheetsFor(kind: PageKind): string[] {
  return [SHARED_STYLESHEET, ...AREA_STYLESHEETS[kind]];
}

export interface PageSpec {
  /** Without the site suffix; 'mopm' alone for the home page. */
  title: string;
  description: string;
  kind: PageKind;
  main: readonly SNode[];
  noindex?: boolean;
  /** Shown at the top of <main> when scripts do not run (inside <noscript>). */
  noscript?: readonly SNode[];
  /** The navigation entry this page belongs to. */
  current?: 'packages' | 'docs';
  /** This page is that entry's own target (aria-current="page"); otherwise it is below it (aria-current="true"). */
  currentIsTarget?: boolean;
}

function siteSearch(): SNode {
  return h(
    doc,
    'form',
    { class: 'site-search', role: 'search', action: internalHref('/search'), method: 'get', 'aria-label': 'Site search' },
    h(doc, 'label', { for: 'q', class: 'visually-hidden' }, 'Search packages'),
    h(doc, 'input', {
      id: 'q',
      name: 'q',
      type: 'search',
      placeholder: 'Search packages',
      maxlength: '64',
      autocomplete: 'off',
      spellcheck: 'false',
      enterkeyhint: 'search',
    }),
    h(doc, 'button', { type: 'submit', class: 'button' }, 'Search'),
  );
}

/** The site header. The home page leaves out the header search: its own search form is the first thing on it. */
function header(spec: PageSpec): SNode {
  const navLink = (key: 'packages' | 'docs', path: string, label: string): SNode => {
    const attrs = spec.current !== key ? { href: internalHref(path) } : { href: internalHref(path), 'aria-current': spec.currentIsTarget ? 'page' : 'true' };
    return h(doc, 'li', null, h(doc, 'a', attrs, label));
  };
  return h(
    doc,
    'header',
    { class: 'site-header' },
    h(
      doc,
      'div',
      { class: 'wrap bar' },
      h(doc, 'a', { class: 'brand', href: internalHref('/'), 'aria-label': 'mopm home' }, h(doc, 'span', { class: 'logo', 'aria-hidden': 'true' }, 'm'), 'mopm'),
      spec.kind === 'home' ? null : siteSearch(),
      h(
        doc,
        'nav',
        { class: 'site-nav', 'aria-label': 'Site' },
        h(
          doc,
          'ul',
          null,
          navLink('packages', '/search', 'Packages'),
          navLink('docs', '/docs/', 'Docs'),
          h(doc, 'li', null, h(doc, 'a', { href: webHref(REPO_URL) ?? undefined }, 'GitHub')),
        ),
      ),
    ),
  );
}

function footer(): SNode {
  const ext = (path: string, text: string): SNode => h(doc, 'li', null, h(doc, 'a', { href: webHref(`${REPO_URL}${path}`) ?? undefined }, text));
  return h(
    doc,
    'footer',
    { class: 'site-footer' },
    h(
      doc,
      'div',
      { class: 'wrap' },
      h(doc, 'p', null, 'mopm is open source under the Apache-2.0 license. ', h(doc, 'a', { href: webHref(REPO_URL) ?? undefined }, 'Source on GitHub'), '.'),
      h(
        doc,
        'nav',
        { 'aria-label': 'Footer' },
        h(doc, 'ul', null, h(doc, 'li', null, h(doc, 'a', { href: internalHref('/docs/') }, 'Docs')), ext('/blob/main/SECURITY.md', 'Security policy'), ext('/blob/main/CONTRIBUTING.md', 'Contributing')),
      ),
    ),
  );
}

/** The complete HTML of a page. */
export function renderPage(spec: PageSpec, assets: Assets): string {
  const a = (file: string): string => escapeAttr(assets.base + file);
  const head = [
    '<meta charset="utf-8">',
    '<meta name="viewport" content="width=device-width, initial-scale=1">',
    `<title>${escapeText(titleOf(spec.title))}</title>`,
    `<meta name="description" content="${escapeAttr(spec.description)}">`,
    '<meta name="color-scheme" content="light dark">',
    '<meta name="referrer" content="no-referrer">',
    spec.noindex ? '<meta name="robots" content="noindex">' : '',
    ...stylesheetsFor(spec.kind).map((css) => `<link rel="stylesheet" href="${a(css)}">`),
    ...assets.preload.map((m) => `<link rel="modulepreload" href="${a(m)}">`),
    `<script type="module" src="${a(assets.entry)}"></script>`,
  ].filter((l) => l !== '');
  // <noscript> is not a tag views may build: it goes in here, around serialized (escaped) nodes.
  const noscript = spec.noscript ? `<noscript><div class="notice">${serialize(spec.noscript)}</div></noscript>` : '';
  const body = [
    serialize([h(doc, 'a', { class: 'skip', href: anchorHref('main') }, 'Skip to content'), header(spec)]),
    // The home page's bands run the full width, each with its own wrap; every other page sits in one.
    `<main id="main" class="${spec.kind === 'home' ? 'home' : 'wrap'}" tabindex="-1">${noscript}${serialize(spec.main)}</main>`,
    serialize(footer()),
  ].join('\n');
  return [
    '<!doctype html>',
    '<html lang="en">',
    '<head>',
    ...head,
    '</head>',
    `<body data-page="${escapeAttr(spec.kind)}">`,
    body,
    '</body>',
    '</html>',
    '',
  ].join('\n');
}
