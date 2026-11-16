import { AuthError } from '../../src/auth';
import { route } from '../../src/http/router';
import { orgMembership } from '../auth-helpers';
import { ALICE, BOB, CAROL, DAVE, ERIN, createRig, type Rig } from '../publish/create-rig';

// The namespace operations of /api/v2 through route(): the registration of an organization namespace (a device flow with
// read:org, then a poll), and the members of an organization namespace (list, set, remove). The rig has komira-ai with DAVE as
// its owner and CAROL as a member; ALICE and BOB have user namespaces.

const ORG_ID = 99;

async function rig() {
  const r = createRig();
  await r.seed();
  const at = r.clock.now().toISOString();
  for (const [id, handle] of [[CAROL, 'carol'], [DAVE, 'dave'], [ERIN, 'erin']] as const) {
    await r.authStore.upsertUser(id, handle, at, true);
    await r.namespaces.createNamespace({ namespace: handle, kind: 'user', github_id: id, created_at: at });
  }
  // The GitHub account that will approve is DAVE's, and it is an active admin of acme-labs.
  r.gh.state.user = { id: DAVE, login: 'dave', two_factor_authentication: true };
  r.gh.state.memberships['acme-labs'] = { body: orgMembership({ id: ORG_ID, login: 'acme-labs' }, 'admin', 'active', DAVE) };
  return r;
}
const parsed = (res: { statusCode: number; body: string }) => ({ status: res.statusCode, body: res.body === '' ? undefined : JSON.parse(res.body) });
const post = (r: Rig, token: string | undefined, body: string | undefined) => r.call('POST', '/api/v2/namespaces', token, body);
const poll = (r: Rig, token: string | undefined, device_code: string) => r.call('POST', '/api/v2/namespaces/poll', token, JSON.stringify({ device_code }));
const startAs = async (r: Rig, account: number, namespace = 'acme-labs') => {
  const res = parsed(await post(r, await r.session(account), JSON.stringify({ namespace })));
  expect(res.status).toBe(202);
  return res.body.device_code as string;
};
const members = (r: Rig, token: string | undefined, ns = 'komira-ai') => r.call('GET', `/api/v2/namespaces/${ns}/members`, token);
const put = (r: Rig, token: string | undefined, user: string, body: unknown, ns = 'komira-ai') => r.call('PUT', `/api/v2/namespaces/${ns}/members/${user}`, token, typeof body === 'string' ? body : JSON.stringify(body));
const del = (r: Rig, token: string | undefined, user: string, ns = 'komira-ai') => r.call('DELETE', `/api/v2/namespaces/${ns}/members/${user}`, token);

describe('POST /api/v2/namespaces (start the registration)', () => {
  test('a fresh session starts the registration: 202 with the device flow of GitHub, asked for read:org only', async () => {
    const r = await rig();
    const res = parsed(await post(r, await r.session(DAVE), '{"namespace":"acme-labs"}'));
    expect(res).toEqual({
      status: 202,
      body: { device_code: expect.stringMatching(/^dev_[0-9a-f]{48}$/), user_code: 'WDJB-MJHT', verification_uri: 'https://github.com/login/device', expires_in: 600, interval: 5 },
    });
    expect(new URLSearchParams(r.gh.state.calls[0]!.body).get('scope')).toBe('read:org');
    expect(await r.namespaces.getNamespace('acme-labs')).toBeUndefined();
  });

  test.each([
    ['Acme-Labs', 400, 'invalid_namespace'],
    ['a_b', 400, 'invalid_namespace'],
    ['index', 403, 'namespace_reserved'],
    ['poll', 403, 'namespace_reserved'],
    ['alice', 409, 'namespace_taken'],
    ['komira-ai', 409, 'namespace_taken'],
  ])('the namespace %p is refused with %s, and GitHub is not asked', async (ns, status, code) => {
    const r = await rig();
    const res = parsed(await post(r, await r.session(DAVE), JSON.stringify({ namespace: ns })));
    expect([res.status, res.body.error.code]).toEqual([status, code]);
    expect(r.gh.state.calls).toEqual([]);
  });

  test('an account with no user namespace is user_not_found 404 with its handle in lower case, and GitHub is not asked', async () => {
    const r = await rig();
    await r.authStore.upsertUser(5005, 'Enterprise_Login', r.clock.now().toISOString(), true);
    const res = parsed(await post(r, await r.session(5005), '{"namespace":"acme-labs"}'));
    expect([res.status, res.body.error.code, res.body.error.message]).toEqual([404, 'user_not_found', "There is no mopm user 'enterprise_login'."]);
    expect(r.gh.state.calls).toEqual([]);
  });

  test('a stale session and an API token are stale_session; no token and an unknown token are refused by the authenticator', async () => {
    const r = await rig();
    expect(parsed(await post(r, await r.session(DAVE, false), '{"namespace":"acme-labs"}')).body.error.code).toBe('stale_session');
    expect(parsed(await post(r, await r.api(DAVE, []), '{"namespace":"acme-labs"}')).body.error.code).toBe('stale_session');
    expect(parsed(await post(r, undefined, '{"namespace":"acme-labs"}')).body.error.code).toBe('token_missing');
    expect(parsed(await post(r, 'Bearer mopm_pat_nothing', '{"namespace":"acme-labs"}')).body.error.code).toBe('token_unknown');
    expect(r.gh.state.calls).toEqual([]);
  });

  test.each([
    ['no body', undefined, 'a JSON body is required'],
    ['not JSON', '{', 'the body is not valid JSON'],
    ['an array', '[]', 'the body must be a JSON object'],
    ['no namespace member', '{}', "'namespace' must be a string"],
    ['a namespace that is not a string', '{"namespace":7}', "'namespace' must be a string"],
  ])('%s is invalid_request', async (_label, body, detail) => {
    const r = await rig();
    const res = parsed(await post(r, await r.session(DAVE), body));
    expect([res.status, res.body.error.code, res.body.error.message]).toEqual([400, 'invalid_request', `The request is not valid: ${detail}.`]);
  });

  test('the OAuth app secret being absent is unavailable', async () => {
    const r = await rig();
    const down = { ...r.deps, auth: { ...r.deps.auth!, registration: async () => { throw new AuthError('unavailable', 'x'); } } }; // prettier-ignore
    const res = await route({ method: 'POST', path: '/api/v2/namespaces', query: {}, headers: { authorization: await r.session(DAVE) }, body: '{"namespace":"acme-labs"}' }, down, 'req-1');
    expect(parsed(res)).toMatchObject({ status: 503, body: { error: { code: 'unavailable' } } });
  });

  test('a router with no auth services answers unavailable', async () => {
    const r = await rig();
    const res = await route({ method: 'POST', path: '/api/v2/namespaces', query: {}, headers: {}, body: '{"namespace":"acme-labs"}' }, { ...r.deps, auth: undefined }, 'req-1');
    expect([res.statusCode, JSON.parse(res.body).error.code]).toEqual([503, 'unavailable']);
  });
});

describe('POST /api/v2/namespaces/poll', () => {
  test('an approved registration by an active admin of the organization: 200 created with NamespaceInfo, and the registrant is its owner', async () => {
    const r = await rig();
    const code = await startAs(r, DAVE);
    const res = parsed(await poll(r, await r.session(DAVE), code));
    expect(res).toEqual({ status: 200, body: { status: 'created', namespace: { namespace: 'acme-labs', kind: 'org', github_id: ORG_ID, login: 'acme-labs' } } });
    expect(parsed(await r.call('GET', '/api/v2/namespaces/acme-labs')).body).toEqual({ namespace: 'acme-labs', kind: 'org', github_id: ORG_ID, login: 'acme-labs' });
    expect(parsed(await members(r, await r.session(DAVE), 'acme-labs')).body.members).toEqual([
      { user: 'dave', handle: 'dave', github_id: DAVE, role: 'owner', added_at: r.clock.now().toISOString() },
    ]);
    // The registrant publishes there at once; nothing else asked GitHub about the organization after the poll.
    expect(r.gh.state.calls.filter((c) => c.url.includes('/user/memberships/orgs'))).toHaveLength(1);
  });

  test('any token of the account that started the flow polls it, an API token included', async () => {
    const r = await rig();
    const code = await startAs(r, DAVE);
    expect(parsed(await poll(r, await r.api(DAVE, []), code)).body.status).toBe('created');
  });

  test('while the person has not decided: pending with the interval', async () => {
    const r = await rig();
    r.gh.state.pollScript = [{ error: 'authorization_pending' }];
    const code = await startAs(r, DAVE);
    expect(parsed(await poll(r, await r.session(DAVE), code))).toEqual({ status: 200, body: { status: 'pending', interval: 5 } });
  });

  test('a plain member of the organization approving is not_org_admin with the exact text; nothing is created', async () => {
    const r = await rig();
    r.gh.state.memberships['acme-labs'] = { body: orgMembership({ id: ORG_ID, login: 'acme-labs' }, 'member', 'active', DAVE) };
    const code = await startAs(r, DAVE);
    const res = parsed(await poll(r, await r.session(DAVE), code));
    expect(res.status).toBe(403);
    expect(res.body.error).toEqual({
      code: 'not_org_admin',
      message: "You are not an active admin of the GitHub organization 'acme-labs'.",
      hint: "An admin of the GitHub organization runs 'mopm org create acme-labs'; an organization that restricts OAuth apps approves the mopm registry first.",
    });
    expect(await r.namespaces.getNamespace('acme-labs')).toBeUndefined();
  });

  test('another GitHub account approving is github_account_mismatch', async () => {
    const r = await rig();
    r.gh.state.user = { id: 9999, login: 'mallory', two_factor_authentication: true };
    const code = await startAs(r, DAVE);
    expect(parsed(await poll(r, await r.session(DAVE), code)).body.error.code).toBe('github_account_mismatch');
  });

  test('another account of mopm polling the code is device_code_unknown, and the owner can still finish', async () => {
    const r = await rig();
    const code = await startAs(r, DAVE);
    expect(parsed(await poll(r, await r.session(ALICE), code)).body.error.code).toBe('device_code_unknown');
    expect(parsed(await poll(r, await r.session(DAVE), code)).body.status).toBe('created');
  });

  test('no token is token_missing; a body with no device code is device_code_unknown', async () => {
    const r = await rig();
    expect(parsed(await poll(r, undefined, 'x'.repeat(20))).body.error.code).toBe('token_missing');
    const res = parsed(await r.call('POST', '/api/v2/namespaces/poll', await r.session(DAVE), '{}'));
    expect([res.status, res.body.error.code]).toEqual([404, 'device_code_unknown']);
  });

  test('GET /namespaces/poll is a read of the reserved namespace `poll`, not the operation', async () => {
    const r = await rig();
    expect(parsed(await r.call('GET', '/api/v2/namespaces/poll')).body.error.code).toBe('namespace_reserved');
  });
});

describe('GET /api/v2/namespaces/{namespace}/members', () => {
  test('an owner and a member read the list: users, handles, roles', async () => {
    const r = await rig();
    const at = '2026-10-01T00:00:00.000Z';
    const want = {
      namespace: 'komira-ai',
      members: [
        { user: 'carol', handle: 'carol', github_id: CAROL, role: 'member', added_at: at },
        { user: 'dave', handle: 'dave', github_id: DAVE, role: 'owner', added_at: at },
      ],
    };
    expect(parsed(await members(r, await r.session(DAVE)))).toEqual({ status: 200, body: want });
    expect(parsed(await members(r, await r.api(CAROL, []))).body).toEqual(want);
  });

  test('an account outside the namespace is not_namespace_member with the hint naming the namespace', async () => {
    const r = await rig();
    const res = parsed(await members(r, await r.session(ERIN)));
    expect([res.status, res.body.error.code, res.body.error.hint]).toEqual([403, 'not_namespace_member', "Ask an owner of 'komira-ai' to run 'mopm org add komira-ai <your mopm username>'."]);
  });

  test('a user namespace has no members: invalid_request; no token: token_missing', async () => {
    const r = await rig();
    const res = parsed(await members(r, await r.session(ALICE), 'alice'));
    expect([res.status, res.body.error.code, res.body.error.message]).toEqual([400, 'invalid_request', "The request is not valid: 'alice' is a user namespace; it has no members."]);
    expect(parsed(await members(r, undefined)).body.error.code).toBe('token_missing');
  });
});

describe('PUT and DELETE /api/v2/namespaces/{namespace}/members/{user}', () => {
  test('add: 201 with the member; change of role: 200; the same role: 200', async () => {
    const r = await rig();
    const owner = await r.session(DAVE);
    const at = r.clock.now().toISOString();
    expect(parsed(await put(r, owner, 'bob', { role: 'member' }))).toEqual({ status: 201, body: { user: 'bob', handle: 'bob', github_id: BOB, role: 'member', added_at: at } });
    expect(parsed(await put(r, owner, 'bob', { role: 'owner' })).status).toBe(200);
    const same = parsed(await put(r, owner, 'bob', { role: 'owner' }));
    expect([same.status, same.body.role]).toEqual([200, 'owner']);
  });

  test('remove: 204 with no body; a second remove is member_not_found', async () => {
    const r = await rig();
    const owner = await r.session(DAVE);
    const res = await del(r, owner, 'carol');
    expect([res.statusCode, res.body]).toEqual([204, '']);
    const again = parsed(await del(r, owner, 'carol'));
    expect([again.status, again.body.error.code]).toEqual([404, 'member_not_found']);
  });

  test('a stale session and an API token are stale_session for both; a member is not_namespace_owner for both', async () => {
    const r = await rig();
    for (const t of [await r.session(DAVE, false), await r.api(DAVE, [])]) {
      expect(parsed(await put(r, t, 'bob', { role: 'member' })).body.error.code).toBe('stale_session');
      expect(parsed(await del(r, t, 'carol')).body.error.code).toBe('stale_session');
    }
    const member = await r.session(CAROL);
    expect(parsed(await put(r, member, 'bob', { role: 'member' })).body.error.code).toBe('not_namespace_owner');
    expect(parsed(await del(r, member, 'carol')).body.error.code).toBe('not_namespace_owner');
    expect(await r.namespaces.getMember('komira-ai', BOB)).toBeUndefined();
  });

  test('the last owner is kept: demoting or removing the only owner is last_owner (409)', async () => {
    const r = await rig();
    const owner = await r.session(DAVE);
    const demote = parsed(await put(r, owner, 'dave', { role: 'member' }));
    expect([demote.status, demote.body.error.code, demote.body.error.message]).toEqual([409, 'last_owner', "'dave' is the last owner of 'komira-ai'."]);
    expect(parsed(await del(r, owner, 'dave')).status).toBe(409);
    await put(r, owner, 'carol', { role: 'owner' });
    expect((await del(r, owner, 'dave')).statusCode).toBe(204);
  });

  test('an account with no mopm username, or an organization name, is user_not_found; a role that is not one is invalid_request', async () => {
    const r = await rig();
    const owner = await r.session(DAVE);
    expect(parsed(await put(r, owner, 'ghost', { role: 'member' })).body.error.code).toBe('user_not_found');
    expect(parsed(await put(r, owner, 'komira-ai', { role: 'member' })).body.error.code).toBe('user_not_found');
    expect(parsed(await del(r, owner, 'ghost')).body.error.code).toBe('user_not_found');
    expect(parsed(await put(r, owner, 'bob', { role: 'admin' })).body.error.code).toBe('invalid_request');
    expect(parsed(await put(r, owner, 'bob', '{')).body.error.code).toBe('invalid_request');
  });

  test('a member removed in one request cannot create a package in the very next, and nothing asks GitHub', async () => {
    const r = await rig();
    const fetchSpy = jest.spyOn(globalThis, 'fetch');
    try {
      const carol = await r.session(CAROL);
      expect((await r.call('PUT', '/api/v2/packages/komira-ai/json', carol)).statusCode).toBe(201);
      expect((await del(r, await r.session(DAVE), 'carol')).statusCode).toBe(204);
      const res = parsed(await r.call('PUT', '/api/v2/packages/komira-ai/yaml', carol));
      expect([res.status, res.body.error.code, res.body.error.message]).toEqual([403, 'not_namespace_member', "You cannot write in 'komira-ai'."]);
      expect(await r.registry.getPackage('komira-ai/yaml')).toBeUndefined();
      expect(r.gh.state.calls).toEqual([]);
      expect(fetchSpy).not.toHaveBeenCalled();
    } finally {
      fetchSpy.mockRestore();
    }
  });

  test('a member added in one request writes in the next', async () => {
    const r = await rig();
    expect((await put(r, await r.session(DAVE), 'bob', { role: 'member' })).statusCode).toBe(201);
    expect((await r.call('PUT', '/api/v2/packages/komira-ai/json', await r.session(BOB))).statusCode).toBe(201);
  });
});
