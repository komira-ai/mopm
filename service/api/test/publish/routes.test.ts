import { mintToken } from '../../src/auth';
import { route } from '../../src/http/router';
import { Harness, pkg } from './harness';

const err = (r: { body: string }) => JSON.parse(r.body).error as { code: string; message: string; hint: string };

describe('authentication and scope of the publish routes', () => {
  const p = pkg({ name: 'demo', version: '1.0.0' });
  const body = { subdir: 'noarch', filename: p.filename, sha256: p.sha256, size: p.bytes.length };
  const begin = (h: Harness, token?: string, name = 'demo') => h.call('POST', `/api/v1/packages/${name}/1.0.0/files`, token, { ...body, filename: p.filename.replace('demo', name) });

  test('no token, a malformed token and an unknown token are 401, on all three operations', async () => {
    const h = new Harness();
    await h.account(1, 'a', ['demo']);
    for (const [method, path, b] of [
      ['POST', '/api/v1/packages/demo/1.0.0/files', body],
      ['POST', '/api/v1/packages/demo/1.0.0/publish', { upload_ids: ['u'], manifest_sha256: 'a'.repeat(64) }],
      ['GET', '/api/v1/publishes/pub_x', undefined],
    ] as const) {
      const none = await h.call(method, path, undefined, b);
      expect([none.statusCode, err(none).code]).toEqual([401, 'token_missing']);
      expect(none.headers['x-mopm-request-id']).toBe('req-1');
      const junk = await h.call(method, path, 'not-a-token', b);
      expect([junk.statusCode, err(junk).code]).toEqual([401, 'token_unknown']);
      const unknown = await h.call(method, path, `mopm_${'a'.repeat(40)}`, b);
      expect([unknown.statusCode, err(unknown).code]).toEqual([401, 'token_unknown']);
    }
  });

  test('an expired token and a revoked token are 401 with their own codes', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const [revoked] = (await h.authStore.listTokens(1)).map((t) => t.id);
    await h.authStore.revokeToken(revoked!, '2026-10-14T12:00:00Z');
    expect(err(await begin(h, me.token)).code).toBe('token_revoked');

    const h2 = new Harness();
    const me2 = await h2.account(1, 'a', ['demo']);
    h2.clock.advance(25 * 3600_000);
    const res = await begin(h2, me2.token);
    expect(res.statusCode).toBe(401);
    expect(err(res).code).toBe('token_expired');
  });

  test('the scope must be publish, for this package: a yank-only token and a token for another package are 403 scope_missing', async () => {
    const h = new Harness();
    await h.account(1, 'a', ['demo', 'other']);
    const yankOnly = await h.token(1, ['demo'], ['yank']);
    const r1 = await begin(h, yankOnly);
    expect([r1.statusCode, err(r1).code]).toEqual([403, 'scope_missing']);
    expect(err(r1).message).toBe("The token does not have the 'publish' scope for 'demo'.");
    const otherOnly = await h.token(1, ['other'], ['publish']);
    expect(err(await begin(h, otherOnly)).code).toBe('scope_missing');
    const status = await h.call('GET', '/api/v1/publishes/pub_x', yankOnly);
    expect([status.statusCode, err(status).code]).toEqual([403, 'scope_missing']);
  });

  test('a CI identity token publishes exactly its package and version, and sees only its own publish', async () => {
    const h = new Harness();
    await h.registry.createPackage({ name: 'demo', state: 'claimed', created_at: '2026-10-14T12:00:00Z' });
    const t = h.clock.now();
    const ci = await mintToken(h.authStore, {
      kind: 'oidc',
      name: 'ci',
      scopes: ['publish'],
      packages: ['demo'],
      all_current: false,
      version: '1.0.0',
      created_at: t.toISOString(),
      expires_at: new Date(t.getTime() + 15 * 60_000).toISOString(),
      issued_to: 'komira-ai/demo',
    });
    // another version: refused
    const wrong = await h.call('POST', '/api/v1/packages/demo/1.0.1/files', ci.secret, { ...body, filename: 'mojo-demo-1.0.1-mojo1.0.0_0.conda' });
    expect(err(wrong).code).toBe('scope_missing');
    // the equivalent spelling of its version: allowed (conda equality)
    const q = pkg({ name: 'demo', version: '1.0' });
    const u = await h.upload(ci.secret, q);
    expect(u.res.statusCode).toBe(200);
    expect(u.put).toBe('ok');
    const c = await h.commit(ci.secret, 'demo', '1.0', [u.upload_id!], q.manifest);
    expect(c.statusCode).toBe(202);
    const id = JSON.parse(c.body).publish_id as string;
    expect((await h.status(ci.secret, id)).body.status).toBe('pending');
    await h.runValidator();
    await h.runIndexer();
    expect((await h.status(ci.secret, id)).body.status).toBe('published');
    expect((await h.registry.getVersion('demo', '1.0'))?.published_by).toBe('ci');
    // another CI token (another run) cannot read this publish
    const other = await mintToken(h.authStore, {
      kind: 'oidc',
      name: 'ci',
      scopes: ['publish'],
      packages: ['demo'],
      all_current: false,
      version: '1.0.0',
      created_at: t.toISOString(),
      expires_at: new Date(t.getTime() + 15 * 60_000).toISOString(),
    });
    expect((await h.call('GET', `/api/v1/publishes/${id}`, other.secret)).statusCode).toBe(404);
  });

  test('a session token (a login, not an API token) cannot publish', async () => {
    const h = new Harness();
    await h.account(1, 'a', ['demo']);
    const t = h.clock.now();
    const session = await mintToken(h.authStore, {
      kind: 'session',
      github_id: 1,
      name: 'login',
      scopes: [],
      packages: [],
      all_current: false,
      fresh_until: new Date(t.getTime() + 600_000).toISOString(),
      created_at: t.toISOString(),
      expires_at: new Date(t.getTime() + 3600_000).toISOString(),
    });
    expect(err(await begin(h, session.secret)).code).toBe('scope_missing');
    expect(err(await h.call('GET', '/api/v1/publishes/pub_x', session.secret)).code).toBe('scope_missing');
  });
});

describe('response shapes', () => {
  test('begin is 200 and commit is 202, JSON, never cached, with the request id', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const p = pkg({ name: 'demo', version: '1.0.0' });
    const begin = await h.call('POST', '/api/v1/packages/demo/1.0.0/files', me.token, { subdir: 'noarch', filename: p.filename, sha256: p.sha256, size: p.bytes.length });
    expect(begin.statusCode).toBe(200);
    expect(begin.headers).toMatchObject({ 'content-type': 'application/json', 'cache-control': 'no-store', 'x-mopm-request-id': 'req-1' });
    const b = JSON.parse(begin.body);
    expect(Object.keys(b).sort()).toEqual(['expires_at', 'put_headers', 'put_url', 'upload_id']);
    await h.upload(me.token, p);
    const rec = [...h.publishes.uploads.values()][1]!;
    const commit = await h.commit(me.token, 'demo', '1.0.0', [rec.upload_id], p.manifest);
    expect(commit.statusCode).toBe(202);
    expect(Object.keys(JSON.parse(commit.body)).sort()).toEqual(['publish_id', 'status_url']);
    expect(commit.headers['cache-control']).toBe('no-store');
  });

  test('a pending status carries only the id, name, version and status', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const id = await h.publish(me.token, pkg({ name: 'demo', version: '1.0.0' }));
    expect(Object.keys((await h.status(me.token, id)).body).sort()).toEqual(['name', 'publish_id', 'status', 'version']);
  });

  test('the error body of an unexpected failure is internal_error and leaks nothing', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    h.publishes.getUpload = async () => {
      throw new Error('secret table name mopm-beta-uploads exploded');
    };
    const spy = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    const p = pkg({ name: 'demo', version: '1.0.0' });
    const r = await h.call('POST', '/api/v1/packages/demo/1.0.0/publish', me.token, { upload_ids: ['u'], manifest_sha256: p.manifest });
    spy.mockRestore();
    expect(r.statusCode).toBe(500);
    expect(err(r)).toEqual({ code: 'internal_error', message: 'Something went wrong on our side.', hint: 'Try again; report the request id if it persists.' });
    expect(r.body).not.toContain('secret');
  });

  test('without publish dependencies the router serves reads only, as before', async () => {
    const h = new Harness();
    const { publish: _p, ...reads } = h.deps;
    const r = await route({ method: 'POST', path: '/api/v1/packages/demo/1.0.0/files', query: {}, headers: {}, body: '{}' }, reads, 'r');
    expect([r.statusCode, err(r).code]).toEqual([404, 'route_not_found']);
    expect((await route({ method: 'GET', path: '/api/v1/health', query: {} }, reads, 'r')).statusCode).toBe(200);
  });
});
