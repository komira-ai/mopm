import * as fs from 'fs';
import * as path from 'path';
import { FUNCTION_MAX_BYTES, NOT_FOUND_PAGE, siteRouterSource } from '../lib/site-stack';

// The edge router (the CloudFront Function of the site stack's default behaviour) over the site's shared route vectors:
// the same file the site's parseRoute is tested against (site/test/routes.test.ts), so the edge and the app shell agree
// on every path. The vectors name the build they assume (files); the router is generated for that build.

type Query = Record<string, { value: string; multiValue?: { value: string }[] }>;
type Request = { method: string; uri: string; querystring: Query; headers: object };
type Redirect = { statusCode: number; statusDescription: string; headers: { location: { value: string } } };
type Response = { statusCode: number; statusDescription: string; headers: Record<string, { value: string }> };
type Vector = { path: string; edge: string; view: unknown };
type Event = { context?: { eventType: string }; request: Request; response?: Response };

const VECTORS_FILE = path.resolve(__dirname, '../../../../site/test/fixtures/routes.json');
const FIXTURE = JSON.parse(fs.readFileSync(VECTORS_FILE, 'utf8')) as { files: string[]; vectors: Vector[] };
const V = FIXTURE.vectors;
const SOURCE = siteRouterSource(FIXTURE.files);

/** The function source as CloudFront runs it: a script whose `handler` is called with the event. */
const load = (source: string) => new Function(`${source}\nreturn handler;`)() as (e: Event) => Request | Redirect | Response;
const handler = load(SOURCE);

const request = (uri: string, querystring: Query = {}): Request => ({ method: 'GET', uri, querystring, headers: {} });
const viewerRequest = (r: Request) => handler({ context: { eventType: 'viewer-request' }, request: r });

/** What the router did, in the vectors' terms: the rewritten URI, "redirect:<location>" (301), "found:<location>" (302), or "pass". */
function edge(uri: string): string {
  const out = viewerRequest(request(uri));
  if ('statusCode' in out) {
    const kind = out.statusCode === 301 ? 'redirect' : out.statusCode === 302 ? 'found' : null;
    expect(kind).not.toBeNull();
    expect(out.statusDescription).toBe(kind === 'redirect' ? 'Moved Permanently' : 'Found');
    return `${kind}:${(out as Redirect).headers.location.value}`;
  }
  return out.uri === uri ? 'pass' : out.uri;
}

const response = (statusCode: number, headers: Response['headers'] = { 'content-type': { value: 'text/html' } }): Response => ({
  statusCode,
  statusDescription: statusCode === 200 ? 'OK' : 'Error',
  headers,
});

/** The viewer-response run for a request of `uri` that the cache or bucket answered with `res`. */
function viewerResponse(uri: string, res: Response): Response {
  return handler({ context: { eventType: 'viewer-response' }, request: request(uri), response: res }) as Response;
}

test.each(V.map((v) => [v.path, v.edge] as const))('router(%j) is %j', (uri, want) => {
  expect(edge(uri)).toBe(want);
});

test.each(V.map((v) => [v.path, v.edge] as const))('the response to %j (router: %j) has the status it should', (uri, want) => {
  // CloudFront hands the viewer-response function the viewer's request; whether its URI is the one the viewer sent or
  // the one the router rewrote it to, the answer is the same.
  // The 404 page itself is a 404 too, however it was asked for (the function cannot tell its own rewrite from it).
  const rewritten = want.startsWith('/') ? want : uri;
  for (const seen of [uri, rewritten]) {
    const out = viewerResponse(seen, response(200));
    if (want === NOT_FOUND_PAGE || uri === NOT_FOUND_PAGE) {
      expect([seen, out.statusCode, out.statusDescription]).toEqual([seen, 404, 'Not Found']);
    } else {
      expect([seen, out.statusCode, out.statusDescription]).toEqual([seen, 200, 'OK']);
    }
    expect(out.headers).toEqual({ 'content-type': { value: 'text/html' } });
    expect(out).not.toHaveProperty('body');
  }
});

test('the vectors exercise every kind of answer, including a version route that ends in what looks like an extension', () => {
  expect(V.length).toBeGreaterThan(40);
  const kinds = new Set(V.map((v) => (v.edge.startsWith('redirect:') ? 'redirect' : v.edge.startsWith('found:') ? 'found' : v.edge)));
  for (const k of ['/index.html', '/app.html', '/docs/index.html', '/tutorial/index.html', '/tutorial/hello/index.html', '/404.html', 'redirect', 'found', 'pass']) {
    expect(kinds).toContain(k);
  }
  expect(V).toContainEqual(expect.objectContaining({ path: '/packages/a/ab/1.0.0', edge: '/app.html' }));
  expect(V).toContainEqual(
    expect.objectContaining({ path: '/packages/komira-ai/http.client', edge: 'redirect:/packages/komira-ai/http_client' }),
  );
  expect(V).toContainEqual(expect.objectContaining({ path: '/packages/http.client', edge: 'found:/search?q=http_client' }));
});

test('an unknown page, a missing docs page and a missing key under /assets/ of this build get the 404 page', () => {
  const [build] = new Set(FIXTURE.files.filter((f) => f.startsWith('/assets/')).map((f) => f.split('/')[2]));
  // A docs slug the build has no page for is held here, not in the shared vectors: return_to (service/lambda/core) keeps
  // every path of the docs grammar, and its vector test reads a kept path as one the router serves a page for.
  for (const uri of [
    '/nope', '/nope.txt', '/docs/no-such-page', '/docs/no-such-page/', `/assets/${build}/nope.js`, `/assets/${build}/`, '/assets/main.js',
  ]) {
    expect([uri, edge(uri)]).toEqual([uri, '/404.html']);
    expect([uri, viewerResponse(uri, response(200)).statusCode]).toEqual([uri, 404]);
  }
  // The page itself is answered with 404 too, however it was asked for.
  expect(viewerResponse('/404.html', response(200)).statusCode).toBe(404);
});

test('a lesson id the build has no page for, and a tutorial path of the wrong shape, get the 404 page', () => {
  // Held here, not in the shared vectors: return_to keeps every path of the lesson grammar, and its vector test reads a
  // kept path as one the router serves a page for.
  for (const uri of ['/tutorial/no-such-lesson', '/tutorial/index', '/tutorial/hello-world-2', '/tutorial//hello', '/tutorial/hello%2F']) {
    expect([uri, edge(uri)]).toEqual([uri, '/404.html']);
    expect([uri, viewerResponse(uri, response(200)).statusCode]).toEqual([uri, 404]);
  }
});

// A stage without the tutorial's E2B template leaves the tutorial's files out of the router's build (site-stack.ts
// servedFiles): there the router answers every tutorial vector with the 404 page, and every other vector as before.
test('a router of the build without its tutorial files answers every tutorial path with the 404 page, and the rest as before', () => {
  const without = load(siteRouterSource(FIXTURE.files.filter((f) => !f.startsWith('/tutorial/'))));
  const run = (uri: string) => {
    const out = without({ context: { eventType: 'viewer-request' }, request: request(uri) });
    return 'statusCode' in out ? (out as Redirect).headers.location.value : (out as Request).uri;
  };
  const tutorial = V.filter((v) => v.path.startsWith('/tutorial'));
  expect(tutorial.length).toBeGreaterThan(5);
  for (const v of tutorial) expect([v.path, run(v.path)]).toEqual([v.path, '/404.html']);
  for (const v of V.filter((x) => !x.path.startsWith('/tutorial') && !x.edge.includes(':'))) {
    expect([v.path, run(v.path)]).toEqual([v.path, v.edge === 'pass' ? v.path : v.edge]);
  }
});

test("an asset of an earlier build goes to the bucket as it is: the router knows only this build's files", () => {
  for (const uri of ['/assets/ffffffffffffffff/main.js', '/assets/ffffffffffffffff/views/removed.js']) {
    expect([uri, edge(uri)]).toEqual([uri, 'pass']);
    expect([uri, viewerResponse(uri, response(200)).statusCode]).toEqual([uri, 200]);
  }
});

test('the viewer response leaves every status but 200 as it is: a JSON 404 stays a JSON 404', () => {
  const json = { 'content-type': { value: 'application/json' }, 'cache-control': { value: 'no-store' } };
  for (const uri of ['/api/v2/packages/komira-ai/nope', '/nope', '/404.html']) {
    for (const status of [304, 400, 403, 404, 500, 503]) {
      const res = response(status, json);
      const before = JSON.parse(JSON.stringify(res));
      const out = viewerResponse(uri, res);
      expect([uri, out]).toEqual([uri, before]);
    }
  }
});

test('a redirect keeps the query string, repeated and empty parameters included', () => {
  const out = viewerRequest(
    request('/packages/komira-ai/HTTP-Client', {
      tab: { value: 'versions' },
      flag: { value: '' },
      q: { value: 'a%20b', multiValue: [{ value: 'a%20b' }, { value: 'c' }] },
    }),
  ) as Redirect;
  expect(out).toEqual({
    statusCode: 301,
    statusDescription: 'Moved Permanently',
    headers: { location: { value: '/packages/komira-ai/http_client?tab=versions&flag&q=a%20b&q=c' } },
  });
  expect((viewerRequest(request('/packages/komira-ai/Foo')) as Redirect).headers.location.value).toBe('/packages/komira-ai/foo');
});

test('a 302 to a search builds its own query: the request query string is not carried over', () => {
  const qs = { tab: { value: 'versions' }, q: { value: 'x', multiValue: [{ value: 'x' }, { value: 'y' }] } };
  for (const [uri, want] of [
    ['/packages/HTTP-Client', '/search?q=http_client'],
    ['/packages/komira-ai', '/search?q=komira-ai%2F'],
    ['/packages/ab/1.0.0', '/search?q=ab'],
  ]) {
    expect(viewerRequest(request(uri, qs))).toEqual({
      statusCode: 302,
      statusDescription: 'Found',
      headers: { location: { value: want } },
    });
  }
});

test('a namespace is never normalised: Komira-AI under a package is no page, a name under a namespace is redirected with its query', () => {
  expect(edge('/packages/Komira-AI/json')).toBe('/404.html');
  const out = viewerRequest(request('/packages/komira-ai/Foo__Bar', { a: { value: '1' } })) as Redirect;
  expect(out.statusCode).toBe(301);
  expect(out.headers.location.value).toBe('/packages/komira-ai/foo_bar?a=1');
});

test('a rewrite or a pass returns the request itself, with its query, method and headers untouched', () => {
  const qs = { cursor: { value: 'x' } };
  for (const [uri, want] of [['/search', '/app.html'], ['/nope', '/404.html'], ['/index.html', '/index.html']]) {
    const r = request(uri, qs);
    const out = viewerRequest(r) as Request;
    expect(out).toBe(r);
    expect(out).toEqual({ method: 'GET', uri: want, querystring: qs, headers: {} });
  }
});

test('a key the prototype of a plain object has is no file of the build', () => {
  const r = load(siteRouterSource(['/index.html', '/assets/0a1b2c3d4e5f6a7b/main.js']));
  for (const uri of ['/__proto__', '/constructor', '/hasOwnProperty', '/toString', '/assets/constructor/x.js']) {
    const out = r({ context: { eventType: 'viewer-request' }, request: request(uri) }) as Request;
    const want = uri.startsWith('/assets/') ? uri : '/404.html';
    expect([uri, out.uri]).toEqual([uri, want]);
  }
});

test('the router is generated from the build it serves: another build has other files and another asset id', () => {
  const other = load(siteRouterSource(['/404.html', '/index.html', '/assets/1111111111111111/main.js']));
  const run = (uri: string) => (other({ request: request(uri) }) as Request).uri;
  expect(run('/assets/1111111111111111/main.js')).toBe('/assets/1111111111111111/main.js');
  expect(run('/assets/1111111111111111/site.css')).toBe('/404.html');
  // This fixture's build id is an earlier build to that router, so its assets pass.
  expect(run('/assets/0a1b2c3d4e5f6a7b/nope.js')).toBe('/assets/0a1b2c3d4e5f6a7b/nope.js');
  expect(run('/docs/')).toBe('/404.html');
  expect(run('/app.html')).toBe('/404.html');
});

test('a router of exactly the size limit is accepted, one byte more is refused', () => {
  const base = Buffer.byteLength(siteRouterSource(['/a']));
  const fit = ['/' + 'a'.repeat(1 + FUNCTION_MAX_BYTES - base)];
  expect(Buffer.byteLength(siteRouterSource(fit))).toBe(FUNCTION_MAX_BYTES);
  expect(() => siteRouterSource([fit[0] + 'a'])).toThrow(
    `the edge router for this site build is ${FUNCTION_MAX_BYTES + 1} bytes; CloudFront Functions take at most ${FUNCTION_MAX_BYTES} (the build has 1 files)`,
  );
});

test('a build with assets under two ids checks both; any other id is an earlier build', () => {
  const r = load(siteRouterSource(['/index.html', '/assets/1111111111111111/main.js', '/assets/2222222222222222/site.css']));
  const run = (uri: string) => (r({ request: request(uri) }) as Request).uri;
  expect(run('/assets/1111111111111111/main.js')).toBe('/assets/1111111111111111/main.js');
  expect(run('/assets/2222222222222222/site.css')).toBe('/assets/2222222222222222/site.css');
  expect(run('/assets/1111111111111111/site.css')).toBe('/404.html');
  expect(run('/assets/2222222222222222/main.js')).toBe('/404.html');
  expect(run('/assets/3333333333333333/main.js')).toBe('/assets/3333333333333333/main.js');
  expect(run('/assets/3333333333333333/views/')).toBe('/404.html');
});

test("a missing key under an earlier build's id is the bucket's to answer: the function leaves its 403 alone", () => {
  // The router cannot know an earlier build's files; S3 answers 403 through OAC, and CloudFront runs no viewer function
  // on an origin status of 400 or more, so that visitor gets the bucket's 403.
  const uri = '/assets/ffffffffffffffff/never-built.js';
  expect(edge(uri)).toBe('pass');
  const res = response(403, { 'content-type': { value: 'application/xml' } });
  expect(viewerResponse(uri, res)).toEqual(response(403, { 'content-type': { value: 'application/xml' } }));
});

test('a build whose router would exceed the CloudFront Functions size limit is refused, naming the sizes', () => {
  const files = Array.from({ length: 400 }, (_, i) => `/assets/0a1b2c3d4e5f6a7b/module-${String(i).padStart(4, '0')}.js`);
  expect(() => siteRouterSource(files)).toThrow(
    new RegExp(`^the edge router for this site build is \\d+ bytes; CloudFront Functions take at most ${FUNCTION_MAX_BYTES} \\(the build has 400 files\\)$`),
  );
  expect(FUNCTION_MAX_BYTES).toBe(10240);
  expect(Buffer.byteLength(SOURCE)).toBeLessThanOrEqual(FUNCTION_MAX_BYTES);
});

test('the router names no host or stage, so every stage runs the same function for one build', () => {
  expect(SOURCE).not.toMatch(/mopm\.dev|https?:|\b(beta|gamma|prod)\b/);
});
