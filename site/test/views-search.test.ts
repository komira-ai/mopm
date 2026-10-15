// T14 (search and shared views): reading the search state from the address, the results page and its paging links,
// the empty and too-long states, the two invalid_request ways out, and the banner, error and not-found views.
import { fromResponse, networkError } from '../src/errors';
import {
  errorView, notFoundView, pageNotFoundView, readOnlyBanner, titleOf, unknownHostView,
} from '../src/views/common';
import { readSearch, searchErrorView, searchResultsView, searchTooLongView } from '../src/views/search';
import { serialize } from '../src/doc';
import { decodePackageList } from '../src/decode';
import { hrefs, html, sdoc, text } from './view-helpers';
import { validReadCases } from './fixtures';

const listFixture = (name: string) => decodePackageList(validReadCases().find((c) => c.name === name)?.response.body);

describe('readSearch', () => {
  test('trims q, keeps sort=updated and a cursor', () => {
    expect(readSearch('?q=%20http%20&sort=updated&cursor=abc')).toEqual({
      state: { q: 'http', sort: 'updated', cursor: 'abc' },
      tooLong: false,
      canonicalPath: '/search?q=http&sort=updated&cursor=abc',
    });
  });

  test('an unknown sort is name, and drops out of the address', () => {
    const r = readSearch('?q=x&sort=stars');
    expect(r.state.sort).toBe('name');
    expect(r.canonicalPath).toBe('/search?q=x');
  });

  test('a cursor over 512 characters, or empty, is dropped', () => {
    expect(readSearch(`?cursor=${'a'.repeat(513)}`).state.cursor).toBeUndefined();
    expect(readSearch('?cursor=').state.cursor).toBeUndefined();
    expect(readSearch(`?cursor=${'a'.repeat(512)}`).state.cursor).toHaveLength(512);
  });

  test('q over 64 characters after trimming is too long; 64 is not', () => {
    expect(readSearch(`?q=${'a'.repeat(65)}`).tooLong).toBe(true);
    expect(readSearch(`?q=%20${'a'.repeat(64)}%20`).tooLong).toBe(false);
  });
});

describe('search results', () => {
  test('a first page: a linked result, its latest version, a Next link carrying the cursor and the query', () => {
    const state = { q: 'http', sort: 'name' as const };
    const out = html(searchResultsView(sdoc, state, listFixture('search by prefix')));
    expect(out).toContain('<a href="/packages/http_client" class="result-name">http_client</a>');
    expect(text(out)).toContain('latest version 0.4.0');
    expect(hrefs(out)).toContain('/search?q=http&cursor=c2Vjb25kLXBhZ2U');
    expect(text(out)).not.toContain('First page');
  });

  test('a later page: a First page link without the cursor, no Next on the last page, a claimed package shows no release', () => {
    const state = { q: '', sort: 'updated' as const, cursor: 'c2Vjb25kLXBhZ2U' };
    const out = html(searchResultsView(sdoc, state, listFixture('search, last page, claimed package with no version')));
    expect(hrefs(out)).toContain('/search?sort=updated');
    expect(text(out)).not.toContain('Next page');
    expect(text(out)).toContain('no release');
  });

  test.each([
    ['empty', ''],
    ['over 512 characters', 'a'.repeat(513)],
  ])('a next_cursor from the server that is %s gives no Next link', (_what, cursor) => {
    const out = html(searchResultsView(sdoc, { q: 'http', sort: 'name' }, { ...listFixture('search by prefix'), next_cursor: cursor }));
    expect(text(out)).not.toContain('Next page');
    expect(hrefs(out).filter((h) => h.includes('cursor='))).toEqual([]);
  });

  test('a next_cursor of 512 characters gives a Next link carrying it', () => {
    const cursor = 'a'.repeat(512);
    const out = html(searchResultsView(sdoc, { q: 'http', sort: 'name' }, { ...listFixture('search by prefix'), next_cursor: cursor }));
    expect(hrefs(out)).toContain(`/search?q=http&cursor=${cursor}`);
  });

  test('the form carries q and sort but never the cursor (a new query starts at page one)', () => {
    const out = html(searchResultsView(sdoc, { q: 'http', sort: 'updated', cursor: 'abc' }, { packages: [], next_cursor: null }));
    expect(out).toContain('name="q" type="search" value="http"');
    expect(out).toContain('<option value="updated" selected="">');
    expect(out).not.toMatch(/name="cursor"/);
  });

  test('empty with a q and without one say different things', () => {
    const withQ = text(html(searchResultsView(sdoc, { q: 'zz', sort: 'name' }, { packages: [], next_cursor: null })));
    const without = text(html(searchResultsView(sdoc, { q: '', sort: 'name' }, { packages: [], next_cursor: null })));
    expect(withQ).toContain('No package name starts with zz');
    expect(without).toContain('No packages have been published yet.');
  });

  test('a q too long gets a message (the caller makes no call)', () => {
    const out = html(searchTooLongView(sdoc, { q: 'a'.repeat(65), sort: 'name' }));
    expect(out).toContain('role="alert"');
    expect(text(out)).toContain('at most 64 characters');
  });

  test('a result name that is not a package name is text, not a link', () => {
    const out = html(searchResultsView(sdoc, { q: '', sort: 'name' }, { packages: [{ name: 'Bad/../x', latest: null, description: null, updated_at: 'x' }], next_cursor: null }));
    expect(out).toContain('<span class="result-name">Bad/../x</span>');
  });
});

describe('the search page design', () => {
  const list = listFixture('search by prefix');
  const out = html(searchResultsView(sdoc, { q: 'http', sort: 'name' }, list));

  // Mutant: a card that drops the description or the update date, or the glyph.
  test('each result is a card: glyph, name, latest version, description and the date of its last update', () => {
    const p = list.packages[0];
    const card = out.slice(out.indexOf('<li class="result">'), out.indexOf('</li>') + 5);
    expect(card).toMatch(/^<li class="result"><span class="glyph g[012]" aria-hidden="true">[a-z0-9_]{1,2}<\/span>/);
    expect(card).toContain(`<a href="/packages/${p.name}" class="result-name">${p.name}</a>`);
    if (p.description) expect(card).toContain(`<p class="result-desc">${p.description}</p>`);
    expect(card).toContain(`<p class="result-meta">Updated <time datetime="${p.updated_at}">${p.updated_at.slice(0, 10)}</time></p>`);
    expect(out.split('<li class="result">').length - 1).toBe(list.packages.length);
  });

  // The API matches a name prefix only. Mutants: a ranking chip, a "why it matched" or a ranking explainer added to the
  // page; the note saying what search matches removed.
  test('the page says search matches the start of a name, and claims no ranking', () => {
    expect(text(out)).toContain('Search matches the start of a package name, not descriptions or readmes.');
    expect(out).toContain('aria-describedby="search-note"');
    expect(text(out)).not.toMatch(/rank|relevan|best match|why it matched|exact name/i);
  });

  test('the big search box shows the current query, and the page has one h1 naming it', () => {
    expect(out).toContain('<div class="big-search">');
    expect(out).toMatch(/<input id="search-q" name="q" type="search" value="http"/);
    expect(out.match(/<h1[ >]/g)).toHaveLength(1);
    expect(text(out)).toContain('Packages starting with “http”');
  });

  // Mutant: the Next link losing rel=next or its button styling; the count not saying more pages exist.
  test('paging is a pair of buttons, and the count says when there is a next page', () => {
    expect(out).toMatch(/<a class="button button-primary" href="\/search\?q=http&amp;cursor=[^"]+" rel="next">Next page →<\/a>/);
    expect(text(out)).toMatch(/1 package, sorted by name; more on the next page\./);
    const later = html(searchResultsView(sdoc, { q: 'http', sort: 'updated', cursor: 'abc' }, { ...list, next_cursor: null }));
    expect(later).toContain('<a class="button" href="/search?q=http&amp;sort=updated">← First page</a>');
    expect(text(later)).toMatch(/packages? on this page, most recently updated first\./);
  });

  // The way out of each empty state sits in the empty-state block itself: the side panel's "Browse all packages" and
  // the pager's "First page" carry the same hrefs, so a page-wide href check passes with the block's link gone.
  // Mutants: any of the three links replaced by a span, or pointing elsewhere.
  const emptyBlock = (out: string): string => {
    const start = out.indexOf('<div class="empty-state">');
    expect(start).toBeGreaterThanOrEqual(0);
    return out.slice(start, out.indexOf('</div>', start) + 6);
  };
  test.each([
    ['a search with no match offers the full list', { q: 'zz', sort: 'name' as const }, '<a class="button" href="/search">Browse all packages</a>'],
    ['an empty later page goes back to the first page', { q: 'http', sort: 'name' as const, cursor: 'abc' }, '<a class="button" href="/search?q=http">Back to the first page</a>'],
    ['an empty registry offers the docs', { q: '', sort: 'name' as const }, '<a class="button" href="/docs/">Read the docs</a>'],
  ])('%s, inside the empty-state block', (_what, state, link) => {
    const block = emptyBlock(html(searchResultsView(sdoc, state, { packages: [], next_cursor: null })));
    expect(block).toContain(link);
    expect(block.match(/<a /g)).toHaveLength(1);
  });
});

describe('search errors', () => {
  const invalid = fromResponse(400, JSON.stringify({ error: { code: 'invalid_request', message: 'The request is not valid: bad cursor.', hint: '' } }), 'req-1');

  test('invalid_request with a cursor: a link back to the first page of the same query', () => {
    const out = html(searchErrorView(sdoc, { q: 'http', sort: 'updated', cursor: 'stale' }, invalid));
    expect(text(out)).toContain('This page link is no longer valid.');
    expect(hrefs(out)).toContain('/search?q=http&sort=updated');
  });

  test('invalid_request under sort=updated: the 1000-match cap, and a link to sort by name', () => {
    const out = html(searchErrorView(sdoc, { q: 'a', sort: 'updated' }, invalid));
    expect(text(out)).toContain('up to 1000 matching packages');
    expect(hrefs(out)).toContain('/search?q=a');
  });

  test('another failure: the error view with a Retry button, under the form', () => {
    const out = html(searchErrorView(sdoc, { q: 'a', sort: 'name' }, networkError()));
    expect(out).toContain('role="alert"');
    expect(out).toContain('<button type="button" class="button button-primary retry">Retry</button>');
    expect(out).toContain('<form class="search-form"');
    expect(out.indexOf('<form class="search-form"')).toBeLessThan(out.indexOf('role="alert"'));
  });

  // The band over a failed search carries the form but not the page heading: the error block has the one h1.
  // Mutant: the band built with its heading -> two h1s.
  test('a failed search has exactly one h1, the error\'s', () => {
    const out = html(searchErrorView(sdoc, { q: 'a', sort: 'name' }, networkError()));
    expect(out.match(/<h1[ >]/g)).toHaveLength(1);
    expect(out).toContain('<h1>Search failed</h1>');
  });
});

describe('shared views', () => {
  test('the read-only banner', () => {
    expect(text(serialize(readOnlyBanner(sdoc)))).toContain('Read-only mode.');
  });

  test('error: role=alert, the message, the server detail as text, the request id, Retry', () => {
    const err = fromResponse(500, JSON.stringify({ error: { code: 'internal_error', message: '<b>boom</b>', hint: '' } }), 'abc-123');
    const out = html(errorView(sdoc, err));
    expect(out).toContain('role="alert"');
    expect(out).toContain('&lt;b&gt;boom&lt;/b&gt;');
    expect(out).toContain('<code>abc-123</code>');
    expect(out).toContain('class="button button-primary retry"');
    // A way home next to Retry. Mutant: the Home button dropped.
    expect(hrefs(out)).toContain('/');
  });

  test('error: the server hint is shown as text when there is one', () => {
    const err = fromResponse(429, JSON.stringify({ error: { code: 'rate_limited', message: 'Slow down.', hint: 'Wait <1 minute>.' } }), null);
    const out = html(errorView(sdoc, err));
    expect(out).toContain('<p class="detail">Wait &lt;1 minute&gt;.</p>');
  });

  test('not found: noindex, and a way on', () => {
    const p = notFoundView(sdoc, 'zz_absent');
    expect(p.noindex).toBe(true);
    expect(hrefs(html(p))).toContain('/search?q=zz_absent');
    const v = notFoundView(sdoc, 'http_client', '9.9.9');
    expect(v.noindex).toBe(true);
    expect(hrefs(html(v))).toContain('/packages/http_client');
    expect(pageNotFoundView(sdoc).noindex).toBe(true);
  });

  // A not-found page is a place to go on from, not a dead end: a search box (its own id, so the header's #q stays the
  // one '/' focuses), Home, the package list and the docs. Mutants: the search box or the way-on row dropped; the box
  // given id q (two #q on the app shell).
  test.each([
    ['a package', () => notFoundView(sdoc, 'zz_absent'), 'zz_absent'],
    ['a version', () => notFoundView(sdoc, 'http_client', '9.9.9'), ''],
    ['an address', () => pageNotFoundView(sdoc), ''],
  ])('not found (%s): a search box, Home, Browse packages and Docs', (_what, make, q) => {
    const out = html(make());
    expect(out).toContain('<form class="lost-search" role="search" action="/search" method="get" aria-label="Search the registry">');
    expect(out).toContain(`<input id="lost-q" name="q" type="search" value="${q}"`);
    expect(out).not.toContain('id="q"');
    expect(hrefs(out)).toEqual(expect.arrayContaining(['/', '/search', '/docs/']));
    expect(out.match(/<h1[ >]/g)).toHaveLength(1);
    // The big "404" is decoration: hidden from screen readers, the h1 says it.
    expect(out).toContain('<p class="lost-code" aria-hidden="true">404</p>');
  });

  test('an unknown host: noindex, no API, the host shown as text', () => {
    const v = unknownHostView(sdoc, 'evil<x>mopm.dev');
    expect(v.noindex).toBe(true);
    expect(html(v)).toContain('evil&lt;x&gt;mopm.dev');
  });

  test('titles get the site suffix once', () => {
    expect(titleOf('http_client')).toBe('http_client · mopm');
    expect(titleOf('mopm')).toBe('mopm');
  });
});
