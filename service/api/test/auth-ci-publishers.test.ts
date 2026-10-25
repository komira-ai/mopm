import { ALLOWED_EVENTS, CI_EVENTS, CI_PUBLISHERS_ENV, ciOwnerOf, matchesCiPublisher, parseCiPublishers, type GithubActionsClaims } from '../src/auth';
import { configureAuth } from '../src/http/lambda';
import { FakeAuthDoc } from './auth-fake-doc';

// The CI_PUBLISHERS variable: what the code accepts, and that it refuses to load anywhere but beta.

const ENTRY = {
  repository_id: '1376408823',
  repository_owner_id: '305577347',
  workflow: '.github/workflows/release.yml',
  ref: 'refs/heads/main',
  events: ['push', 'workflow_dispatch'],
  environment: 'beta',
};
const json = (v: unknown) => JSON.stringify(v);

describe('parseCiPublishers: the stage gate', () => {
  test('absent or empty is no publishers, on every stage', () => {
    for (const stage of ['beta', 'gamma', 'prod']) {
      expect(parseCiPublishers(stage, undefined)).toEqual([]);
      expect(parseCiPublishers(stage, '')).toEqual([]);
    }
  });

  test('beta loads a valid value', () => {
    expect(parseCiPublishers('beta', json([ENTRY]))).toEqual([ENTRY]);
    expect(ciOwnerOf('1376408823')).toBe('gh-repo:1376408823');
  });

  test.each(['gamma', 'prod', 'dev', 'Beta', ''])('stage %j refuses to load a value, even a valid one and even an empty list', (stage) => {
    expect(() => parseCiPublishers(stage, json([ENTRY]))).toThrow(/beta stage only/);
    expect(() => parseCiPublishers(stage, '[]')).toThrow(/beta stage only/);
  });
});

describe('parseCiPublishers: a malformed value is refused whole', () => {
  const cases: Array<[string, string]> = [
    ['not JSON', '{'],
    ['an object, not an array', json(ENTRY)],
    ['an empty list', '[]'],
    ['too many entries', json(Array.from({ length: 9 }, (_x, i) => ({ ...ENTRY, repository_id: String(100 + i) })))],
    ['an entry that is not an object', json(['x'])],
    ['an unknown key', json([{ ...ENTRY, branches: ['*'] }])],
    ['a missing environment', json([{ ...ENTRY, environment: undefined }])],
    ['a missing ref', json([{ ...ENTRY, ref: undefined }])],
    ['a numeric repository_id', json([{ ...ENTRY, repository_id: 1376408823 }])],
    ['a repository_id with a leading zero', json([{ ...ENTRY, repository_id: '0123' }])],
    ['a repository name instead of an id', json([{ ...ENTRY, repository_id: 'komira-ai/komira' }])],
    ['a non-numeric owner id', json([{ ...ENTRY, repository_owner_id: 'komira-ai' }])],
    ['a workflow outside .github/workflows', json([{ ...ENTRY, workflow: 'release.yml' }])],
    ['a workflow that names a ref', json([{ ...ENTRY, workflow: '.github/workflows/release.yml@refs/heads/main' }])],
    ['a wildcard ref', json([{ ...ENTRY, ref: 'refs/heads/*' }])],
    ['a ref that is not a full ref', json([{ ...ENTRY, ref: 'main' }])],
    ['no events', json([{ ...ENTRY, events: [] }])],
    ['an event that is not allowed', json([{ ...ENTRY, events: ['pull_request'] }])],
    ['a repeated event', json([{ ...ENTRY, events: ['push', 'push'] }])],
    ['an environment with a wildcard', json([{ ...ENTRY, environment: '*' }])],
    ['the same repository twice', json([ENTRY, ENTRY])],
  ];
  test.each(cases)('%s', (_n, raw) => {
    expect(() => parseCiPublishers('beta', raw)).toThrow(new RegExp(`${CI_PUBLISHERS_ENV} is not valid`));
  });

  test('the events a configuration may name are exactly the events the exchange allows', () => {
    expect([...CI_EVENTS]).toEqual([...ALLOWED_EVENTS]);
  });
});

describe('matchesCiPublisher', () => {
  const claims: GithubActionsClaims = {
    iss: 'i',
    aud: 'a',
    exp: 1,
    iat: 1,
    repository: 'komira-ai/komira',
    repository_id: '1376408823',
    repository_owner_id: '305577347',
    workflow_ref: 'komira-ai/komira/.github/workflows/release.yml@refs/heads/main',
    ref: 'refs/heads/main',
    event_name: 'push',
    jti: 'j',
    environment: 'beta',
  };
  test('the identity matches; each field that differs does not', () => {
    expect(matchesCiPublisher(ENTRY, claims)).toBe(true);
    const diffs: Array<Partial<GithubActionsClaims>> = [
      { repository_id: '1' },
      { repository_owner_id: '1' },
      { workflow_ref: 'komira-ai/komira/.github/workflows/x.yml@refs/heads/main' },
      { ref: 'refs/heads/dev' },
      { environment: 'prod' },
      { environment: undefined },
      { event_name: 'pull_request' },
    ];
    for (const d of diffs) expect(matchesCiPublisher(ENTRY, { ...claims, ...d })).toBe(false);
  });
  test('an event the publisher does not list, though the exchange allows it, does not match', () => {
    expect(matchesCiPublisher({ ...ENTRY, events: ['workflow_dispatch'] }, claims)).toBe(false);
  });
});

describe('configureAuth: the stage gate in the handler wiring', () => {
  const doc = new FakeAuthDoc({});
  const env = (extra: Record<string, string> = {}) => ({ MOPM_OAUTH_SECRET_NAME: 'mopm/x/github-oauth', ...extra });

  test('gamma and prod refuse to start with CI_PUBLISHERS set (a mistake in the infrastructure cannot turn the trust on there)', () => {
    for (const stage of ['gamma', 'prod'] as const) {
      expect(() => configureAuth(stage, doc, env({ [CI_PUBLISHERS_ENV]: json([ENTRY]) }))).toThrow(/beta stage only/);
      // even when auth is not otherwise wired
      expect(() => configureAuth(stage, doc, { [CI_PUBLISHERS_ENV]: json([ENTRY]) })).toThrow(/beta stage only/);
    }
  });

  test('beta wires the exchange with the configured publisher; a malformed value stops the function', () => {
    expect(configureAuth('beta', doc, env({ [CI_PUBLISHERS_ENV]: json([ENTRY]) }))!.oidc).toBeDefined();
    expect(() => configureAuth('beta', doc, env({ [CI_PUBLISHERS_ENV]: '[{}]' }))).toThrow(/is not valid/);
  });

  test('gamma and prod without the variable are wired as before', () => {
    for (const stage of ['gamma', 'prod'] as const) expect(configureAuth(stage, doc, env())!.oidc).toBeDefined();
  });
});
