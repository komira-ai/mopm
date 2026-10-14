// The page wrapper every prerendered page shares: the document head, a skip link, the site header (brand, search,
// navigation), <main id="main"> and the footer.
//
// The body is built through StringDoc and h() like any view. The document shell around it (doctype, <html>, <head>,
// <body>, the stylesheet <link> and the module <script>) is not markup a view may produce, so it is written here, once,
// from fixed text and escaped values. Nothing is inline: one stylesheet, one module script (plus modulepreload hints
// for the modules it imports), no style attribute, no event handler.

import { escapeAttr, escapeText, h, type SNode, serialize, StringDoc } from '../src/doc';
import { anchorHref, internalHref, REPO_URL, webHref } from '../src/links';
import { titleOf } from '../src/views/common';

export const doc = new StringDoc();

export interface Assets {
  /** '/assets/<id>/' */
  base: string;
  /** File names under base. */
  stylesheet: string;
  entry: string;
  /** Modules the entry imports, for modulepreload. */
  preload: readonly string[];
}

export type PageKind = 'home' | 'docs' | 'app' | 'error';

export interface PageSpec {
  /** Without the site suffix; 'mopm' alone for the home page. */
  title: string;
  description: string;
  kind: PageKind;
  main: readonly SNode[];
  noindex?: boolean;
  /** Shown at the top of <main> when scripts do not run (inside <noscript>). */
  noscript?: readonly SNode[];
  /** The navigation entry to mark as the current page. */
  current?: 'packages' | 'docs';
}

function header(current: PageSpec['current']): SNode {
  const navLink = (key: 'packages' | 'docs', path: string, label: string): SNode =>
    h(doc, 'li', null, h(doc, 'a', current === key ? { href: internalHref(path), 'aria-current': 'page' } : { href: internalHref(path) }, label));
  return h(
    doc,
    'header',
    { class: 'site-header' },
    h(
      doc,
      'div',
      { class: 'wrap bar' },
      h(doc, 'a', { class: 'brand', href: internalHref('/'), 'aria-label': 'mopm home' }, 'mopm'),
      h(
        doc,
        'form',
        { class: 'site-search', role: 'search', action: internalHref('/search'), method: 'get' },
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
      ),
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
  return h(
    doc,
    'footer',
    { class: 'site-footer' },
    h(
      doc,
      'div',
      { class: 'wrap' },
      h(doc, 'p', null, 'mopm is open source under the Apache-2.0 license. ', h(doc, 'a', { href: webHref(REPO_URL) ?? undefined }, 'Source on GitHub'), '.'),
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
    `<link rel="stylesheet" href="${a(assets.stylesheet)}">`,
    ...assets.preload.map((m) => `<link rel="modulepreload" href="${a(m)}">`),
    `<script type="module" src="${a(assets.entry)}"></script>`,
  ].filter((l) => l !== '');
  // <noscript> is not a tag views may build: it goes in here, around serialized (escaped) nodes.
  const noscript = spec.noscript ? `<noscript><div class="notice">${serialize(spec.noscript)}</div></noscript>` : '';
  const body = [
    serialize([h(doc, 'a', { class: 'skip', href: anchorHref('main') }, 'Skip to content'), header(spec.current)]),
    `<main id="main" class="wrap" tabindex="-1">${noscript}${serialize(spec.main)}</main>`,
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
