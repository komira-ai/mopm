// Pieces every app view shares: the view value main.ts mounts, the read-only banner, and the loading, error,
// not-found and unknown-host views.
//
// A view is built through a Doc (so tests render it with StringDoc and need no DOM) and is plain data: main.ts sets
// the title, mounts the nodes into <main>, adds the robots meta for `noindex`, and rewrites the address to
// `canonicalPath` without a reload. Interactive parts carry a class main.ts looks for (button.retry); no view attaches
// a handler itself.

import type { ApiError } from '../errors.js';
import { type Child, type Doc, h } from '../doc.js';
import { formatTime } from '../format.js';
import { internalHref, webHref } from '../links.js';
import { packagePath, searchPath } from '../routes.js';

export interface View<N> {
  /** The document title, without the site suffix (titleOf adds it). */
  title: string;
  nodes: N[];
  /** A page that is not a real package or version: search engines should not index it. */
  noindex?: boolean;
  /** The address the page should show (the version the registry returned, a normalised search). */
  canonicalPath?: string;
  /** A search page's q, for the header search field. */
  searchQ?: string;
}

export const SITE_NAME = 'mopm';

export function titleOf(title: string): string {
  return title === SITE_NAME ? SITE_NAME : `${title} · ${SITE_NAME}`;
}

/** A <time> element showing the UTC date and time. */
export function timeEl<N>(doc: Doc<N>, iso: string): N {
  return h(doc, 'time', { datetime: iso }, formatTime(iso));
}

/** A description list of label and value rows; a row whose value is null is left out. */
export function details<N>(doc: Doc<N>, rows: readonly [string, Child<N> | Child<N>[]][]): N | null {
  const dl = h(doc, 'dl', { class: 'meta' });
  let any = false;
  for (const [label, value] of rows) {
    const vals = Array.isArray(value) ? value : [value];
    if (vals.every((v) => v === null || v === undefined || v === false || v === '')) continue;
    any = true;
    doc.append(dl, h(doc, 'dt', null, label));
    doc.append(dl, h(doc, 'dd', null, ...vals));
  }
  return any ? dl : null;
}

/** A code block a reader copies from, with a short label above it that names it (a named <pre> needs a role). */
export function snippetBlock<N>(doc: Doc<N>, label: string, code: string, id: string): N {
  return h(
    doc,
    'div',
    { class: 'snippet' },
    h(doc, 'p', { class: 'snippet-label', id }, label),
    h(doc, 'pre', { tabindex: '0', role: 'region', 'aria-labelledby': id }, h(doc, 'code', null, code)),
  );
}

/** The registry refuses new uploads; reading and installing still work. */
export function readOnlyBanner<N>(doc: Doc<N>): N {
  return h(
    doc,
    'div',
    { class: 'banner', role: 'status' },
    h(doc, 'p', null, h(doc, 'strong', null, 'Read-only mode.'), ' The registry is not accepting new uploads right now. Browsing and installs still work.'),
  );
}

export function loadingView<N>(doc: Doc<N>, what = 'Loading'): View<N> {
  return {
    title: what,
    nodes: [h(doc, 'div', { class: 'loading', 'aria-busy': 'true' }, h(doc, 'h1', null, `${what}…`))],
  };
}

/** A failed call: what happened, the server's own words if any, the request id, and a Retry button. */
export function errorView<N>(doc: Doc<N>, err: ApiError, heading = 'Something went wrong'): View<N> {
  const box = h(
    doc,
    'section',
    { class: 'notice notice-error', role: 'alert' },
    h(doc, 'h1', null, heading),
    h(doc, 'p', null, err.message),
    err.detail ? h(doc, 'p', { class: 'detail' }, err.detail) : null,
    err.hint ? h(doc, 'p', { class: 'detail' }, err.hint) : null,
    err.requestId ? h(doc, 'p', { class: 'muted' }, 'Request id: ', h(doc, 'code', null, err.requestId)) : null,
    h(doc, 'p', null, h(doc, 'button', { type: 'button', class: 'button retry' }, 'Retry')),
  );
  return { title: heading, nodes: [box] };
}

/** A well-formed address for a package or version the registry does not have. */
export function notFoundView<N>(doc: Doc<N>, name: string, version?: string): View<N> {
  const heading = version === undefined ? 'Package not found' : 'Version not found';
  const sentence =
    version === undefined
      ? [`There is no package `, h(doc, 'code', null, name), ' in the registry.']
      : [h(doc, 'code', null, name), ' has no version ', h(doc, 'code', null, version), '.'];
  const box = h(
    doc,
    'section',
    { class: 'notice' },
    h(doc, 'h1', null, heading),
    h(doc, 'p', null, ...sentence),
    h(
      doc,
      'p',
      null,
      version === undefined
        ? h(doc, 'a', { href: internalHref(searchPath({ q: name })) }, `Search for names starting with ${name}`)
        : h(doc, 'a', { href: internalHref(packagePath(name)) }, `All versions of ${name}`),
    ),
  );
  return { title: heading, nodes: [box], noindex: true };
}

/** A copy of the site served from a host outside the table in host.ts: it never calls an API. */
export function unknownHostView<N>(doc: Doc<N>, hostname: string): View<N> {
  const box = h(
    doc,
    'section',
    { class: 'notice notice-error', role: 'alert' },
    h(doc, 'h1', null, 'Registry unavailable here'),
    h(doc, 'p', null, 'This page is served from ', h(doc, 'code', null, hostname || '(no host)'), ', which is not a mopm.dev site, so it does not call the registry API.'),
    h(doc, 'p', null, 'Browse the registry at ', h(doc, 'a', { href: webHref('https://mopm.dev/') ?? undefined }, 'mopm.dev'), '.'),
  );
  return { title: 'Registry unavailable', nodes: [box], noindex: true };
}

/** An address that is not an app route (the shell opened directly, say). */
export function pageNotFoundView<N>(doc: Doc<N>): View<N> {
  const box = h(
    doc,
    'section',
    { class: 'notice' },
    h(doc, 'h1', null, 'Page not found'),
    h(doc, 'p', null, 'There is nothing at this address. ', h(doc, 'a', { href: internalHref(searchPath()) }, 'Browse packages'), '.'),
  );
  return { title: 'Page not found', nodes: [box], noindex: true };
}
