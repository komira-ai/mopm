// /search: a name-prefix search over the registry (searchPackages), one page at a time.
//
// The address is the state: q, sort and cursor come from the query string, and every change is a full page load
// through the form or a link. The form carries no cursor, so a new q or sort always starts from the first page (a
// cursor belongs to one query; the API refuses it for another). A q over 64 characters after trimming is answered here
// and never sent.
//
// The page says what the API does: the search matches the start of a package name (searchPackages has no full-text
// mode), so there are no ranking reasons and no ranking explainer. Each result is a card: glyph, name, latest version,
// description and the date of its last update; paging is a First page and a Next page button.

import type { ApiError } from '../errors.js';
import { type Doc, h } from '../doc.js';
import { internalHref } from '../links.js';
import { isCanonicalName, packagePath, type SearchSort, searchPath } from '../routes.js';
import type { PackageList } from '../types.js';
import { formatDate } from '../format.js';
import { errorView, type View } from './common.js';
import { glyphClass, initials } from './recent.js';

export const Q_MAX = 64;
export const CURSOR_MAX = 512;

export interface SearchState {
  /** Trimmed. */
  q: string;
  sort: SearchSort;
  cursor?: string;
}

export interface ParsedSearch {
  state: SearchState;
  /** q is over Q_MAX characters: show a message and make no call. */
  tooLong: boolean;
  /** The address for this state (a stray or invalid parameter dropped). */
  canonicalPath: string;
}

/** Reads the search state from a query string ('?q=http&sort=updated'). */
export function readSearch(query: string): ParsedSearch {
  const p = new URLSearchParams(query);
  const q = (p.get('q') ?? '').trim();
  const sort: SearchSort = p.get('sort') === 'updated' ? 'updated' : 'name';
  const rawCursor = p.get('cursor');
  const cursor = rawCursor !== null && rawCursor.length >= 1 && rawCursor.length <= CURSOR_MAX ? rawCursor : undefined;
  const state: SearchState = cursor === undefined ? { q, sort } : { q, sort, cursor };
  return { state, tooLong: q.length > Q_MAX, canonicalPath: searchPath(state) };
}

function heading(state: SearchState): string {
  return state.q ? `Packages starting with “${state.q}”` : 'Packages';
}

/** What the API does today, said where the reader types: a name prefix, nothing else. */
export const PREFIX_NOTE = 'Search matches the start of a package name, not descriptions or readmes.';

/** The page's own search form: q and sort, never a cursor. A big search box, then the sort and the prefix note. */
export function searchForm<N>(doc: Doc<N>, state: SearchState): N {
  const option = (value: SearchSort, label: string): N =>
    h(doc, 'option', state.sort === value ? { value, selected: '' } : { value }, label);
  return h(
    doc,
    'form',
    { class: 'search-form', role: 'search', action: internalHref('/search'), method: 'get', 'aria-label': 'Search packages' },
    h(doc, 'label', { for: 'search-q', class: 'visually-hidden' }, 'Name starts with'),
    h(
      doc,
      'div',
      { class: 'big-search' },
      h(doc, 'span', { class: 'search-icon', 'aria-hidden': 'true' }),
      h(doc, 'input', {
        id: 'search-q',
        name: 'q',
        type: 'search',
        value: state.q,
        placeholder: 'Name starts with…',
        maxlength: String(Q_MAX),
        autocomplete: 'off',
        spellcheck: 'false',
        enterkeyhint: 'search',
        'aria-describedby': 'search-note',
      }),
      h(doc, 'kbd', { 'aria-hidden': 'true' }, '/'),
      h(doc, 'button', { type: 'submit', class: 'button button-primary' }, 'Search'),
    ),
    h(
      doc,
      'div',
      { class: 'search-opts' },
      h(doc, 'p', { class: 'search-note', id: 'search-note' }, PREFIX_NOTE),
      h(
        doc,
        'div',
        { class: 'sort-field' },
        h(doc, 'label', { for: 'search-sort' }, 'Sort by'),
        h(doc, 'select', { id: 'search-sort', name: 'sort' }, option('name', 'Name'), option('updated', 'Recently updated')),
      ),
    ),
  );
}

/** The band at the top of the page: the heading (when the page has no other h1) and the form. */
function band<N>(doc: Doc<N>, state: SearchState, withHeading: boolean): N {
  return h(
    doc,
    'header',
    { class: 'page-band search-band' },
    withHeading ? h(doc, 'h1', { class: 'search-title' }, heading(state)) : null,
    searchForm(doc, state),
  );
}

/** Beside the results: what the search does, in the API's terms (a name prefix), and nothing about ranking. */
function searchHelp<N>(doc: Doc<N>): N {
  return h(
    doc,
    'aside',
    { class: 'search-help', 'aria-labelledby': 'search-help-title' },
    h(doc, 'h2', { id: 'search-help-title' }, 'How search works'),
    h(
      doc,
      'ul',
      null,
      h(doc, 'li', null, 'It finds every package whose name starts with what you type.'),
      h(doc, 'li', null, 'Package names are lowercase letters, digits and underscores.'),
      h(doc, 'li', null, 'Results are sorted by name, or by last update for up to 1000 matches.'),
    ),
    h(doc, 'p', null, h(doc, 'a', { href: internalHref(searchPath()) }, 'Browse all packages')),
  );
}

function page<N>(doc: Doc<N>, state: SearchState, ...body: (N | null)[]): View<N> {
  return {
    title: heading(state),
    nodes: [band(doc, state, true), h(doc, 'div', { class: 'search-body' }, h(doc, 'div', { class: 'search-results' }, ...body), searchHelp(doc))],
  };
}

/** A q too long to send. */
export function searchTooLongView<N>(doc: Doc<N>, state: SearchState): View<N> {
  return page(
    doc,
    state,
    h(doc, 'p', { class: 'notice notice-warn', role: 'alert' }, `Package names are at most ${Q_MAX} characters, so a longer search matches nothing. Shorten it and search again.`),
  );
}

function resultItem<N>(doc: Doc<N>, p: PackageList['packages'][number]): N {
  const name = isCanonicalName(p.name)
    ? h(doc, 'a', { href: internalHref(packagePath(p.name)), class: 'result-name' }, p.name)
    : h(doc, 'span', { class: 'result-name' }, p.name);
  return h(
    doc,
    'li',
    { class: 'result' },
    h(doc, 'span', { class: glyphClass(p.name), 'aria-hidden': 'true' }, initials(p.name)),
    h(
      doc,
      'div',
      { class: 'result-body' },
      h(
        doc,
        'div',
        { class: 'result-head' },
        h(doc, 'h2', null, name),
        p.latest !== null
          ? h(doc, 'span', { class: 'ver' }, h(doc, 'span', { class: 'visually-hidden' }, 'latest version '), p.latest)
          : h(doc, 'span', { class: 'tag tag-muted' }, 'no release'),
      ),
      p.description ? h(doc, 'p', { class: 'result-desc' }, p.description) : null,
      h(doc, 'p', { class: 'result-meta' }, 'Updated ', h(doc, 'time', { datetime: p.updated_at }, formatDate(p.updated_at))),
    ),
  );
}

/** An empty answer, said as what it means, with a way on. */
function emptyState<N>(doc: Doc<N>, lead: (N | string)[], more: string | null, link: N): N {
  return h(
    doc,
    'div',
    { class: 'empty-state' },
    h(doc, 'p', { class: 'empty-lead' }, ...lead),
    more ? h(doc, 'p', { class: 'muted' }, more) : null,
    h(doc, 'p', null, link),
  );
}

/** One page of results, with First page and Next page links. */
export function searchResultsView<N>(doc: Doc<N>, state: SearchState, list: PackageList): View<N> {
  const first = searchPath({ q: state.q, sort: state.sort });
  const allLink = (label: string): N => h(doc, 'a', { class: 'button', href: internalHref(searchPath()) }, label);
  let body: N;
  if (list.packages.length === 0) {
    body = state.cursor
      ? emptyState(doc, ['No more packages.'], null, h(doc, 'a', { class: 'button', href: internalHref(first) }, 'Back to the first page'))
      : state.q
        ? emptyState(doc, ['No package name starts with ', h(doc, 'code', null, state.q), '.'], 'Search matches the start of a name, not descriptions.', allLink('Browse all packages'))
        : emptyState(doc, ['No packages have been published yet.'], null, h(doc, 'a', { class: 'button', href: internalHref('/docs/') }, 'Read the docs'));
  } else {
    body = h(doc, 'ol', { class: 'results' }, ...list.packages.map((p) => resultItem(doc, p)));
  }
  const next = list.next_cursor !== null && list.next_cursor.length >= 1 && list.next_cursor.length <= CURSOR_MAX ? list.next_cursor : null;
  const n = list.packages.length;
  const count =
    n === 0
      ? null
      : h(
          doc,
          'p',
          { class: 'result-count' },
          h(doc, 'strong', null, String(n)),
          n === 1 ? ' package' : ' packages',
          state.cursor ? ' on this page' : '',
          state.sort === 'updated' ? ', most recently updated first' : ', sorted by name',
          next ? '; more on the next page.' : '.',
        );
  const nav =
    state.cursor || next
      ? h(
          doc,
          'nav',
          { class: 'pager', 'aria-label': 'Result pages' },
          state.cursor ? h(doc, 'a', { class: 'button', href: internalHref(first) }, '← First page') : null,
          next ? h(doc, 'a', { class: 'button button-primary', href: internalHref(searchPath({ q: state.q, sort: state.sort, cursor: next })), rel: 'next' }, 'Next page →') : null,
        )
      : null;
  return page(doc, state, count, body, nav);
}

/**
 * A failed search. invalid_request is almost always one of two things: a page link whose cursor the registry no
 * longer accepts, or sort=updated over a prefix that matches more than 1000 packages. Both get a way out.
 */
export function searchErrorView<N>(doc: Doc<N>, state: SearchState, err: ApiError): View<N> {
  if (err.kind !== 'invalid') {
    const v = errorView(doc, err, 'Search failed');
    return { ...v, nodes: [band(doc, state, false), ...v.nodes] };
  }
  const [why, reset, label] = state.cursor
    ? ['This page link is no longer valid.', searchPath({ q: state.q, sort: state.sort }), 'Start from the first page']
    : state.sort === 'updated'
      ? [
          'Sorting by last update works for up to 1000 matching packages. Type a longer prefix, or sort by name.',
          searchPath({ q: state.q }),
          'Sort by name instead',
        ]
      : ['The registry did not accept this search.', searchPath(), 'Show all packages'];
  return page(
    doc,
    state,
    h(
      doc,
      'div',
      { class: 'notice notice-error', role: 'alert' },
      h(doc, 'p', null, h(doc, 'strong', null, why)),
      err.detail ? h(doc, 'p', { class: 'detail' }, err.detail) : null,
      h(doc, 'p', null, h(doc, 'a', { class: 'button', href: internalHref(reset) }, label)),
    ),
  );
}
