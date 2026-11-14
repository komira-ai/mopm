import * as fs from 'fs';
import * as path from 'path';
import { SPA_ROUTER_SOURCE } from '../lib/site-stack';

// The edge router (the CloudFront Function of the site stack) over the site's shared route vectors: the same file the
// site's parseRoute is tested against (site/test/routes.test.ts), so the edge and the app shell agree on every path.

type Request = { method: string; uri: string; querystring: Record<string, { value: string; multiValue?: { value: string }[] }>; headers: object };
type Redirect = { statusCode: number; statusDescription: string; headers: { location: { value: string } } };
type Vector = { path: string; edge: string; view: unknown };

const VECTORS_FILE = path.resolve(__dirname, '../../../../site/test/fixtures/routes.json');
const V = (JSON.parse(fs.readFileSync(VECTORS_FILE, 'utf8')) as { vectors: Vector[] }).vectors;

// The function source as CloudFront runs it: a script whose `handler` is called with the event.
const handler = new Function(`${SPA_ROUTER_SOURCE}\nreturn handler;`)() as (e: { request: Request }) => Request | Redirect;

const request = (uri: string, querystring: Request['querystring'] = {}): Request => ({ method: 'GET', uri, querystring, headers: {} });

/** What the router did, in the vectors' terms: the rewritten URI, "redirect:<location>" (301), "found:<location>" (302), or "pass". */
function edge(uri: string): string {
  const out = handler({ request: request(uri) });
  if ('statusCode' in out) {
    const kind = out.statusCode === 301 ? 'redirect' : out.statusCode === 302 ? 'found' : null;
    expect(kind).not.toBeNull();
    expect(out.statusDescription).toBe(kind === 'redirect' ? 'Moved Permanently' : 'Found');
    return `${kind}:${out.headers.location.value}`;
  }
  return out.uri === uri ? 'pass' : out.uri;
}

test.each(V.map((v) => [v.path, v.edge] as const))('router(%j) is %j', (uri, want) => {
  expect(edge(uri)).toBe(want);
});

test('the vectors exercise every kind of answer, including a version route that ends in what looks like an extension', () => {
  expect(V.length).toBeGreaterThan(40);
  const kinds = new Set(V.map((v) => (v.edge.startsWith('redirect:') ? 'redirect' : v.edge.startsWith('found:') ? 'found' : v.edge)));
  for (const k of ['/index.html', '/app.html', '/docs/index.html', 'redirect', 'found', 'pass']) expect(kinds).toContain(k);
  expect(V).toContainEqual(expect.objectContaining({ path: '/packages/a/ab/1.0.0', edge: '/app.html' }));
  expect(V).toContainEqual(
    expect.objectContaining({ path: '/packages/komira-ai/http.client', edge: 'redirect:/packages/komira-ai/http_client' }),
  );
  expect(V).toContainEqual(expect.objectContaining({ path: '/packages/http.client', edge: 'found:/search?q=http_client' }));
});

test('a redirect keeps the query string, repeated and empty parameters included', () => {
  const out = handler({
    request: request('/packages/komira-ai/HTTP-Client', {
      tab: { value: 'versions' },
      flag: { value: '' },
      q: { value: 'a%20b', multiValue: [{ value: 'a%20b' }, { value: 'c' }] },
    }),
  }) as Redirect;
  expect(out).toEqual({
    statusCode: 301,
    statusDescription: 'Moved Permanently',
    headers: { location: { value: '/packages/komira-ai/http_client?tab=versions&flag&q=a%20b&q=c' } },
  });
  expect((handler({ request: request('/packages/komira-ai/Foo') }) as Redirect).headers.location.value).toBe(
    '/packages/komira-ai/foo',
  );
});

test('a 302 to a search builds its own query: the request query string is not carried over', () => {
  const qs = { tab: { value: 'versions' }, q: { value: 'x', multiValue: [{ value: 'x' }, { value: 'y' }] } };
  for (const [uri, want] of [
    ['/packages/HTTP-Client', '/search?q=http_client'],
    ['/packages/komira-ai', '/search?q=komira-ai%2F'],
    ['/packages/ab/1.0.0', '/search?q=ab'],
  ]) {
    expect(handler({ request: request(uri, qs) })).toEqual({
      statusCode: 302,
      statusDescription: 'Found',
      headers: { location: { value: want } },
    });
  }
});

test('a namespace is never normalised: Komira-AI under a package passes, a name under a namespace is redirected with its query', () => {
  expect(edge('/packages/Komira-AI/json')).toBe('pass');
  const out = handler({ request: request('/packages/komira-ai/Foo__Bar', { a: { value: '1' } }) }) as Redirect;
  expect(out.statusCode).toBe(301);
  expect(out.headers.location.value).toBe('/packages/komira-ai/foo_bar?a=1');
});

test('a rewrite or a pass returns the request itself, with its query, method and headers untouched', () => {
  const qs = { cursor: { value: 'x' } };
  const r = request('/search', qs);
  const out = handler({ request: r }) as Request;
  expect(out).toBe(r);
  expect(out).toEqual({ method: 'GET', uri: '/app.html', querystring: qs, headers: {} });
});

test('the router names no host or stage, so every stage runs the same function', () => {
  expect(SPA_ROUTER_SOURCE).not.toMatch(/mopm|beta|gamma|prod|https?:/);
});
