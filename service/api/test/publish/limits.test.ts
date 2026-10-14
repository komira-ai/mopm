import { Harness, pkg } from './harness';

const err = (r: { body: string }) => JSON.parse(r.body).error as { code: string; message: string; hint: string };
const beginBody = (name: string, version: string, size = 10) => ({
  subdir: 'noarch',
  filename: `mojo-${name}-${version}-mojo1.0.0_0.conda`,
  sha256: 'c'.repeat(64),
  size,
});
const begin = (h: Harness, token: string, name: string, version: string, size?: number) =>
  h.call('POST', `/api/v1/packages/${name}/${version}/files`, token, beginBody(name, version, size));

describe('size limits', () => {
  test('a declared size over 100 MB is refused up front with payload_too_large; exactly 100 MB is accepted', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const over = await begin(h, me.token, 'demo', '1.0.0', 100_000_001);
    expect(over.statusCode).toBe(413);
    expect(err(over)).toMatchObject({ code: 'payload_too_large', message: 'The file is larger than the limit of 100000000 bytes.' });
    // Nothing was reserved or recorded.
    expect(await h.registry.listVersions('demo')).toEqual([]);
    expect(h.publishes.uploads.size).toBe(0);
    const edge = await begin(h, me.token, 'demo', '1.0.0', 100_000_000);
    expect(edge.statusCode).toBe(200);
  });

  test('the project total: used + declared over the limit is refused, and the error says how much room is left', async () => {
    const a = pkg({ name: 'demo', version: '1.0.0' });
    const b = pkg({ name: 'demo', version: '1.1.0' });
    // Room for a, and for b minus one byte.
    const h = new Harness({ projectQuotaBytes: a.bytes.length + b.bytes.length - 1 });
    const me = await h.account(1, 'a', ['demo']);
    await h.publish(me.token, a);
    await h.runValidator();
    await h.runIndexer();

    const room = a.bytes.length + b.bytes.length - 1 - a.bytes.length;
    const res = await begin(h, me.token, 'demo', '1.1.0', b.bytes.length);
    expect(res.statusCode).toBe(413);
    expect(err(res).message).toBe(`The file is larger than the limit of ${room} bytes.`);
    expect((await h.registry.getVersion('demo', '1.1.0'))).toBeUndefined();
    // Exactly the room left is fine.
    expect((await begin(h, me.token, 'demo', '1.1.0', room)).statusCode).toBe(200);
  });

  test('a full project blocks NEW publishes and deletes nothing: the published files stay in the channel and in repodata', async () => {
    const a = pkg({ name: 'demo', version: '1.0.0' });
    const h = new Harness({ projectQuotaBytes: a.bytes.length });
    const me = await h.account(1, 'a', ['demo']);
    await h.publish(me.token, a);
    await h.runValidator();
    await h.runIndexer();
    expect((await begin(h, me.token, 'demo', '2.0.0', 1)).statusCode).toBe(413);
    expect((await begin(h, me.token, 'demo', '2.0.0', 1)).statusCode).toBe(413);
    expect(h.objects.keys('noarch/')).toEqual(expect.arrayContaining([`noarch/${a.filename}`]));
    expect(Object.keys(h.repodata('noarch')['packages.conda'])).toEqual([a.filename]);
    expect((await h.registry.getVersion('demo', '1.0.0'))?.state).toBe('published');
  });

  test('yanked files still count (their bytes are still served); tombstoned ones do not (their bytes are gone)', async () => {
    const a = pkg({ name: 'demo', version: '1.0.0' });
    const h = new Harness({ projectQuotaBytes: a.bytes.length });
    const me = await h.account(1, 'a', ['demo']);
    await h.publish(me.token, a);
    await h.runValidator();
    const audit = { name: 'demo', ts: '2026-10-14T12:00:00Z', id: 'x1', actor: 't', action: 'yank' };
    await h.registry.updateVersion('demo', '1.0.0', { type: 'yank', reason: 'bad' }, audit);
    expect((await begin(h, me.token, 'demo', '2.0.0', 1)).statusCode).toBe(413);
    await h.registry.updateVersion('demo', '1.0.0', { type: 'tombstone', reason_code: 'malware', date: '2026-10-14' }, { ...audit, id: 'x2' });
    expect((await begin(h, me.token, 'demo', '2.0.0', 1)).statusCode).toBe(200);
  });

  test('the validator checks the total again, exactly, per package: two publishes begun in parallel cannot both fit', async () => {
    const a = pkg({ name: 'demo', version: '1.0.0' });
    const b = pkg({ name: 'demo', version: '1.1.0' });
    const h = new Harness({ projectQuotaBytes: a.bytes.length + b.bytes.length - 1 });
    const me = await h.account(1, 'a', ['demo']);
    // Both begins see an empty project, so both are admitted ...
    const ida = await h.publish(me.token, a);
    const idb = await h.publish(me.token, b);
    // ... and the validator, which handles a package's publishes one at a time, admits the first and refuses the second.
    await h.runValidator();
    await h.runIndexer();
    expect((await h.status(me.token, ida)).body.status).toBe('published');
    const second = (await h.status(me.token, idb)).body;
    expect(second).toMatchObject({ status: 'rejected', rejection_code: 'limit_exceeded' });
    expect(Object.keys(h.repodata('noarch')['packages.conda'])).toEqual([a.filename]);
    expect(h.objects.keys('noarch/')).not.toContain(`noarch/${b.filename}`);
    expect(h.objects.keys('quarantine/')).toEqual([]);
  });
});

describe('rate limits', () => {
  test('per account per UTC day: the call after the limit is 429 with Retry-After to midnight; a new day starts again', async () => {
    const h = new Harness({ ratePerAccountPerDay: 3 });
    const me = await h.account(1, 'a', ['demo']);
    for (const v of ['1.0.0', '1.0.1', '1.0.2']) expect((await begin(h, me.token, 'demo', v)).statusCode).toBe(200);
    const res = await begin(h, me.token, 'demo', '1.0.3');
    expect(res.statusCode).toBe(429);
    expect(err(res)).toEqual({ code: 'rate_limited', message: 'Too many requests.', hint: 'Wait 43200 seconds; the Retry-After header says how long.' });
    expect(res.headers['retry-after']).toBe('43200');
    // The refused call reserved nothing.
    expect((await h.registry.getVersion('demo', '1.0.3'))).toBeUndefined();
    h.clock.advance(12 * 3600_000 + 1000);
    expect((await begin(h, me.token, 'demo', '1.0.3')).statusCode).toBe(200);
  });

  test('per token: one token at its limit is refused while another token of the same account, and another account, are not', async () => {
    const h = new Harness({ ratePerTokenPerDay: 2, ratePerAccountPerDay: 100 });
    const me = await h.account(1, 'a', ['demo']);
    const second = await h.token(1, ['demo'], ['publish']);
    const other = await h.account(2, 'b', ['demo']);
    expect((await begin(h, me.token, 'demo', '1.0.0')).statusCode).toBe(200);
    expect((await begin(h, me.token, 'demo', '1.0.0')).statusCode).toBe(200);
    expect((await begin(h, me.token, 'demo', '1.0.0')).statusCode).toBe(429);
    expect((await begin(h, second, 'demo', '1.0.0')).statusCode).toBe(200);
    expect((await begin(h, other.token, 'demo', '1.0.0')).statusCode).toBe(200);
  });

  test('the defaults are generous: a CI pushing 150 versions in a day is not limited', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    for (let i = 0; i < 150; i++) expect((await begin(h, me.token, 'demo', `1.0.${i}`)).statusCode).toBe(200);
  });
});

describe('read-only mode', () => {
  test('begin and commit answer 503 read_only_mode, change nothing, and need no token; reads and status keep working', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const p = pkg({ name: 'demo', version: '1.0.0' });
    const id = await h.publish(me.token, p);
    h.flags.ro = true;

    const b = await begin(h, me.token, 'demo', '2.0.0');
    expect(b.statusCode).toBe(503);
    expect(err(b)).toEqual({
      code: 'read_only_mode',
      message: 'The registry is read-only right now; new uploads are refused.',
      hint: 'Installs still work. Try again later.',
    });
    const c = await h.commit(me.token, 'demo', '2.0.0', ['upl_x'], 'a'.repeat(64));
    expect(c.statusCode).toBe(503);
    expect(err(await h.call('POST', '/api/v1/packages/demo/2.0.0/files', undefined, beginBody('demo', '2.0.0'))).code).toBe('read_only_mode');
    expect(await h.registry.getVersion('demo', '2.0.0')).toBeUndefined();
    expect(h.publishes.uploads.size).toBe(1); // only the one from before the switch

    expect((await h.call('GET', '/api/v1/packages/demo')).statusCode).toBe(200);
    expect((await h.call('GET', '/api/v1/packages/demo/versions')).statusCode).toBe(200);
    expect((await h.status(me.token, id)).statusCode).toBe(200);

    // The switch is a runtime value: clearing it needs no deployment.
    h.flags.ro = false;
    expect((await begin(h, me.token, 'demo', '2.0.0')).statusCode).toBe(200);
  });

  test('work already accepted before the switch still finishes: the validator and the index writer do not look at it', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const id = await h.publish(me.token, pkg({ name: 'demo', version: '1.0.0' }));
    h.flags.ro = true;
    await h.runValidator();
    await h.runIndexer();
    expect((await h.status(me.token, id)).body.status).toBe('published');
  });

  test('if the switch cannot be read, writers fail closed with 503 unavailable and reads are unaffected', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    h.flags.broken = true;
    const b = await begin(h, me.token, 'demo', '1.0.0');
    expect(b.statusCode).toBe(503);
    expect(err(b).code).toBe('unavailable');
    expect((await h.call('GET', '/api/v1/health')).statusCode).toBe(200);
    expect((await h.call('GET', '/api/v1/packages/demo')).statusCode).toBe(200);
  });

  test('health reports read_only from the dependencies it is given', async () => {
    const h = new Harness();
    const { route } = await import('../../src/http/router');
    const health = async (readOnly: boolean) =>
      JSON.parse((await route({ method: 'GET', path: '/api/v1/health', query: {} }, { ...h.deps, readOnly }, 'r')).body).read_only;
    expect(await health(false)).toBe(false);
    expect(await health(true)).toBe(true);
  });
});
