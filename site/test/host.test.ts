// T2: only the three site hostnames (and the local preview's) have an API, on the page's own origin under the relative
// /api/v2, and each its own channel; anything else gets no API (and no call).
import { client, type FetchFn } from '../src/api';
import { API_BASE, apiBase, condaBase, registryFlag } from '../src/host';

test.each([
  ['mopm.dev', 'https://conda.mopm.dev/'],
  ['beta.mopm.dev', 'https://conda.beta.mopm.dev/'],
  ['gamma.mopm.dev', 'https://conda.gamma.mopm.dev/'],
])('%s reads the API on its own origin, /api/v2, and has its own channel', (host, conda) => {
  expect(apiBase(host)).toBe('/api/v2');
  expect(API_BASE).toBe('/api/v2');
  expect(condaBase(host)).toBe(conda);
});

// The URL a page fetches is relative: no scheme, no host, so the browser sends it to the page's own origin, which the
// site distribution answers from the stage's API (/api/*). api.<site host> is never named.
test.each(['mopm.dev', 'beta.mopm.dev', 'gamma.mopm.dev', '127.0.0.1', 'localhost'])('%s: the fetch URL is relative', async (host) => {
  const urls: string[] = [];
  const fetchFn: FetchFn = async (url) => {
    urls.push(url);
    return new Response('{}', { status: 404 });
  };
  const api = client(fetchFn, apiBase(host)!);
  await api.getHealth();
  await api.getPackage({ namespace: 'komira-ai', name: 'json' });
  expect(urls).toEqual(['/api/v2/health', '/api/v2/packages/komira-ai/json']);
  for (const u of urls) {
    expect(u.startsWith('/api/v2/')).toBe(true);
    expect(u.startsWith('//')).toBe(false);
    expect(u).not.toContain('://');
  }
});

// A host that ends with the string 'mopm.dev' but is not under it: a suffix match without a dot boundary would accept
// it. No reserved name can end in 'mopm.dev', so it is built here rather than written out as a registrable domain; it
// is never fetched (apiBase and condaBase only look it up, and test/setup.ts makes the global fetch throw).
const SUFFIX_TRAP = 'evil' + 'mopm.dev';

test.each([
  SUFFIX_TRAP, // a suffix match would accept this
  'mopm.dev.', // trailing dot
  'www.mopm.dev', // not a site host (and not a CORS origin)
  'MOPM.DEV', // location.hostname is lowercase; anything else is not ours
  'api.mopm.dev',
  'conda.mopm.dev',
  'mopm.dev.example',
  'dev.mopm.dev',
  'localhost.',
  '127.0.0.2',
  '[::1]',
  '0.0.0.0',
  '',
  'constructor', // inherited Object keys must not count
  '__proto__',
  'toString',
])('%j has no API', (host) => {
  expect(apiBase(host)).toBeNull();
  expect(condaBase(host)).toBeNull();
  expect(registryFlag(host)).toBeNull();
});

// A command a page shows must reach the registry the page reads: mopm's default is prod, so mopm.dev needs no flag and
// the other two stages need theirs, spelled as `--registry` takes them (docs/configuration.md).
test.each([
  ['mopm.dev', null],
  ['beta.mopm.dev', 'beta'],
  ['gamma.mopm.dev', 'gamma'],
  ['127.0.0.1', null],
  ['localhost', null],
])('%s: the --registry its commands name is %p', (host, flag) => {
  expect(registryFlag(host)).toBe(flag);
});

test.each(['mopm.dev', 'beta.mopm.dev', 'gamma.mopm.dev'])('%s: the API base is version 2, the one with full names', (host) => {
  expect(apiBase(host)).toMatch(/\/api\/v2$/);
  expect(apiBase(host)).not.toContain('/api/v1');
});

// The local preview (tools/preview.ts) serves the built site on 127.0.0.1 and answers the API on that same origin.
test.each(['127.0.0.1', 'localhost'])('%s, the local preview, has the API on its own origin and no conda channel', (host) => {
  expect(apiBase(host)).toBe('/api/v2');
  expect(condaBase(host)).toBeNull();
});
