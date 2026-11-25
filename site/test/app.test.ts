// T14 (the app shell's routing, app.ts): which call an address makes and which view its answer gives. A fake client
// counts calls, so "no call" is checked, not assumed: a search too long to send, an address that is not an app route
// and a host outside the table make none. A version address tells a missing package from a missing version by the
// API's code.
import type { Client, Result, SearchQuery } from '../src/api';
import { appView, healthBanner } from '../src/app';
import { serialize } from '../src/doc';
import { fromResponse, networkError } from '../src/errors';
import type { FullName } from '../src/routes';
import type { Health, PackageList } from '../src/types';
import { hrefs, html, packageFixture, sdoc, text, versionFixture } from './view-helpers';

type Call = ['getHealth'] | ['searchPackages', SearchQuery] | ['getPackage', FullName] | ['getVersion', FullName, string];

/** A client that records each call and answers with `answer` (or a network failure when there is none). */
function fake(answer: Partial<{ search: Result<PackageList>; pkg: Result<unknown>; version: Result<unknown> }> = {}) {
  const calls: Call[] = [];
  const api: Client = {
    getHealth: async () => {
      calls.push(['getHealth']);
      return networkError();
    },
    searchPackages: async (q) => {
      calls.push(['searchPackages', q]);
      return answer.search ?? networkError();
    },
    getPackage: async (n) => {
      calls.push(['getPackage', n]);
      return (answer.pkg ?? networkError()) as never;
    },
    getVersion: async (n, v) => {
      calls.push(['getVersion', n, v]);
      return (answer.version ?? networkError()) as never;
    },
  };
  return { api, calls };
}

const ok = <T>(value: T): Result<T> => ({ kind: 'ok', value, requestId: null });
const notFound = (code: string) => fromResponse(404, JSON.stringify({ error: { code, message: 'Not here.', hint: '' } }), 'req-9');
const HOST = 'mopm.dev';
const EMPTY: PackageList = { packages: [], next_cursor: null };

describe('search', () => {
  test('a q over 104 characters after trimming makes no call and says why', async () => {
    const { api, calls } = fake({ search: ok(EMPTY) });
    const view = await appView(sdoc, '/search', `?q=${'a'.repeat(105)}`, api, HOST);
    expect(calls).toEqual([]);
    expect(text(html(view))).toContain('at most 104 characters');
    expect(view.searchQ).toBe('a'.repeat(105));
  });

  test('a q of 104 characters is sent, trimmed, with the sort and cursor', async () => {
    const { api, calls } = fake({ search: ok(EMPTY) });
    await appView(sdoc, '/search', `?q=%20${'a'.repeat(104)}%20&sort=updated&cursor=abc`, api, HOST);
    expect(calls).toEqual([['searchPackages', { q: 'a'.repeat(104), sort: 'updated', cursor: 'abc' }]]);
  });

  test('an empty q is not sent; the address is normalised', async () => {
    const { api, calls } = fake({ search: ok(EMPTY) });
    const view = await appView(sdoc, '/search', '?q=%20&sort=stars&x=1', api, HOST);
    expect(calls).toEqual([['searchPackages', { q: undefined, sort: 'name', cursor: undefined }]]);
    expect(view.canonicalPath).toBe('/search');
    expect(text(html(view))).toContain('No packages have been published yet.');
  });

  test('a failed search keeps the form and offers Retry', async () => {
    const { api } = fake();
    const out = html(await appView(sdoc, '/search', '?q=http', api, HOST));
    expect(out).toContain('<form class="search-form"');
    expect(out).toContain('class="button button-primary retry"');
  });
});

const KOMIRA: FullName = { namespace: 'komira-ai', name: 'json' };
const refused = (code: string, status = 400) => fromResponse(status, JSON.stringify({ error: { code, message: 'Not valid.', hint: '' } }), 'req-4');

describe('package', () => {
  test('one getPackage call with the route namespace and name, and the package view', async () => {
    const { api, calls } = fake({ pkg: ok(packageFixture()) });
    const view = await appView(sdoc, '/packages/komira-ai/json', '', api, HOST);
    expect(calls).toEqual([['getPackage', KOMIRA]]);
    expect(html(view)).toContain('<span class="ns">komira-ai/</span><span>json</span></h1>');
    expect(html(view)).toContain('<code>mopm add komira-ai/json</code>');
  });

  // The host reaches the view: a page on beta names beta's registry in its commands.
  test('the host picks the registry the view\'s commands name', async () => {
    const { api } = fake({ pkg: ok(packageFixture()) });
    expect(html(await appView(sdoc, '/packages/komira-ai/json', '', api, 'beta.mopm.dev'))).toContain('<code>mopm add komira-ai/json --registry beta</code>');
  });

  test.each(['package_not_found', 'namespace_not_found'])('%s: the package-not-found view, noindex', async (code) => {
    const { api } = fake({ pkg: notFound(code) });
    const view = await appView(sdoc, '/packages/komira-ai/zz_absent', '', api, HOST);
    expect(view.title).toBe('Package not found');
    expect(view.noindex).toBe(true);
  });

  test('another failure: the error view with the request id', async () => {
    const { api } = fake({ pkg: fromResponse(500, JSON.stringify({ error: { code: 'internal_error', message: 'x', hint: '' } }), 'req-5') });
    const out = html(await appView(sdoc, '/packages/komira-ai/json', '', api, HOST));
    expect(out).toContain('role="alert"');
    expect(out).toContain('<code>req-5</code>');
  });
});

describe('version', () => {
  test('one getVersion call; the address is the version as published', async () => {
    const { api, calls } = fake({ version: ok(versionFixture('version detail')) });
    const view = await appView(sdoc, '/packages/komira-ai/json/1.1.0', '', api, HOST);
    expect(calls).toEqual([['getVersion', KOMIRA, '1.1.0']]);
    expect(view.canonicalPath).toBe('/packages/komira-ai/json/1.1.0');
  });

  test.each(['package_not_found', 'namespace_not_found'])('%s: "Package not found", and the way on is a search for the name in every namespace', async (code) => {
    const { api } = fake({ version: notFound(code) });
    const view = await appView(sdoc, '/packages/komira-ai/zz_absent/1.0.0', '', api, HOST);
    expect(view.title).toBe('Package not found');
    expect(view.noindex).toBe(true);
    expect(hrefs(html(view))).toContain('/search?q=zz_absent');
    expect(text(html(view))).toContain('komira-ai/zz_absent');
  });

  test('version_not_found: "Version not found", with a link to the package', async () => {
    const { api } = fake({ version: notFound('version_not_found') });
    const view = await appView(sdoc, '/packages/komira-ai/json/9.9.9', '', api, HOST);
    expect(view.title).toBe('Version not found');
    expect(view.noindex).toBe(true);
    expect(hrefs(html(view))).toContain('/packages/komira-ai/json');
  });

  // routes.ts sends the API only namespaces, names and versions its grammar accepts, so these answers mean the site's
  // grammar and the API's disagree (or the namespace is one nobody can hold). Retrying cannot help, so the reader gets
  // the not-found page (noindex, no Retry).
  test.each([
    ['/packages/komira-ai/json/1.0.0', 400, 'invalid_version', 'Version not found'],
    ['/packages/komira-ai/json/1.0.0', 400, 'invalid_name', 'Package not found'],
    ['/packages/komira-ai/json/1.0.0', 400, 'invalid_namespace', 'Package not found'],
    ['/packages/komira-ai/json/1.0.0', 403, 'namespace_reserved', 'Package not found'],
    ['/packages/komira-ai/json', 400, 'invalid_name', 'Package not found'],
    ['/packages/komira-ai/json', 400, 'invalid_namespace', 'Package not found'],
    ['/packages/noarch/json', 403, 'namespace_reserved', 'Package not found'],
  ])('%s answered %i %s: "%s", noindex, no Retry', async (path, status, code, title) => {
    const bad = refused(code, status);
    const { api } = fake({ version: bad, pkg: bad });
    const view = await appView(sdoc, path, '', api, HOST);
    expect(view.title).toBe(title);
    expect(view.noindex).toBe(true);
    expect(html(view)).not.toContain('Retry');
    expect(html(view)).not.toContain('role="alert"');
  });

  test('another 400 (invalid_request) is still the error view', async () => {
    const bad = refused('invalid_request');
    const { api } = fake({ version: bad, pkg: bad });
    expect((await appView(sdoc, '/packages/komira-ai/json/1.0.0', '', api, HOST)).title).toBe('Something went wrong');
    expect((await appView(sdoc, '/packages/komira-ai/json', '', api, HOST)).title).toBe('Something went wrong');
  });

  test('a 403 that is not namespace_reserved is still the error view', async () => {
    const bad = refused('forbidden', 403);
    const { api } = fake({ version: bad, pkg: bad });
    expect((await appView(sdoc, '/packages/komira-ai/json/1.0.0', '', api, HOST)).title).toBe('Something went wrong');
    expect((await appView(sdoc, '/packages/komira-ai/json', '', api, HOST)).title).toBe('Something went wrong');
  });

  test('a network failure: the error view, not a not-found', async () => {
    const { api } = fake();
    const view = await appView(sdoc, '/packages/komira-ai/json/1.0.0', '', api, HOST);
    expect(view.title).toBe('Something went wrong');
  });
});

describe('no call at all', () => {
  test.each([
    '/', '/packages/Foo', '/packages/a', '/packages/komira-ai/json/v1', '/packages/xy/1.0', '/packages/komira-ai/json/1.0', '/packages/komira-ai/json/1.0rc1',
    '/packages/komira-ai/json/1.0.0.0', '/packages/Komira-AI/json', '/packages/komira--ai/json', '/packages/-komira/json', '/packages/komira-ai/Json',
    `/packages/${'a'.repeat(40)}/json`, '/packages/komira-ai/json/1.0.0/x', '/app.html', '/search/x',
  ])('%s is not an app route', async (path) => {
    const { api, calls } = fake();
    const view = await appView(sdoc, path, '', api, HOST);
    expect(calls).toEqual([]);
    expect(view.title).toBe('Page not found');
    expect(view.noindex).toBe(true);
  });

  test('a host outside the table (no client): the unknown-host view', async () => {
    const view = await appView(sdoc, '/packages/komira-ai/json', '', null, 'evil-mopm.invalid');
    expect(view.title).toBe('Registry unavailable');
    expect(html(view)).toContain('<code>evil-mopm.invalid</code>');
  });
});

describe('healthBanner', () => {
  const health = (read_only: boolean): Result<Health> => ok({ status: 'ok', stage: 'prod', api_version: '1', read_only });

  test('read-only: the banner', () => {
    const b = healthBanner(sdoc, health(true));
    expect(b).not.toBeNull();
    expect(text(serialize(b as never))).toContain('Read-only mode.');
  });

  test('writable, or any failure: nothing', () => {
    expect(healthBanner(sdoc, health(false))).toBeNull();
    expect(healthBanner(sdoc, networkError())).toBeNull();
  });
});
