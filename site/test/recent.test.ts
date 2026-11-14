// The home page's "Recently published" list (src/views/recent.ts), over the contract fixtures replayed through the real
// client. What each test proves, and the defect it catches:
//  - the list makes exactly one call, GET /packages?sort=updated&limit=8 (a list built from name order, or with no
//    limit, fails it);
//  - a published package shows its name as a link, its version, description and date, all as text (an unescaped
//    description or a link for a name outside the grammar fails it);
//  - a claimed name (latest null) is left out, and a last page (next_cursor null) of only claims, or an empty registry,
//    says nothing is published (listing claims as "published", or an empty <ol> for an empty registry, fails it); a
//    page of only claims with more pages behind it links to the full list instead (calling a registry with published
//    packages further down empty fails it);
//  - each row's date is labelled as an update, since sort=updated also moves a package on a yank (a bare date under a
//    "published" heading fails it);
//  - the API's refusal of sort=updated over more than 1000 packages, and any other failure, each get a sentence and a
//    link to the name-sorted list (an empty slot or an endless "Loading" fails it).
import { client, type FetchFn } from '../src/api';
import { fromResponse } from '../src/errors';
import { glyphClass, initials, RECENT_LIMIT, recentList, recentQuery, recentUnavailable } from '../src/views/recent';
import { load, responseOf, validReadCases } from './fixtures';
import { hrefs, sdoc, text, uniqueIds } from './view-helpers';
import { type SNode, serialize } from '../src/doc';
import type { PackageList } from '../src/types';

const out = (nodes: SNode[]) => serialize(nodes);
const listCase = (name: string) => {
  const c = validReadCases().find((x) => x.name === name);
  if (!c) throw new Error(`no fixture '${name}'`);
  return c;
};

test('one call: GET /packages?sort=updated&limit=8, and its answer decodes', async () => {
  const urls: string[] = [];
  const fetchFn: FetchFn = async (url) => {
    urls.push(url);
    return responseOf(listCase('search by name prefix in every namespace'));
  };
  const r = await client(fetchFn, 'https://api.mopm.dev/api/v2').searchPackages(recentQuery());
  expect(urls).toEqual(['https://api.mopm.dev/api/v2/packages?sort=updated&limit=8']);
  expect(RECENT_LIMIT).toBe(8);
  expect(r.kind).toBe('ok');
});

describe('an answer with a published package (fixture: search by name prefix in every namespace)', () => {
  const list = listCase('search by name prefix in every namespace').response.body as PackageList;
  const html = out(recentList(sdoc, { kind: 'ok', value: list, requestId: null }));

  test('the full name links to the package page inside its namespace; version and date are shown', () => {
    expect(html).toContain('<a href="/packages/alice/json" class="recent-name">alice/json</a>');
    expect(html).toContain('<a href="/packages/komira-ai/json" class="recent-name">komira-ai/json</a>');
    expect(text(html)).toContain('version 1.1.0');
    expect(html).toContain('updated <time datetime="2026-11-02T09:00:00.000Z">2026-11-02</time>');
    expect(html.startsWith('<ol class="recent">')).toBe(true);
  });

  test('the glyph is decorative', () => {
    expect(html).toContain('<span class="glyph g');
    expect(html).toMatch(/<span class="glyph g[0-2]" aria-hidden="true">js<\/span>/);
  });
});

test('a claimed name with no version is not listed; a page of claims only says nothing is published', () => {
  const list = listCase('search, last page, a package with no version').response.body as PackageList;
  const html = out(recentList(sdoc, { kind: 'ok', value: list, requestId: null }));
  expect(html).not.toContain('jsonschema');
  expect(text(html)).toBe('Nothing has been published yet.');
});

test('an empty registry (no packages, last page) says nothing is published, with no list', () => {
  const html = out(recentList(sdoc, { kind: 'ok', value: { packages: [], next_cursor: null }, requestId: null }));
  expect(text(html)).toBe('Nothing has been published yet.');
  expect(html).not.toContain('<ol');
});

test('a page of only claims with more pages behind it does not say the registry is empty', () => {
  const value: PackageList = {
    next_cursor: 'abc',
    packages: [{ name: 'alice/just_claimed', latest: null, description: null, updated_at: '2026-10-13T00:00:00Z' }],
  };
  const html = out(recentList(sdoc, { kind: 'ok', value, requestId: null }));
  expect(text(html)).toBe('No recently updated package has a published version. Browse all packages.');
  expect(hrefs(html)).toEqual(['/search']);
  expect(html).not.toContain('<ol');
});

test('each row says its date is an update, not a publish', () => {
  const value: PackageList = { next_cursor: null, packages: [{ name: 'alice/p', latest: '1.0.0', description: null, updated_at: '2026-10-14T00:00:00Z' }] };
  const html = out(recentList(sdoc, { kind: 'ok', value, requestId: null }));
  expect(html).toContain('<p class="recent-when">updated <time datetime="2026-10-14T00:00:00Z">2026-10-14</time></p>');
  expect(text(html)).not.toMatch(/published/i);
});

test('a mix keeps the published ones in the order the registry sent', () => {
  const value: PackageList = {
    next_cursor: null,
    packages: [
      { name: 'alice/newer_pkg', latest: '1.0.0', description: null, updated_at: '2026-10-14T00:00:00Z' },
      { name: 'alice/just_claimed', latest: null, description: null, updated_at: '2026-10-13T00:00:00Z' },
      { name: 'komira-ai/older_pkg', latest: '0.1.0', description: '<b>bold</b>', updated_at: '2026-10-12T00:00:00Z' },
    ],
  };
  const html = out(recentList(sdoc, { kind: 'ok', value, requestId: null }));
  expect(hrefs(html)).toEqual(['/packages/alice/newer_pkg', '/packages/komira-ai/older_pkg']);
  expect(html).toContain('&lt;b&gt;bold&lt;/b&gt;');
  expect(uniqueIds(html)).toBe(true);
});

test('a name outside the grammar is text, not a link', () => {
  const value: PackageList = { next_cursor: null, packages: [{ name: 'Bad/../x', latest: '1.0.0', description: null, updated_at: '2026-10-14T00:00:00Z' }] };
  const html = out(recentList(sdoc, { kind: 'ok', value, requestId: null }));
  expect(hrefs(html)).toEqual([]);
  expect(html).toContain('<span class="recent-name">Bad/../x</span>');
});

test.each([
  ['a flat name', 'json'],
  ['an upper-case namespace', 'Komira-AI/json'],
  ['a name outside the grammar', 'komira-ai/Json'],
  ['an empty name', 'komira-ai/'],
  ['an empty namespace', '/json'],
  ['a namespace over 39 characters', `${'a'.repeat(40)}/json`],
])('%s is text, not a link', (_what, name) => {
  const value: PackageList = { next_cursor: null, packages: [{ name, latest: '1.0.0', description: null, updated_at: '2026-10-14T00:00:00Z' }] };
  const html = out(recentList(sdoc, { kind: 'ok', value, requestId: null }));
  expect(hrefs(html)).toEqual([]);
  expect(html).toContain(`<span class="recent-name">${name}</span>`);
});

test('a namespace of 39 characters links', () => {
  const name = `${'a'.repeat(39)}/json`;
  const value: PackageList = { next_cursor: null, packages: [{ name, latest: '1.0.0', description: null, updated_at: '2026-10-14T00:00:00Z' }] };
  expect(hrefs(out(recentList(sdoc, { kind: 'ok', value, requestId: null })))).toEqual([`/packages/${name}`]);
});

test('the glyph initials come from the name part, not the namespace', () => {
  const value: PackageList = { next_cursor: null, packages: [{ name: 'komira-ai/http_client', latest: '1.0.0', description: null, updated_at: '2026-10-14T00:00:00Z' }] };
  const html = out(recentList(sdoc, { kind: 'ok', value, requestId: null }));
  expect(html).toMatch(/aria-hidden="true">hc<\/span>/);
});

test('the refusal of sort=updated (invalid_request) gets its own sentence and a name-sorted link', () => {
  const c = load('errors').find((x) => x.name === 'error invalid_request');
  if (!c) throw new Error('no fixture');
  const err = fromResponse(c.response.status, JSON.stringify(c.response.body), null);
  const html = out(recentList(sdoc, err));
  expect(text(html)).toBe('The registry has too many packages to list by update time here. Browse all packages.');
  expect(hrefs(html)).toEqual(['/search']);
});

test.each(['error internal_error', 'error unavailable', 'error rate_limited'])('%s: a sentence and a link, never an empty slot', (name) => {
  const c = load('errors').find((x) => x.name === name);
  if (!c) throw new Error('no fixture');
  const html = out(recentList(sdoc, fromResponse(c.response.status, JSON.stringify(c.response.body), null)));
  expect(text(html)).toBe('Recently updated packages could not be loaded. Browse all packages.');
  expect(hrefs(html)).toEqual(['/search']);
});

test('on a host outside the table the slot says why it is empty', () => {
  expect(text(out(recentUnavailable(sdoc)))).toContain('not served from mopm.dev');
});

test('initials and glyph colour: first letters of two words, else the first two; the same colour for a name', () => {
  expect(initials('http_client')).toBe('hc');
  expect(initials('json')).toBe('js');
  expect(initials('a_b_c')).toBe('ab');
  expect(glyphClass('json')).toBe(glyphClass('json'));
  expect(new Set(['a1', 'b2', 'c3', 'd4', 'e5', 'f6', 'g7'].map(glyphClass)).size).toBeGreaterThan(1);
});
