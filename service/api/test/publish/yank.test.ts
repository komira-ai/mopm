import { Harness, pkg } from './harness';

const err = (r: { body: string }) => JSON.parse(r.body).error as { code: string; message: string };
const yankUrl = (name: string, version: string) => `/api/v1/packages/${name}/${version}/yank`;

/** A published, indexed version with files in two subdirs. */
async function published(h: Harness, token: string) {
  const a = pkg({ name: 'demo', version: '1.0.0', subdir: 'linux-64' });
  const b = pkg({ name: 'demo', version: '1.0.0', subdir: 'osx-arm64' });
  const ua = await h.upload(token, a);
  const ub = await h.upload(token, b);
  expect((await h.commit(token, 'demo', '1.0.0', [ua.upload_id!, ub.upload_id!], a.manifest)).statusCode).toBe(202);
  await h.runValidator();
  await h.runIndexer();
  return { a, b };
}

describe('yank and unyank rebuild the index', () => {
  test('a yank queues one rebuild per affected subdir, and after the writer runs repodata lists the file under removed', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const { a, b } = await published(h, me.token);
    expect(Object.keys(h.repodata('linux-64')['packages.conda'])).toEqual([a.filename]);
    expect(h.indexQueue.sent).toEqual([]);

    const res = await h.call('PUT', yankUrl('demo', '1.0.0'), me.token, { yanked: true, reason: 'broken build' });
    expect(res.statusCode).toBe(200);
    expect(JSON.parse(res.body)).toMatchObject({ version: '1.0.0', state: 'yanked', yank_reason: 'broken build' });
    // The index writer's FIFO group is the subdir, as for a publish; no publish id: a plain rebuild.
    expect(h.indexQueue.sent.map((m) => [m.groupId, JSON.parse(m.body)]).sort()).toEqual([
      ['linux-64', { type: 'index', subdir: 'linux-64' }],
      ['osx-arm64', { type: 'index', subdir: 'osx-arm64' }],
    ]);
    await h.runIndexer();
    for (const [subdir, f] of [['linux-64', a], ['osx-arm64', b]] as const) {
      expect(h.repodata(subdir)['packages.conda']).toEqual({});
      expect(h.repodata(subdir).removed).toEqual([f.filename]);
    }
    // The files stay downloadable.
    expect(h.objects.keys('linux-64/')).toContain(`linux-64/${a.filename}`);

    const back = await h.call('PUT', yankUrl('demo', '1.0.0'), me.token, { yanked: false });
    expect(back.statusCode).toBe(200);
    expect(JSON.parse(back.body)).toMatchObject({ state: 'published' });
    expect(JSON.parse(back.body)).not.toHaveProperty('yank_reason');
    expect(h.indexQueue.sent).toHaveLength(2);
    await h.runIndexer();
    expect(Object.keys(h.repodata('linux-64')['packages.conda'])).toEqual([a.filename]);
    expect(h.repodata('linux-64').removed).toEqual([]);
  });

  test('if the rebuild cannot be queued the yank is already recorded; repeating the request queues it and answers 200', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const { a } = await published(h, me.token);
    const send = h.indexQueue.send.bind(h.indexQueue);
    h.indexQueue.send = async () => {
      throw new Error('sqs down');
    };
    jest.spyOn(console, 'error').mockImplementation(() => undefined);
    const failed = await h.call('PUT', yankUrl('demo', '1.0.0'), me.token, { yanked: true, reason: 'bad' });
    expect(failed.statusCode).toBe(500);
    expect((await h.registry.getVersion('demo', '1.0.0'))?.state).toBe('yanked');
    expect(Object.keys(h.repodata('linux-64')['packages.conda'])).toEqual([a.filename]); // still stale

    h.indexQueue.send = send;
    const again = await h.call('PUT', yankUrl('demo', '1.0.0'), me.token, { yanked: true, reason: 'other words' });
    expect(again.statusCode).toBe(200);
    expect(JSON.parse(again.body)).toMatchObject({ state: 'yanked', yank_reason: 'bad' });
    expect(h.indexQueue.sent).toHaveLength(2);
    expect((await h.registry.getVersion('demo', '1.0.0'))?.rev).toBe(2); // the repeat changed nothing
    await h.runIndexer();
    expect(h.repodata('linux-64').removed).toEqual([a.filename]);
  });

  test('a yank is audited with the reason and who did it', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    await published(h, me.token);
    await h.call('PUT', yankUrl('demo', '1.0.0'), me.token, { yanked: true, reason: 'bad' });
    const entries = await h.registry.listAudit('demo');
    expect(entries.find((e) => e.action === 'yank')).toMatchObject({ version: '1.0.0', actor: 'u:1', detail: { by: 'a', reason: 'bad' } });
  });
});

describe('who may yank, and what is refused', () => {
  test('a yank-only token for the package works; a token for another package is scope_missing; a non-owner account is not_owner', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    await h.account(2, 'b', ['other']);
    await published(h, me.token);
    const yankOnly = await h.token(1, ['demo'], ['yank']);
    expect((await h.call('PUT', yankUrl('demo', '1.0.0'), yankOnly, { yanked: true, reason: 'x' })).statusCode).toBe(200);
    const wrongPackage = await h.token(1, ['other'], ['yank']);
    const r1 = await h.call('PUT', yankUrl('demo', '1.0.0'), wrongPackage, { yanked: false });
    expect([r1.statusCode, err(r1).code]).toEqual([403, 'scope_missing']);
    // Account 2 has a token naming demo but owns only 'other'.
    const stranger = await h.token(2, ['demo'], ['yank']);
    const r2 = await h.call('PUT', yankUrl('demo', '1.0.0'), stranger, { yanked: false });
    expect([r2.statusCode, err(r2).code]).toEqual([403, 'not_owner']);
    const none = await h.call('PUT', yankUrl('demo', '1.0.0'), undefined, { yanked: false });
    expect([none.statusCode, err(none).code]).toEqual([401, 'token_missing']);
    expect((await h.registry.getVersion('demo', '1.0.0'))?.state).toBe('yanked');
  });

  test.each([
    ['no body', undefined, 'invalid_request'],
    ['yanked is not a boolean', { yanked: 'yes' }, 'invalid_request'],
    ['a yank without a reason', { yanked: true }, 'invalid_request'],
    ['a yank with an empty reason', { yanked: true, reason: '' }, 'invalid_request'],
    ['a reason over 280 characters', { yanked: true, reason: 'x'.repeat(281) }, 'invalid_request'],
  ])('%s: 400 %s and nothing queued', async (_n, body, code) => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    await published(h, me.token);
    const r = await h.call('PUT', yankUrl('demo', '1.0.0'), me.token, body);
    expect([r.statusCode, err(r).code]).toEqual([400, code]);
    expect(h.indexQueue.sent).toEqual([]);
    expect((await h.registry.getVersion('demo', '1.0.0'))?.state).toBe('published');
  });

  test('invalid_transition (409) for a pending version, an unyank of a published one and anything on a tombstone; version_not_found (404); invalid_version (400)', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    await published(h, me.token);
    // A reserved number whose publish has not run is pending.
    const p2 = pkg({ name: 'demo', version: '2.0.0' });
    await h.upload(me.token, p2);
    const pending = await h.call('PUT', yankUrl('demo', '2.0.0'), me.token, { yanked: true, reason: 'x' });
    expect([pending.statusCode, err(pending)]).toEqual([409, { code: 'invalid_transition', message: "Cannot yank 'demo' 2.0.0: it is pending.", hint: expect.any(String) }]);
    const unyank = await h.call('PUT', yankUrl('demo', '1.0.0'), me.token, { yanked: false });
    expect([unyank.statusCode, err(unyank).code]).toEqual([409, 'invalid_transition']);
    await h.registry.updateVersion('demo', '1.0.0', { type: 'tombstone', reason_code: 'malware', date: '2026-10-14' }, { name: 'demo', ts: 't', id: 'x', actor: 'admin', action: 'takedown' });
    for (const body of [{ yanked: true, reason: 'x' }, { yanked: false }]) {
      const r = await h.call('PUT', yankUrl('demo', '1.0.0'), me.token, body);
      expect([r.statusCode, err(r).code]).toEqual([409, 'invalid_transition']);
    }
    expect(h.indexQueue.sent).toEqual([]);
    const missing = await h.call('PUT', yankUrl('demo', '9.9.9'), me.token, { yanked: false });
    expect([missing.statusCode, err(missing).code]).toEqual([404, 'version_not_found']);
    const bad = await h.call('PUT', yankUrl('demo', '1.0'), me.token, { yanked: false });
    expect([bad.statusCode, err(bad).code]).toEqual([400, 'invalid_version']);
  });

  test('read-only mode does not stop a yank', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    await published(h, me.token);
    h.flags.ro = true;
    expect((await h.call('PUT', yankUrl('demo', '1.0.0'), me.token, { yanked: true, reason: 'incident' })).statusCode).toBe(200);
  });

  test('without an index queue configured a yank is unavailable (503) and changes nothing', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    await published(h, me.token);
    (h.service as unknown as { d: { indexQueue?: unknown } }).d.indexQueue = undefined;
    const r = await h.call('PUT', yankUrl('demo', '1.0.0'), me.token, { yanked: true, reason: 'x' });
    expect([r.statusCode, err(r).code]).toEqual([503, 'unavailable']);
    expect((await h.registry.getVersion('demo', '1.0.0'))?.state).toBe('published');
  });
});
