import { route } from '../../src/http/router';
import { ALICE, CAROL, DAVE, ERIN, createRig, type Rig } from '../publish/create-rig';

const NEWCO_ID = 300;
const NEWCO_INST = 6001;

async function rig(over: Parameters<typeof createRig>[0] = {}) {
  const r = createRig(over);
  await r.seed();
  r.gh.install(NEWCO_INST, { id: NEWCO_ID, login: 'newco' }).member('newco', 'dave', DAVE, 'admin').member('newco', 'carol', CAROL, 'member');
  return r;
}
const post = (r: Rig, token: string | undefined, body: string | undefined) => r.call('POST', '/api/v2/namespaces', token, body);
const parsed = (res: { statusCode: number; body: string }) => ({ status: res.statusCode, body: JSON.parse(res.body) });

describe('POST /api/v2/namespaces', () => {
  test('a fresh session of an admin creates the organization namespace: 201 with NamespaceInfo, and the row is bound to the installation', async () => {
    const r = await rig();
    const res = parsed(await post(r, await r.session(DAVE), '{"namespace":"newco"}'));
    expect(res).toEqual({ status: 201, body: { namespace: 'newco', kind: 'org', github_id: NEWCO_ID, login: 'newco', frozen: false } });
    expect(await r.namespaces.getNamespace('newco')).toMatchObject({ kind: 'org', github_id: NEWCO_ID, installation_id: NEWCO_INST });
  });

  test('the same request again is 200 with the same NamespaceInfo (held)', async () => {
    const r = await rig();
    const t = await r.session(DAVE);
    await post(r, t, '{"namespace":"newco"}');
    expect(parsed(await post(r, t, '{"namespace":"newco"}'))).toEqual({ status: 200, body: { namespace: 'newco', kind: 'org', github_id: NEWCO_ID, login: 'newco', frozen: false } });
  });

  test('a frozen namespace is rebound to a new installation of the same organization: 200, and no longer frozen', async () => {
    const r = await rig();
    expect(await r.access.info((await r.namespaces.getNamespace('frozen-org'))!)).toMatchObject({ frozen: true });
    r.gh.install(7001, { id: 88, login: 'frozen-org' }).member('frozen-org', 'dave', DAVE, 'admin');
    const res = parsed(await post(r, await r.session(DAVE), '{"namespace":"frozen-org"}'));
    expect(res).toEqual({ status: 200, body: { namespace: 'frozen-org', kind: 'org', github_id: 88, login: 'frozen-org', frozen: false } });
    expect((await r.namespaces.getNamespace('frozen-org'))!.installation_id).toBe(7001);
  });

  test('a member who is not an admin is refused with not_namespace_member', async () => {
    const r = await rig();
    const res = parsed(await post(r, await r.session(CAROL), '{"namespace":"newco"}'));
    expect(res.status).toBe(403);
    expect(res.body.error.code).toBe('not_namespace_member');
    expect(await r.namespaces.getNamespace('newco')).toBeUndefined();
  });

  test('an organization without the App installed is namespace_unverified', async () => {
    const r = await rig();
    const res = parsed(await post(r, await r.session(DAVE), '{"namespace":"nobody-org"}'));
    expect([res.status, res.body.error.code]).toEqual([403, 'namespace_unverified']);
  });

  test('a user namespace cannot be created this way', async () => {
    const r = await rig();
    const res = parsed(await post(r, await r.session(ALICE), '{"namespace":"alice"}'));
    expect([res.status, res.body.error.code]).toEqual([403, 'namespace_unverified']);
  });

  test.each([
    ['Newco', 400, 'invalid_namespace'],
    ['a_b', 400, 'invalid_namespace'],
    ['index', 403, 'namespace_reserved'],
  ])('the namespace %p is refused with %s', async (ns, status, code) => {
    const r = await rig();
    const res = parsed(await post(r, await r.session(DAVE), JSON.stringify({ namespace: ns })));
    expect([res.status, res.body.error.code]).toEqual([status, code]);
  });

  test('GitHub being down is unavailable', async () => {
    const r = await rig();
    r.gh.state.faults.push({ path: /./, reject: true });
    const res = parsed(await post(r, await r.session(DAVE), '{"namespace":"newco"}'));
    expect([res.status, res.body.error.code]).toEqual([503, 'unavailable']);
  });

  test('a stale session and an API token are stale_session; no token and an unknown token are refused by the authenticator', async () => {
    const r = await rig();
    expect(parsed(await post(r, await r.session(DAVE, false), '{"namespace":"newco"}')).body.error.code).toBe('stale_session');
    expect(parsed(await post(r, await r.api(DAVE, []), '{"namespace":"newco"}')).body.error.code).toBe('stale_session');
    expect(parsed(await post(r, undefined, '{"namespace":"newco"}')).body.error.code).toBe('token_missing');
    expect(parsed(await post(r, 'Bearer mopm_pat_nothing', '{"namespace":"newco"}')).body.error.code).toBe('token_unknown');
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
    expect(res.status).toBe(400);
    expect(res.body.error.code).toBe('invalid_request');
    expect(res.body.error.message).toBe(`The request is not valid: ${detail}.`);
    expect(await r.namespaces.getNamespace('newco')).toBeUndefined();
  });

  test('a deployment with no GitHub App answers unavailable', async () => {
    const r = await rig({ app: false });
    const res = parsed(await post(r, await r.session(DAVE), '{"namespace":"newco"}'));
    expect([res.status, res.body.error.code]).toEqual([503, 'unavailable']);
    expect(res.body.error.message).toBe('The registry is temporarily unavailable.');
  });

  test('a router with no auth services answers unavailable', async () => {
    const r = await rig();
    const res = await route({ method: 'POST', path: '/api/v2/namespaces', query: {}, headers: {}, body: '{"namespace":"newco"}' }, { ...r.deps, auth: undefined }, 'req-1');
    expect([res.statusCode, JSON.parse(res.body).error.code]).toEqual([503, 'unavailable']);
  });

  test('a member of nothing (no pass kept) still gets not_namespace_member, not a created namespace', async () => {
    const r = await rig();
    const res = parsed(await post(r, await r.session(ERIN), '{"namespace":"newco"}'));
    expect([res.status, res.body.error.code]).toEqual([403, 'not_namespace_member']);
  });
});
