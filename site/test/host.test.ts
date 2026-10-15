// T2: only the three site hostnames map to an API, each to its own; anything else gets no API (and no call).
import { apiBase, condaBase } from '../src/host';

test.each([
  ['mopm.dev', 'https://api.mopm.dev/api/v1', 'https://conda.mopm.dev/'],
  ['beta.mopm.dev', 'https://api.beta.mopm.dev/api/v1', 'https://conda.beta.mopm.dev/'],
  ['gamma.mopm.dev', 'https://api.gamma.mopm.dev/api/v1', 'https://conda.gamma.mopm.dev/'],
])('%s maps to its own API and channel', (host, api, conda) => {
  expect(apiBase(host)).toBe(api);
  expect(condaBase(host)).toBe(conda);
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
  'localhost',
  '',
  'constructor', // inherited Object keys must not count
  '__proto__',
  'toString',
])('%j has no API', (host) => {
  expect(apiBase(host)).toBeNull();
  expect(condaBase(host)).toBeNull();
});
