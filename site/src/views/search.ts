// /search: a name-prefix search over the registry (searchPackages), one page at a time.
//
// The address is the state: q, sort and cursor come from the query string, and every change is a full page load
// through the form or a link. The form carries no cursor, so a new q or sort always starts from the first page (a
// cursor belongs to one query; the API refuses it for another). A q over 64 characters after trimming is answered here
// and never sent.

import type { ApiError } from '../errors.js';
import { type Doc, h } from '../doc.js';
import { internalHref } from '../links.js';
import { isCanonicalName, packagePath, type SearchSort, searchPath } from '../routes.js';
import type { PackageList } from '../types.js';
import { errorView, timeEl, type View } from './common.js';

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

/** The page's own search form: q and sort, never a cursor. */
export function searchForm<N>(doc: Doc<N>, state: SearchState): N {
  const option = (value: SearchSort, label: string): N =>
    h(doc, 'option', state.sort === value ? { value, selected: '' } : { value }, label);
  return h(
    doc,
    'form',
    { class: 'search-form', role: 'search', action: internalHref('/search'), method: 'get', 'aria-label': 'Search packages' },
    h(
      doc,
      'div',
      { class: 'field grow' },
      h(doc, 'label', { for: 'search-q' }, 'Name starts with'),
      h(doc, 'input', {
        id: 'search-q',
        name: 'q',
        type: 'search',
        value: state.q,
        maxlength: String(Q_MAX),
        autocomplete: 'off',
        spellcheck: 'false',
        enterkeyhint: 'search',
      }),
    ),
    h(
      doc,
      'div',
      { class: 'field' },
      h(doc, 'label', { for: 'search-sort' }, 'Sort by'),
      h(doc, 'select', { id: 'search-sort', name: 'sort' }, option('name', 'Name'), option('updated', 'Recently updated')),
    ),
    h(doc, 'button', { type: 'submit', class: 'button' }, 'Search'),
  );
}

function page<N>(doc: Doc<N>, state: SearchState, ...body: (N | null)[]): View<N> {
  const title = heading(state);
  return {
    title,
    nodes: [h(doc, 'h1', null, title), searchForm(doc, state), ...body.filter((n): n is N => n !== null)],
  };
}

/** A q too long to send. */
export function searchTooLongView<N>(doc: Doc<N>, state: SearchState): View<N> {
  return page(
    doc,
    state,
    h(doc, 'p', { class: 'notice', role: 'alert' }, `Package names are at most ${Q_MAX} characters, so a longer search matches nothing. Shorten it and search again.`),
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
    h(
      doc,
      'div',
      { class: 'result-head' },
      h(doc, 'h2', null, name),
      p.latest !== null
        ? h(doc, 'span', { class: 'tag' }, h(doc, 'span', { class: 'visually-hidden' }, 'latest version '), p.latest)
        : h(doc, 'span', { class: 'tag tag-muted' }, 'no release'),
    ),
    p.description ? h(doc, 'p', null, p.description) : null,
    h(doc, 'p', { class: 'muted small' }, 'Updated ', timeEl(doc, p.updated_at)),
  );
}

/** One page of results, with First page and Next page links. */
export function searchResultsView<N>(doc: Doc<N>, state: SearchState, list: PackageList): View<N> {
  let body: N;
  if (list.packages.length === 0) {
    body = state.cursor
      ? h(doc, 'p', { class: 'notice' }, 'No more packages. ', h(doc, 'a', { href: internalHref(searchPath({ q: state.q, sort: state.sort })) }, 'Back to the first page'))
      : state.q
        ? h(doc, 'p', { class: 'notice' }, 'No package name starts with ', h(doc, 'code', null, state.q), '. Search matches the start of a name, not descriptions.')
        : h(doc, 'p', { class: 'notice' }, 'No packages have been published yet.');
  } else {
    body = h(doc, 'ol', { class: 'results' }, ...list.packages.map((p) => resultItem(doc, p)));
  }
  const next = list.next_cursor !== null && list.next_cursor.length >= 1 && list.next_cursor.length <= CURSOR_MAX ? list.next_cursor : null;
  const nav =
    state.cursor || next
      ? h(
          doc,
          'nav',
          { class: 'pager', 'aria-label': 'Result pages' },
          state.cursor ? h(doc, 'a', { href: internalHref(searchPath({ q: state.q, sort: state.sort })) }, '← First page') : null,
          next ? h(doc, 'a', { href: internalHref(searchPath({ q: state.q, sort: state.sort, cursor: next })), rel: 'next' }, 'Next page →') : null,
        )
      : null;
  return page(doc, state, body, nav);
}

/**
 * A failed search. invalid_request is almost always one of two things: a page link whose cursor the registry no
 * longer accepts, or sort=updated over a prefix that matches more than 1000 packages. Both get a way out.
 */
export function searchErrorView<N>(doc: Doc<N>, state: SearchState, err: ApiError): View<N> {
  if (err.kind !== 'invalid') {
    const v = errorView(doc, err, 'Search failed');
    return { ...v, nodes: [searchForm(doc, state), ...v.nodes] };
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
      h(doc, 'p', null, why),
      err.detail ? h(doc, 'p', { class: 'detail' }, err.detail) : null,
      h(doc, 'p', null, h(doc, 'a', { href: internalHref(reset) }, label)),
    ),
  );
}
