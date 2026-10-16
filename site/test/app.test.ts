// T14 (the app shell's routing, app.ts): which call an address makes and which view its answer gives. A fake client
// counts calls, so "no call" is checked, not assumed: a search too long to send, an address that is not an app route
// and a host outside the table make none. A version address tells a missing package from a missing version by the
// API's code.
import type { Client, Result, SearchQuery } from '../src/api';
import { appView, healthBanner } from '../src/app';
import { serialize } from '../src/doc';
import { fromResponse, networkError } from '../src/errors';
import type { Health, PackageList } from '../src/types';
import { hrefs, html, packageFixture, sdoc, text, versionFixture } from './view-helpers';

type Call = ['getHealth'] | ['searchPackages', SearchQuery] | ['getPackage', string] | ['getVersion', string, string];

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
  test('a q over 64 characters after trimming makes no call and says why', async () => {
    const { api, calls } = fake({ search: ok(EMPTY) });
    const view = await appView(sdoc, '/search', `?q=${'a'.repeat(65)}`, api, HOST);
    expect(calls).toEqual([]);
    expect(text(html(view))).toContain('at most 64 characters');
    expect(view.searchQ).toBe('a'.repeat(65));
  });

  test('a q of 64 characters is sent, trimmed, with the sort and cursor', async () => {
    const { api, calls } = fake({ search: ok(EMPTY) });
    await appView(sdoc, '/search', `?q=%20${'a'.repeat(64)}%20&sort=updated&cursor=abc`, api, HOST);
    expect(calls).toEqual([['searchPackages', { q: 'a'.repeat(64), sort: 'updated', cursor: 'abc' }]]);
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

describe('package', () => {
  test('one getPackage call with the route name, and the package view', async () => {
    const { api, calls } = fake({ pkg: ok(packageFixture()) });
    const view = await appView(sdoc, '/packages/http_client', '', api, HOST);
    expect(calls).toEqual([['getPackage', 'http_client']]);
    expect(html(view)).toContain('<h1>http_client</h1>');
    expect(html(view)).toContain('<code>https://conda.mopm.dev/</code>');
  });

  test('the host picks the channel the view shows', async () => {
    const { api } = fake({ pkg: ok(packageFixture()) });
    expect(html(await appView(sdoc, '/packages/http_client', '', api, 'beta.mopm.dev'))).toContain('<code>https://conda.beta.mopm.dev/</code>');
  });

  test('not found: the package-not-found view, noindex', async () => {
    const { api } = fake({ pkg: notFound('package_not_found') });
    const view = await appView(sdoc, '/packages/zz_absent', '', api, HOST);
    expect(view.title).toBe('Package not found');
    expect(view.noindex).toBe(true);
  });

  test('another failure: the error view with the request id', async () => {
    const { api } = fake({ pkg: fromResponse(500, JSON.stringify({ error: { code: 'internal_error', message: 'x', hint: '' } }), 'req-5') });
    const out = html(await appView(sdoc, '/packages/http_client', '', api, HOST));
    expect(out).toContain('role="alert"');
    expect(out).toContain('<code>req-5</code>');
  });
});

describe('version', () => {
  test('one getVersion call; the address is the version as published', async () => {
    const { api, calls } = fake({ version: ok(versionFixture('version detail')) });
    const view = await appView(sdoc, '/packages/http_client/0.4.0', '', api, HOST);
    expect(calls).toEqual([['getVersion', 'http_client', '0.4.0']]);
    expect(view.canonicalPath).toBe('/packages/http_client/0.4.0');
  });

  test('package_not_found: "Package not found"', async () => {
    const { api } = fake({ version: notFound('package_not_found') });
    const view = await appView(sdoc, '/packages/zz_absent/1.0.0', '', api, HOST);
    expect(view.title).toBe('Package not found');
    expect(hrefs(html(view))).toContain('/search?q=zz_absent');
  });

  test('version_not_found: "Version not found", with a link to the package', async () => {
    const { api } = fake({ version: notFound('version_not_found') });
    const view = await appView(sdoc, '/packages/http_client/9.9.9', '', api, HOST);
    expect(view.title).toBe('Version not found');
    expect(view.noindex).toBe(true);
    expect(hrefs(html(view))).toContain('/packages/http_client');
  });

  // routes.ts sends the API only names and versions its grammar accepts, so these answers mean the site's grammar and
  // the API's disagree. Retrying cannot help, so the reader gets the not-found page (noindex, no Retry).
  test.each([
    ['/packages/http_client/1.0.0', 'invalid_version', 'Version not found'],
    ['/packages/http_client/1.0.0', 'invalid_name', 'Package not found'],
    ['/packages/http_client', 'invalid_name', 'Package not found'],
  ])('%s answered 400 %s: "%s", noindex, no Retry', async (path, code, title) => {
    const bad = fromResponse(400, JSON.stringify({ error: { code, message: 'Not valid.', hint: '' } }), 'req-4');
    const { api } = fake({ version: bad, pkg: bad });
    const view = await appView(sdoc, path, '', api, HOST);
    expect(view.title).toBe(title);
    expect(view.noindex).toBe(true);
    expect(html(view)).not.toContain('Retry');
    expect(html(view)).not.toContain('role="alert"');
  });

  test('another 400 (invalid_request) is still the error view', async () => {
    const bad = fromResponse(400, JSON.stringify({ error: { code: 'invalid_request', message: 'x', hint: '' } }), 'req-4');
    const { api } = fake({ version: bad, pkg: bad });
    expect((await appView(sdoc, '/packages/http_client/1.0.0', '', api, HOST)).title).toBe('Something went wrong');
    expect((await appView(sdoc, '/packages/http_client', '', api, HOST)).title).toBe('Something went wrong');
  });

  test('a network failure: the error view, not a not-found', async () => {
    const { api } = fake();
    const view = await appView(sdoc, '/packages/http_client/1.0.0', '', api, HOST);
    expect(view.title).toBe('Something went wrong');
  });
});

describe('no call at all', () => {
  test.each(['/', '/packages/Foo', '/packages/a', '/packages/x/v1', '/packages/xy/1.0', '/packages/xy/1.0rc1', '/packages/xy/1.0.0.0', '/app.html', '/search/x'])('%s is not an app route', async (path) => {
    const { api, calls } = fake();
    const view = await appView(sdoc, path, '', api, HOST);
    expect(calls).toEqual([]);
    expect(view.title).toBe('Page not found');
    expect(view.noindex).toBe(true);
  });

  test('a host outside the table (no client): the unknown-host view', async () => {
    const view = await appView(sdoc, '/packages/http_client', '', null, 'evil-mopm.invalid');
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
