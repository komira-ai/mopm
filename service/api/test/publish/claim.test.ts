import * as path from 'path';
import { mintToken } from '../../src/auth';
import { route } from '../../src/http/router';
import { MemoryStore } from '../../src/memory-store';
import { CLAIM_TTL_MS, ClaimService, claimLapsed, RESERVED_NAMES, tooSimilar } from '../../src/publish/claim';
import { DEFAULT_PUBLISH_CONFIG } from '../../src/publish/config';
import { MemoryPublishStore } from '../../src/publish/memory';
import { CONTRACT_DIR, loadCases, type Case } from '../http/replay';
import { publishApiFor } from '../../src/publish/wiring';
import { FakeDocClient } from '../helpers';
import { Harness, MutableFlags, pkg } from './harness';

const err = (r: { body: string }) => JSON.parse(r.body).error as { code: string; message: string; hint: string };
const claim = (h: Harness, token: string | undefined, name: string, body?: unknown) => h.call('POST', `/api/v1/packages/${name}/claim`, token, body);

/** An account with a row in the users table and an API token (an account's token, whatever its packages: it has none yet). */
async function account(h: Harness, id = 7, handle = 'octocat'): Promise<string> {
  await h.authStore.upsertUser(id, handle, h.clock.now().toISOString());
  return h.token(id, [], ['publish']);
}

const existing = (h: Harness, name: string) => h.registry.createPackage({ name, state: 'active', created_at: '2026-10-01T09:00:00Z' });
const nothingCreated = async (h: Harness, name: string) => {
  expect(await h.registry.getPackage(name)).toBeUndefined();
  expect(await h.registry.listOwners(name)).toEqual([]);
  expect(await h.registry.listAudit(name)).toEqual([]);
};

describe('the contract cases of claimPackage (tests/contract/api), replayed against the route', () => {
  const cases = ['packages.json', 'errors.json'].flatMap((f) => loadCases(path.join(CONTRACT_DIR, f))).filter((c) => c.operationId === 'claimPackage');
  const SETUP: Record<string, (h: Harness) => Promise<void>> = {
    'claim with no body': async () => undefined,
    'claim a similar name on purpose': (h) => existing(h, 'http_client'),
    'error name_reserved': async () => undefined,
    'error name_taken': (h) => existing(h, 'http_client'),
    'error name_too_similar': (h) => existing(h, 'http_client'),
  };

  test('every claim case of the contract has a setup here, and the cases were found', () => {
    expect(cases.map((c) => c.name).sort()).toEqual(Object.keys(SETUP).sort());
  });

  test.each(cases.map((c) => [c.name, c] as [string, Case]))('%s', async (_name, c) => {
    const h = new Harness();
    h.clock.t = Date.parse('2026-10-13T12:00:00Z'); // the examples' claim_expires_at is 30 days after this
    await SETUP[c.name]!(h);
    const res = await claim(h, await account(h), c.request.path!.name!, c.request.body);
    expect(res.statusCode).toBe(c.response.status);
    expect(JSON.parse(res.body)).toEqual(c.response.body);
    expect(res.headers).toMatchObject({ 'content-type': 'application/json', 'cache-control': 'no-store', 'x-mopm-request-id': 'req-1' });
  });
});

describe('a claim', () => {
  test('creates the package as claimed, its first owner (id and handle of the account) and an audit entry, and is answered 201 with the expiry 30 days out', async () => {
    const h = new Harness();
    const token = await account(h, 7, 'octocat');
    const res = await claim(h, token, 'komira_hash');
    expect(res.statusCode).toBe(201);
    expect(JSON.parse(res.body)).toEqual({ name: 'komira_hash', state: 'claimed', claim_expires_at: '2026-11-13T12:00:00Z' });
    expect(CLAIM_TTL_MS).toBe(30 * 24 * 3600_000);
    expect(await h.registry.getPackage('komira_hash')).toEqual({ name: 'komira_hash', state: 'claimed', created_at: '2026-10-14T12:00:00Z', claim_expires_at: '2026-11-13T12:00:00Z' });
    expect(await h.registry.listOwners('komira_hash')).toEqual([{ name: 'komira_hash', github_id: 7, handle: 'octocat', added_at: '2026-10-14T12:00:00Z' }]);
    expect(await h.registry.listAudit('komira_hash')).toEqual([{ name: 'komira_hash', ts: '2026-10-14T12:00:00Z', id: 'a_claim0001', actor: 'u:7', action: 'claim' }]);
  });

  test('the claimed package is then what the read API shows: state claimed, the claimant its owner, nothing published', async () => {
    const h = new Harness();
    await claim(h, await account(h, 7, 'octocat'), 'komira_hash');
    const info = JSON.parse((await h.call('GET', '/api/v1/packages/komira_hash')).body);
    expect(info).toMatchObject({ name: 'komira_hash', state: 'claimed', owners: [{ github_id: 7, handle: 'octocat' }], latest: null, versions: [] });
    expect(Object.keys(info)).not.toContain('claim_expires_at'); // the stored member never reaches the read API
  });

  test('the claimant is an owner the publish side recognises: begin-upload for the name is accepted', async () => {
    const h = new Harness();
    await claim(h, await account(h, 7, 'octocat'), 'demo');
    const token = await h.token(7, ['demo'], ['publish']);
    const u = await h.upload(token, pkg({ name: 'demo', version: '1.0.0' }));
    expect(u.res.statusCode).toBe(200);
  });

  test('a second claim of the name is refused with name_taken, by the same account and by another, and changes nothing', async () => {
    const h = new Harness();
    const first = await account(h, 7, 'octocat');
    const other = await account(h, 8, 'hubot');
    expect((await claim(h, first, 'taken_name')).statusCode).toBe(201);
    for (const token of [first, other]) {
      const res = await claim(h, token, 'taken_name');
      expect([res.statusCode, err(res).code, err(res).message]).toEqual([409, 'name_taken', "'taken_name' is already taken."]);
    }
    expect((await h.registry.listOwners('taken_name')).map((o) => o.github_id)).toEqual([7]);
    expect(await h.registry.listAudit('taken_name')).toHaveLength(1);
  });

  test('two accounts claiming one name at once: one gets 201, the other name_taken, and the name has exactly one owner', async () => {
    const h = new Harness();
    const [a, b] = [await account(h, 7, 'octocat'), await account(h, 8, 'hubot')];
    const results = await Promise.all([claim(h, a, 'racer'), claim(h, b, 'racer')]);
    expect(results.map((r) => r.statusCode).sort()).toEqual([201, 409]);
    expect(err(results.find((r) => r.statusCode === 409)!).code).toBe('name_taken');
    const owners = await h.registry.listOwners('racer');
    expect(owners).toHaveLength(1);
    expect(await h.registry.listAudit('racer')).toHaveLength(1);
    expect(JSON.parse(results.find((r) => r.statusCode === 201)!.body).name).toBe('racer');
    expect([7, 8]).toContain(owners[0]!.github_id);
  });

  test('a login session token claims too', async () => {
    const h = new Harness();
    await h.authStore.upsertUser(9, 'login_user', h.clock.now().toISOString());
    const t = h.clock.now();
    const session = await mintToken(h.authStore, {
      kind: 'session',
      github_id: 9,
      name: 'login',
      scopes: [],
      packages: [],
      all_current: false,
      created_at: t.toISOString(),
      expires_at: new Date(t.getTime() + 3600_000).toISOString(),
    });
    expect((await claim(h, session.secret, 'by_session')).statusCode).toBe(201);
    expect((await h.registry.listOwners('by_session')).map((o) => o.handle)).toEqual(['login_user']);
  });
});

describe('the first published version ends the claim', () => {
  const READ = async (h: Harness, name: string) => JSON.parse((await h.call('GET', `/api/v1/packages/${name}`)).body);

  test('a package an account claimed stays claimed while its publish is validated, and is active once the version is published; the owner and the version are kept', async () => {
    const h = new Harness();
    await claim(h, await account(h, 7, 'octocat'), 'demo');
    const token = await h.token(7, ['demo'], ['publish']);
    const id = await h.publish(token, pkg({ name: 'demo', version: '1.0.0' }));
    expect(await READ(h, 'demo')).toMatchObject({ state: 'claimed', latest: null });
    await h.runValidator();
    await h.runIndexer();
    expect((await h.status(token, id)).body.status).toBe('published');
    expect(await READ(h, 'demo')).toMatchObject({ state: 'active', owners: [{ github_id: 7, handle: 'octocat' }], latest: '1.0.0' });
    expect(await h.registry.getPackage('demo')).toEqual({ name: 'demo', state: 'active', created_at: '2026-10-14T12:00:00Z' });
  });

  test('a second version changes nothing about the package', async () => {
    const h = new Harness();
    await claim(h, await account(h, 7, 'octocat'), 'demo');
    const token = await h.token(7, ['demo'], ['publish']);
    await h.publish(token, pkg({ name: 'demo', version: '1.0.0' }));
    await h.runValidator();
    const once = await h.registry.getPackage('demo');
    await h.publish(token, pkg({ name: 'demo', version: '1.0.1' }));
    await h.runValidator();
    expect(await h.registry.getPackage('demo')).toEqual(once);
    expect(once?.state).toBe('active');
  });

  test('activatePackage: claimed becomes active and loses its expiry once; active, missing and expiry-less names are left alone', async () => {
    const r = new MemoryStore();
    await r.createPackage({ name: 'a_pkg', state: 'claimed', created_at: '2026-10-01T00:00:00Z', claim_expires_at: '2026-10-31T00:00:00Z' });
    expect(await r.activatePackage('a_pkg')).toBe(true);
    expect(await r.getPackage('a_pkg')).toEqual({ name: 'a_pkg', state: 'active', created_at: '2026-10-01T00:00:00Z' });
    expect(await r.activatePackage('a_pkg')).toBe(false);
    expect(await r.activatePackage('nobody')).toBe(false);
  });

  test('a claim lapses only while it is claimed and past its expiry: an active package never does, however old', () => {
    const at = new Date('2027-06-01T00:00:00Z');
    const expires = '2026-11-13T12:00:00Z';
    expect(claimLapsed({ state: 'claimed', claim_expires_at: expires }, at)).toBe(true);
    expect(claimLapsed({ state: 'claimed', claim_expires_at: expires }, new Date('2026-11-13T11:59:59Z'))).toBe(false);
    expect(claimLapsed({ state: 'active', claim_expires_at: expires }, at)).toBe(false);
    expect(claimLapsed({ state: 'active' }, at)).toBe(false);
    expect(claimLapsed({ state: 'claimed' }, at)).toBe(false); // a CI-created package records no expiry
  });

  test('a package published after its claim was made does not lapse 30 days later', async () => {
    const h = new Harness();
    await claim(h, await account(h, 7, 'octocat'), 'demo');
    const token = await h.token(7, ['demo'], ['publish']);
    await h.publish(token, pkg({ name: 'demo', version: '1.0.0' }));
    await h.runValidator();
    const later = new Date(h.clock.t + CLAIM_TTL_MS + 1000);
    expect(claimLapsed((await h.registry.getPackage('demo'))!, later)).toBe(false);
  });
});

describe('who may claim', () => {
  test('no token, a malformed token and an unknown token are 401 and create nothing', async () => {
    const h = new Harness();
    const none = await claim(h, undefined, 'abc');
    expect([none.statusCode, err(none).code]).toEqual([401, 'token_missing']);
    expect(err(await claim(h, 'not-a-token', 'abc')).code).toBe('token_unknown');
    expect(err(await claim(h, `mopm_${'a'.repeat(40)}`, 'abc')).code).toBe('token_unknown');
    await nothingCreated(h, 'abc');
  });

  test('a CI identity token is nobody: scope_missing for the user scope, and nothing is created', async () => {
    const h = new Harness();
    const t = h.clock.now();
    const ci = await mintToken(h.authStore, {
      kind: 'oidc',
      name: 'ci',
      scopes: ['publish'],
      packages: ['abc'],
      all_current: false,
      version: '1.0.0',
      created_at: t.toISOString(),
      expires_at: new Date(t.getTime() + 15 * 60_000).toISOString(),
      issued_to: 'example/repo',
    });
    const res = await claim(h, ci.secret, 'abc');
    expect([res.statusCode, err(res).code]).toEqual([403, 'scope_missing']);
    expect(err(res).message).toBe("The token does not have the 'user' scope for 'this account'.");
    await nothingCreated(h, 'abc');
  });

  test('a revoked token is 401 token_revoked and an expired one token_expired', async () => {
    const h = new Harness();
    const token = await account(h);
    const [rec] = await h.authStore.listTokens(7);
    await h.authStore.revokeToken(rec!.hash, '2026-10-14T12:00:00Z');
    expect(err(await claim(h, token, 'abc')).code).toBe('token_revoked');
    const h2 = new Harness();
    const token2 = await account(h2);
    h2.clock.advance(25 * 3600_000);
    expect(err(await claim(h2, token2, 'abc')).code).toBe('token_expired');
  });

  test('a token whose account has no row in the users table is token_unknown, and nothing is created', async () => {
    const h = new Harness();
    const token = await h.token(99, [], ['publish']); // no upsertUser
    const res = await claim(h, token, 'abc');
    expect([res.statusCode, err(res).code]).toEqual([401, 'token_unknown']);
    await nothingCreated(h, 'abc');
  });

  test('the token is checked before the name: a bad name without a token is 401, not 400', async () => {
    const h = new Harness();
    expect(err(await claim(h, undefined, 'Bad')).code).toBe('token_missing');
  });
});

describe('read-only mode', () => {
  test('refuses a claim with read_only_mode (503), even for a good token, and creates nothing; the same claim goes through once it is off', async () => {
    const h = new Harness();
    const token = await account(h);
    h.flags.ro = true;
    const res = await claim(h, token, 'abc');
    expect([res.statusCode, err(res).code]).toEqual([503, 'read_only_mode']);
    await nothingCreated(h, 'abc');
    h.flags.ro = false;
    expect((await claim(h, token, 'abc')).statusCode).toBe(201);
  });

  test('a switch that cannot be read fails closed: unavailable (503), nothing created', async () => {
    const h = new Harness();
    const token = await account(h);
    h.flags.broken = true;
    const res = await claim(h, token, 'abc');
    expect([res.statusCode, err(res).code]).toEqual([503, 'unavailable']);
    await nothingCreated(h, 'abc');
  });
});

describe('the name', () => {
  test.each([['Bad'], ['a'], ['1abc'], ['has-dash'], ['has.dot'], ['x'.repeat(65)], ['white%20space']])('%s is invalid_name (400) and creates nothing', async (name) => {
    const h = new Harness();
    const res = await claim(h, await account(h), name);
    expect([res.statusCode, err(res).code]).toEqual([400, 'invalid_name']);
    expect(await h.registry.listPackageNames()).toEqual([]);
  });

  test('the shortest and the longest valid names are claimed', async () => {
    const h = new Harness();
    const token = await account(h);
    for (const name of ['ab', `z${'9'.repeat(63)}`]) expect((await claim(h, token, name)).statusCode).toBe(201);
  });

  test.each([...RESERVED_NAMES])('%s is reserved: name_reserved (403), even with confirm_similar, and creates nothing', async (name) => {
    const h = new Harness();
    const res = await claim(h, await account(h), name, { confirm_similar: true });
    expect([res.statusCode, err(res).code, err(res).message]).toEqual([403, 'name_reserved', `'${name}' is reserved.`]);
    await nothingCreated(h, name);
  });

  test('the reserved names are the six the fake registry holds', () => {
    expect([...RESERVED_NAMES].sort()).toEqual(['max', 'modular', 'mojo', 'mopm', 'std', 'stdlib']);
  });
});

describe('the body', () => {
  test.each([
    ['none', undefined],
    ['an empty object', {}],
    ['an object with other members (ignored)', { other: 1 }],
    ['confirm_similar false', { confirm_similar: false }],
  ])('%s is a plain claim', async (_n, body) => {
    const h = new Harness();
    expect((await claim(h, await account(h), 'plain_claim', body)).statusCode).toBe(201);
  });

  test.each([
    ['not JSON', '{'],
    ['an array', '[]'],
    ['a string', '"x"'],
    ['null', 'null'],
    ['a number', '5'],
    ['confirm_similar a string', '{"confirm_similar":"yes"}'],
    ['confirm_similar a number', '{"confirm_similar":1}'],
    ['confirm_similar null', '{"confirm_similar":null}'],
  ])('%s is invalid_request (400) and creates nothing', async (_n, body) => {
    const h = new Harness();
    const res = await claim(h, await account(h), 'abc', body);
    expect([res.statusCode, err(res).code]).toEqual([400, 'invalid_request']);
    await nothingCreated(h, 'abc');
  });
});

describe('similar names', () => {
  test('tooSimilar: equal once underscores are dropped, or equal but for one trailing s, either way round; nothing else', () => {
    const similar: Array<[string, string]> = [
      ['http_client', 'httpclient'],
      ['httpclient', 'http_client'],
      ['http_client', 'http_clients'],
      ['tool', 'tools'],
      ['tools', 'tool'],
      ['a_b_c', 'ab_cs'],
    ];
    for (const [a, b] of similar) expect({ a, b, similar: tooSimilar(a, b) }).toEqual({ a, b, similar: true });
    const different: Array<[string, string]> = [
      ['http_client', 'http_cli'],
      ['http_client', 'http_clientss'], // two letters more
      ['tool', 'toolz'],
      ['ss', 'ss_x'],
      ['abc', 'abd'],
      ['tool', 'tolls'],
    ];
    for (const [a, b] of different) expect({ a, b, similar: tooSimilar(a, b) }).toEqual({ a, b, similar: false });
  });

  test.each([
    ['http_client', 'httpclient', "'httpclient' is too similar to 'http_client'."],
    ['http_client', 'http_clients', "'http_clients' is too similar to 'http_client'."],
    ['http_clients', 'http_client', "'http_client' is too similar to 'http_clients'."],
    ['http_client', 'http_cli_ent', "'http_cli_ent' is too similar to 'http_client'."],
  ])('with %s taken, claiming %s is name_too_similar (409) naming the other, and creates nothing', async (taken, name, message) => {
    const h = new Harness();
    await existing(h, taken);
    const res = await claim(h, await account(h), name);
    expect([res.statusCode, err(res).code, err(res).message]).toEqual([409, 'name_too_similar', message]);
    await nothingCreated(h, name);
  });

  test('confirm_similar: true claims it anyway; false (or absent) does not', async () => {
    const h = new Harness();
    await existing(h, 'http_client');
    const token = await account(h);
    expect(err(await claim(h, token, 'http_clients', { confirm_similar: false })).code).toBe('name_too_similar');
    expect((await claim(h, token, 'http_clients', { confirm_similar: true })).statusCode).toBe(201);
    expect((await h.registry.getPackage('http_clients'))?.state).toBe('claimed');
  });

  test('a taken name is name_taken, not name_too_similar, even with confirm_similar', async () => {
    const h = new Harness();
    await existing(h, 'http_client');
    const res = await claim(h, await account(h), 'http_client', { confirm_similar: true });
    expect(err(res).code).toBe('name_taken');
  });

  test('a name unlike every existing one is claimed, whatever is taken around it', async () => {
    const h = new Harness();
    for (const n of ['http_client', 'http_server', 'httpx', 'client']) await existing(h, n);
    expect((await claim(h, await account(h), 'http_cache')).statusCode).toBe(201);
  });

  test('only the names that share its first letter are read, and all of them: a similar name on a later page of the index is found', async () => {
    const h = new Harness();
    for (let i = 0; i < 150; i++) await existing(h, `p${String(i).padStart(3, '0')}`);
    await existing(h, 'pkg_x');
    await existing(h, 'other_name');
    const spy = jest.spyOn(h.registry, 'searchPackages');
    const token = await account(h);
    const res = await claim(h, token, 'pkgxs');
    expect([res.statusCode, err(res).code, err(res).message]).toEqual([409, 'name_too_similar', "'pkgxs' is too similar to 'pkg_x'."]);
    expect(spy.mock.calls.map(([prefix]) => prefix)).toEqual(['p', 'p']);
    expect(spy.mock.calls[1]![1]).toBe('p099'); // the second read continues after the last name of the first (100 names a page)
    spy.mockClear();
    // None of the 151 names starting with p is like it: two pages are read, then the name is created.
    expect((await claim(h, token, 'pzz')).statusCode).toBe(201);
    expect(spy.mock.calls).toHaveLength(2);
  });
});

describe('a deployment', () => {
  test('without a claim service has no claim route: POST is route_not_found', async () => {
    const h = new Harness();
    const token = await account(h);
    const res = await route(
      { method: 'POST', path: '/api/v1/packages/abc/claim', query: {}, headers: { authorization: `Bearer ${token}` } },
      { ...h.deps, publish: { ...h.deps.publish!, claims: undefined } },
      'r',
    );
    expect([res.statusCode, err(res).code]).toEqual([404, 'route_not_found']);
    await nothingCreated(h, 'abc');
  });

  test('a claim is a POST of exactly /packages/{name}/claim: other methods and shapes create nothing', async () => {
    const h = new Harness();
    const token = await account(h);
    for (const [method, p] of [
      ['GET', '/api/v1/packages/abc/claim'],
      ['PUT', '/api/v1/packages/abc/claim'],
      ['DELETE', '/api/v1/packages/abc/claim'],
      ['POST', '/api/v1/packages/abc'],
      ['POST', '/api/v1/packages/abc/claim/extra'],
    ] as const) {
      const res = await h.call(method, p, token);
      expect({ method, p, status: res.statusCode }).toEqual({ method, p, status: 404 });
    }
    await nothingCreated(h, 'abc');
  });
});

describe('the Lambda wiring', () => {
  test('publishApiFor offers the claim service next to the publish and group services', () => {
    const env = { MOPM_CHANNEL_BUCKET: 'bucket', MOPM_VALIDATE_QUEUE_URL: 'https://sqs.us-east-1.amazonaws.com/acct/validate.fifo' };
    const api = publishApiFor(env, new FakeDocClient() as never, 't', new MutableFlags());
    expect(api?.claims).toBeInstanceOf(ClaimService);
    expect(api?.groups).toBeDefined();
  });
});

describe('ClaimService on its own clock and ids', () => {
  test('with the defaults it stamps the real time, 30 days apart, and a fresh random audit id each time', async () => {
    const registry = new MemoryStore();
    const users = { getUser: async (id: number) => ({ github_id: id, handle: 'u', created_at: '2026-10-01T00:00:00Z', last_login_at: '2026-10-01T00:00:00Z' }) };
    const svc = new ClaimService({ registry, users, publishes: new MemoryPublishStore(), config: DEFAULT_PUBLISH_CONFIG });
    const before = Date.now();
    const a = await svc.claim({ githubId: 1, tokenId: 'tok_a' }, 'first_name', undefined);
    await svc.claim({ githubId: 1, tokenId: 'tok_a' }, 'second_name', undefined);
    const after = Date.now();
    const created = Date.parse((await registry.getPackage('first_name'))!.created_at);
    expect(created).toBeGreaterThan(before - 1000);
    expect(created).toBeLessThanOrEqual(after);
    expect(Date.parse(a.claim_expires_at) - created).toBe(CLAIM_TTL_MS);
    const ids = [...(await registry.listAudit('first_name')), ...(await registry.listAudit('second_name'))].map((e) => e.id);
    expect(ids[0]).toMatch(/^a_[0-9a-f]{32}$/);
    expect(new Set(ids).size).toBe(2);
  });
});
