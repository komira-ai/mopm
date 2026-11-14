import { GitHubUnavailable, HttpGitHubApi, type FetchLike } from '../src/auth';
import { fakeGitHub, orgMembership } from './auth-helpers';

// HttpGitHubApi.getOrgMembership: `GET /user/memberships/orgs/{org}` with the caller's own token. A 404 and a 403 are "no such
// membership visible" (null); every other failure is GitHub being unavailable.

const api = (fetchFn: FetchLike) => new HttpGitHubApi('Iv1.testclientid', fetchFn);
const answering = (status: number, body: unknown): FetchLike => async () => ({ ok: status >= 200 && status < 300, status, json: async () => body });

describe('getOrgMembership', () => {
  test('reads state, role, the organization and the account from the membership, and sends the token as a bearer', async () => {
    const fake = fakeGitHub({ memberships: { 'acme-labs': { body: orgMembership({ id: 99, login: 'acme-labs' }, 'admin', 'active', 2002) } } });
    expect(await api(fake.fetchFn).getOrgMembership('gho_x', 'acme-labs')).toEqual({ state: 'active', role: 'admin', organization: { id: 99, login: 'acme-labs' }, user_id: 2002 });
    expect(fake.state.calls[0]).toMatchObject({ method: 'GET', url: 'https://api.github.com/user/memberships/orgs/acme-labs' });
    expect(fake.state.calls[0]!.headers.authorization).toBe('Bearer gho_x');
  });

  test('a membership that names no account has no user_id', async () => {
    const body = { state: 'pending', role: 'member', organization: { id: 5, login: 'o' }, user: null };
    expect(await api(answering(200, body)).getOrgMembership('t', 'o')).toEqual({ state: 'pending', role: 'member', organization: { id: 5, login: 'o' } });
  });

  test.each([404, 403])('GitHub answering %i is no visible membership', async (status) => {
    expect(await api(answering(status, { message: 'x' })).getOrgMembership('t', 'o')).toBeNull();
  });

  test.each([401, 429, 500, 502])('GitHub answering %i is GitHubUnavailable', async (status) => {
    await expect(api(answering(status, {})).getOrgMembership('t', 'o')).rejects.toBeInstanceOf(GitHubUnavailable);
  });

  test.each([
    ['not an object', 'text'],
    ['null', null],
    ['no organization', { state: 'active', role: 'admin' }],
    ['an organization id that is not a positive integer', { state: 'active', role: 'admin', organization: { id: 0, login: 'o' } }],
    ['an organization id that is a string', { state: 'active', role: 'admin', organization: { id: '9', login: 'o' } }],
    ['an empty organization login', { state: 'active', role: 'admin', organization: { id: 9, login: '' } }],
    ['no state', { role: 'admin', organization: { id: 9, login: 'o' } }],
    ['no role', { state: 'active', organization: { id: 9, login: 'o' } }],
  ])('an answer with %s is GitHubUnavailable', async (_why, body) => {
    await expect(api(answering(200, body)).getOrgMembership('t', 'o')).rejects.toBeInstanceOf(GitHubUnavailable);
  });

  test.each([
    ['the request is rejected', async () => Promise.reject(new TypeError('fetch failed'))],
    ['the body is not JSON', async () => ({ ok: true, status: 200, json: async () => JSON.parse('<html>') })],
  ])('%s: GitHubUnavailable', async (_why, fetchFn) => {
    await expect(api(fetchFn as FetchLike).getOrgMembership('t', 'o')).rejects.toBeInstanceOf(GitHubUnavailable);
  });

  test('the organization name is sent as one path segment', async () => {
    const fake = fakeGitHub();
    await api(fake.fetchFn).getOrgMembership('t', 'a/b');
    expect(fake.state.calls[0]!.url).toBe('https://api.github.com/user/memberships/orgs/a%2Fb');
  });
});
