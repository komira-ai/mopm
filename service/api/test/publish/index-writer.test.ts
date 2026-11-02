import { buildPackageIndex, buildTakedowns, indexKey } from '../../src/index-files';
import { parseIndexMessage } from '../../src/publish/indexer';
import { queueTakedownIndex } from '../../src/publish/takedown';
import { validatePublish } from '../../src/publish/validator';
import { Harness, pkg, sha256, type Pkg } from './harness';

/**
 * The sparse-index writer over the whole in-memory pipeline: publish, yank, unyank and takedown drive the real
 * services, the queue is the FIFO fake (dedup ids honoured), and the assertions read the files the channel holds.
 */

const lines = (text: string | undefined) =>
  (text ?? '')
    .split('\n')
    .filter((l) => l !== '')
    .map((l) => JSON.parse(l));
const yankUrl = (name: string, version: string) => `/api/v1/packages/${name}/${version}/yank`;
const types = (h: Harness) => h.indexQueue.sent.map((m) => JSON.parse(m.body).type as string);

async function publishAll(h: Harness, token: string, ...ps: Pkg[]) {
  for (const p of ps) await h.publish(token, p);
  await h.runValidator();
  await h.runIndexer();
}

/** A commit of bytes that are not a package; the validator rejects it. Returns the publish id. */
async function rejectedPublish(h: Harness, token: string, p: Pkg): Promise<string> {
  const junk = Buffer.from('this is not an archive');
  const u = await h.upload(token, p, { bytes: junk, sha256: sha256(junk), size: junk.length });
  const c = await h.commit(token, p.name, p.version, [u.upload_id!], p.manifest);
  expect(c.statusCode).toBe(202);
  await h.runValidator();
  await h.runIndexer();
  return JSON.parse(c.body).publish_id as string;
}

describe('publish', () => {
  test('writes the package file at index/<aa>/<bb>/<name>, as NDJSON, from the rows', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    await publishAll(h, me.token, pkg({ name: 'demo', version: '1.0.0' }));
    const o = h.objects.objects.get('index/de/mo/demo')!;
    expect(o.contentType).toBe('application/x-ndjson');
    expect(o.body.toString('utf8')).toBe(buildPackageIndex('demo', await h.registry.listVersions('demo')));
    expect(o.body.toString('utf8').endsWith('\n')).toBe(true);
    expect(lines(h.indexFile('demo'))).toMatchObject([{ v: 1, name: 'demo', version: '1.0.0', state: 'published' }]);
  });

  test('the file of a name under four characters is padded the way the spec says', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['ab']);
    await publishAll(h, me.token, pkg({ name: 'ab', version: '1.0.0' }));
    expect([...h.objects.objects.keys()].filter((k) => k.startsWith('index/'))).toEqual(['index/ab/__/ab']);
  });

  test('the index sha256, size and url match repodata and the file in the channel', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const p = pkg({ name: 'demo', version: '1.0.0' });
    await publishAll(h, me.token, p);
    const entry = h.repodata('noarch')['packages.conda'][p.filename]!;
    const [record] = lines(h.indexFile('demo'));
    expect(record.files).toEqual([
      { subdir: 'noarch', filename: p.filename, sha256: entry.sha256, size: entry.size, url: `https://conda.example.invalid/noarch/${p.filename}` },
    ]);
    expect(sha256((await h.objects.get(`noarch/${p.filename}`))!)).toBe(record.files[0].sha256);
  });

  test('a version with files in two subdirs is one line with both files', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const a = pkg({ name: 'demo', version: '1.0.0', subdir: 'linux-64' });
    const b = pkg({ name: 'demo', version: '1.0.0', subdir: 'osx-arm64' });
    const ua = await h.upload(me.token, a);
    const ub = await h.upload(me.token, b);
    expect((await h.commit(me.token, 'demo', '1.0.0', [ua.upload_id!, ub.upload_id!], a.manifest)).statusCode).toBe(202);
    await h.runValidator();
    await h.runIndexer();
    const rec = lines(h.indexFile('demo'));
    expect(rec).toHaveLength(1);
    expect(rec[0].files.map((f: { subdir: string }) => f.subdir)).toEqual(['linux-64', 'osx-arm64']);
  });

  test('the package file is asked for only after the last subdir lists the version, and the publish is published only after it is written', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const a = pkg({ name: 'demo', version: '1.0.0', subdir: 'linux-64' });
    const b = pkg({ name: 'demo', version: '1.0.0', subdir: 'osx-arm64' });
    const ua = await h.upload(me.token, a);
    const ub = await h.upload(me.token, b);
    expect((await h.commit(me.token, 'demo', '1.0.0', [ua.upload_id!, ub.upload_id!], a.manifest)).statusCode).toBe(202);
    await h.runValidator();
    const id = [...h.publishes.publishes.keys()][0]!;

    await h.handleIndex(h.indexQueue.take()!); // first subdir
    expect(types(h)).toEqual(['index']);
    expect(h.indexFile('demo')).toBeUndefined();

    await h.handleIndex(h.indexQueue.take()!); // second (last) subdir
    expect(types(h)).toEqual(['index_pkg']);
    expect(h.indexQueue.sent[0]!.groupId).toBe('pkg:demo');
    // Repodata lists the file in both subdirs by now; the index file is still absent and the publish still waits.
    expect(Object.keys(h.repodata('linux-64')['packages.conda'])).toEqual([a.filename]);
    expect(Object.keys(h.repodata('osx-arm64')['packages.conda'])).toEqual([b.filename]);
    expect(h.indexFile('demo')).toBeUndefined();
    expect((await h.status(me.token, id)).body.status).toBe('indexing');
    expect(h.publishes.publishes.get(id)).toMatchObject({ remaining_subdirs: [], index_pending: true });

    await h.runIndexer();
    expect(h.indexFile('demo')).toBeDefined();
    expect((await h.status(me.token, id)).body.status).toBe('published');
    expect(h.publishes.publishes.get(id)!.index_pending).toBe(false);
  });

  test('two publishes of one package that finish at the same package revision are both published', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const ids = [await h.publish(me.token, pkg({ name: 'demo', version: '1.0.0' })), await h.publish(me.token, pkg({ name: 'demo', version: '1.1.0' }))];
    await h.runValidator();
    // Both rows are published before either repodata job runs, so both jobs see the same package revision.
    const jobs = [h.indexQueue.take()!, h.indexQueue.take()!];
    for (const j of jobs) await h.handleIndex(j);
    expect(h.indexQueue.sent.map((m) => JSON.parse(m.body).rev)).toEqual([2, 2]);
    expect(h.indexQueue.sent.map((m) => m.dedupId).sort()).toEqual(ids.map((id) => `demo:2:${id}`).sort());
    await h.runIndexer();
    for (const id of ids) expect((await h.status(me.token, id)).body.status).toBe('published');
    expect(lines(h.indexFile('demo')).map((r) => r.version)).toEqual(['1.0.0', '1.1.0']);
  });

  test('a rejected publish yields no file and queues no package job', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const id = await rejectedPublish(h, me.token, pkg({ name: 'demo', version: '1.0.0' }));
    expect((await h.status(me.token, id)).body.status).toBe('rejected');
    expect(h.objects.keys('index/')).toEqual([]);
    expect(h.indexQueue.sent).toEqual([]);
    // Even a package job asked for by hand writes nothing for a package whose only row is the rejected one.
    await h.handleIndex({ body: JSON.stringify({ type: 'index_pkg', name: 'demo', rev: 1 }) });
    expect(h.objects.keys('index/')).toEqual([]);
  });

  test('a rejected publish leaves the file of the package untouched', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    await publishAll(h, me.token, pkg({ name: 'demo', version: '1.0.0' }));
    const before = h.indexFile('demo');
    await rejectedPublish(h, me.token, pkg({ name: 'demo', version: '1.1.0' }));
    expect(h.indexFile('demo')).toBe(before);
  });
});

describe('a lost message', () => {
  test('the last repodata job fails to queue the package job: the redelivered job queues it and the publish ends published', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const id = await h.publish(me.token, pkg({ name: 'demo', version: '1.0.0' }));
    await h.runValidator();
    const job = h.indexQueue.take()!;
    const send = h.indexQueue.send.bind(h.indexQueue);
    h.indexQueue.send = async () => {
      throw new Error('sqs down');
    };
    await expect(h.handleIndex(job)).rejects.toThrow('sqs down');
    h.indexQueue.send = send;
    expect(h.publishes.publishes.get(id)).toMatchObject({ status: 'indexing', index_pending: true });
    await h.handleIndex(job); // SQS redelivers the message
    expect(types(h)).toEqual(['index_pkg']);
    await h.runIndexer();
    expect((await h.status(me.token, id)).body.status).toBe('published');
    expect(h.indexFile('demo')).toBeDefined();
  });

  test('the validator, retried while only the package file is left, asks for it', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const id = await h.publish(me.token, pkg({ name: 'demo', version: '1.0.0' }));
    await h.runValidator();
    await h.handleIndex(h.indexQueue.take()!);
    h.indexQueue.sent.length = 0; // the message was lost
    (h.indexQueue as unknown as { seen: Set<string> }).seen.clear(); // and its dedup window is not in the way
    expect(await validatePublish(h.validatorDeps, id)).toBe('processed');
    expect(types(h)).toEqual(['index_pkg']);
    await h.runIndexer();
    expect((await h.status(me.token, id)).body.status).toBe('published');
  });
});

describe('yank, unyank and stale jobs', () => {
  test('a yank changes the version line to yanked with its reason; an unyank brings back the exact earlier bytes', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    await publishAll(h, me.token, pkg({ name: 'demo', version: '1.0.0' }), pkg({ name: 'demo', version: '1.1.0' }));
    const published = h.indexFile('demo')!;

    expect((await h.call('PUT', yankUrl('demo', '1.0.0'), me.token, { yanked: true, reason: 'broken' })).statusCode).toBe(200);
    await h.runIndexer();
    expect(lines(h.indexFile('demo')).map((r) => [r.version, r.state, r.yank_reason])).toEqual([
      ['1.0.0', 'yanked', 'broken'],
      ['1.1.0', 'published', undefined],
    ]);

    expect((await h.call('PUT', yankUrl('demo', '1.0.0'), me.token, { yanked: false })).statusCode).toBe(200);
    await h.runIndexer();
    expect(h.indexFile('demo')).toBe(published);
  });

  test('two yanks inside the dedup window both write', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    await publishAll(h, me.token, pkg({ name: 'demo', version: '1.0.0' }), pkg({ name: 'demo', version: '1.1.0' }));
    await h.call('PUT', yankUrl('demo', '1.0.0'), me.token, { yanked: true, reason: 'first' });
    await h.call('PUT', yankUrl('demo', '1.1.0'), me.token, { yanked: true, reason: 'second' });
    const pkgJobs = h.indexQueue.sent.filter((m) => JSON.parse(m.body).type === 'index_pkg');
    expect(pkgJobs.map((m) => m.dedupId)).toEqual(['demo:3', 'demo:4']);
    await h.runIndexer();
    expect(lines(h.indexFile('demo')).map((r) => [r.version, r.state, r.yank_reason])).toEqual([
      ['1.0.0', 'yanked', 'first'],
      ['1.1.0', 'yanked', 'second'],
    ]);
    expect(h.objects.log.filter((l) => l === 'put index/de/mo/demo')).toHaveLength(4); // two publishes, two yanks
  });

  test('a stale writer cannot regress a file: an older job delivered after a newer one writes the newest state', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    await publishAll(h, me.token, pkg({ name: 'demo', version: '1.0.0' }));
    await h.call('PUT', yankUrl('demo', '1.0.0'), me.token, { yanked: true, reason: 'bad' });
    const staleYankJob = h.indexQueue.sent.find((m) => JSON.parse(m.body).type === 'index_pkg')!;
    await h.runIndexer();
    expect(lines(h.indexFile('demo'))[0].state).toBe('yanked');
    await h.call('PUT', yankUrl('demo', '1.0.0'), me.token, { yanked: false });
    await h.runIndexer();
    const current = h.indexFile('demo')!;
    expect(lines(current)[0].state).toBe('published');

    await h.handleIndex(staleYankJob); // a redelivery of the older message
    expect(h.indexFile('demo')).toBe(current);
    expect(JSON.parse(staleYankJob.body).rev).toBeLessThan(3);
  });

  test('an unyank shows in the index only after every subdir of repodata lists the file again', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const a = pkg({ name: 'demo', version: '1.0.0', subdir: 'linux-64' });
    const b = pkg({ name: 'demo', version: '1.0.0', subdir: 'osx-arm64' });
    const ua = await h.upload(me.token, a);
    const ub = await h.upload(me.token, b);
    expect((await h.commit(me.token, 'demo', '1.0.0', [ua.upload_id!, ub.upload_id!], a.manifest)).statusCode).toBe(202);
    await h.runValidator();
    await h.runIndexer();
    await h.call('PUT', yankUrl('demo', '1.0.0'), me.token, { yanked: true, reason: 'bad' });
    await h.runIndexer();
    expect(lines(h.indexFile('demo'))[0].state).toBe('yanked');

    await h.call('PUT', yankUrl('demo', '1.0.0'), me.token, { yanked: false });
    const listed = () => [a, b].map((p) => Object.keys(h.repodata(p.subdir)['packages.conda']).length);
    expect(listed()).toEqual([0, 0]);

    await h.handleIndex(h.indexQueue.take()!); // linux-64
    expect(listed()).toEqual([1, 0]);
    expect(lines(h.indexFile('demo'))[0].state).toBe('yanked');
    expect(types(h)).toEqual(['index']);

    await h.handleIndex(h.indexQueue.take()!); // osx-arm64, the last
    expect(listed()).toEqual([1, 1]);
    expect(lines(h.indexFile('demo'))[0].state).toBe('yanked');
    expect(types(h)).toEqual(['index_pkg']);

    await h.runIndexer();
    expect(lines(h.indexFile('demo'))[0].state).toBe('published');
  });
});

describe('takedown', () => {
  const audit = (name: string, version: string) => ({ name, ts: '2026-10-02T00:00:00.000Z', id: `a_takedown_${version}`, actor: 'ops', action: 'takedown', version });

  test('a tombstone of a published version appears in the index and in repodata removed, and in takedowns.json', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const p = pkg({ name: 'demo', version: '1.0.0' });
    await publishAll(h, me.token, p, pkg({ name: 'demo', version: '1.1.0' }));
    await h.registry.updateVersion('demo', '1.0.0', { type: 'tombstone', reason_code: 'malware', date: '2026-10-02' }, audit('demo', '1.0.0'));

    await queueTakedownIndex({ registry: h.registry, indexQueue: h.indexQueue }, 'demo');
    expect(h.indexQueue.sent.map((m) => m.groupId).sort()).toEqual(['noarch', 'pkg:demo', 'takedowns']);
    await h.runIndexer();

    const [tomb, live] = lines(h.indexFile('demo'));
    expect(tomb).toMatchObject({ version: '1.0.0', state: 'tombstoned', tombstone: { reason_code: 'malware', date: '2026-10-02' } });
    expect(tomb.files).toEqual([{ subdir: 'noarch', filename: p.filename, sha256: p.sha256, size: p.bytes.length }]); // sha256 kept, no url
    expect(live).toMatchObject({ version: '1.1.0', state: 'published' });
    expect(h.repodata('noarch').removed).toEqual([p.filename]);
    expect(Object.keys(h.repodata('noarch')['packages.conda'])).not.toContain(p.filename);

    const takedowns = h.objects.objects.get('index/takedowns.json')!;
    expect(takedowns.contentType).toBe('application/json');
    expect(JSON.parse(takedowns.body.toString('utf8'))).toEqual({
      index_version: 1,
      takedowns: [{ name: 'demo', version: '1.0.0', reason_code: 'malware', sha256: [p.sha256], date: '2026-10-02' }],
    });
    expect(takedowns.body.toString('utf8')).toBe(buildTakedowns(await h.registry.listVersions('demo')));
  });

  test('two takedowns in a row both reach takedowns.json (the dedup id carries the package revision)', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    await publishAll(h, me.token, pkg({ name: 'demo', version: '1.0.0' }), pkg({ name: 'demo', version: '1.1.0' }));
    const d = { registry: h.registry, indexQueue: h.indexQueue };
    await h.registry.updateVersion('demo', '1.0.0', { type: 'tombstone', reason_code: 'malware', date: '2026-10-02' }, audit('demo', '1.0.0'));
    await queueTakedownIndex(d, 'demo');
    await h.registry.updateVersion('demo', '1.1.0', { type: 'tombstone', reason_code: 'malware', date: '2026-10-03' }, audit('demo', '1.1.0'));
    await queueTakedownIndex(d, 'demo');
    expect(h.indexQueue.sent.filter((m) => m.groupId === 'takedowns')).toHaveLength(2);
    await h.runIndexer();
    const log = JSON.parse(h.objects.objects.get('index/takedowns.json')!.body.toString('utf8'));
    expect(log.takedowns.map((t: { version: string }) => t.version)).toEqual(['1.0.0', '1.1.0']);
  });

  test('the seed message writes the empty log on a stage that has no takedown, and the same bytes every time', async () => {
    const h = new Harness();
    await h.handleIndex({ body: '{"type":"index_takedowns"}' });
    const o = h.objects.objects.get('index/takedowns.json')!;
    expect(o.body.toString('utf8')).toBe('{"index_version":1,"takedowns":[]}\n');
    expect(o.contentType).toBe('application/json');
    await h.handleIndex({ body: '{"type":"index_takedowns"}' });
    expect(h.objects.objects.get('index/takedowns.json')!.body.toString('utf8')).toBe('{"index_version":1,"takedowns":[]}\n');
  });
});

describe('messages the writer does not understand', () => {
  test.each([
    ['null', null],
    ['no type', {}],
    ['another type', { type: 'validate', publish_id: 'p' }],
    ['an index message without a subdir', { type: 'index' }],
    ['a package job without a name', { type: 'index_pkg', rev: 1 }],
    ['a package job for a path', { type: 'index_pkg', name: '../evil', rev: 1 }],
    ['a package job for an upper-case name', { type: 'index_pkg', name: 'Demo', rev: 1 }],
    ['a package job with a negative rev', { type: 'index_pkg', name: 'demo', rev: -1 }],
    ['a package job with a text rev', { type: 'index_pkg', name: 'demo', rev: '1' }],
    ['a chained index message with a bad package', { type: 'index', subdir: 'noarch', then: { name: 'x/y', rev: 1, next: [] } }],
    ['a chained index message with a bad next list', { type: 'index', subdir: 'noarch', then: { name: 'demo', rev: 1, next: [3] } }],
  ])('%s is refused', (_what, body) => {
    expect(parseIndexMessage(body)).toBeUndefined();
  });

  test('the three kinds parse to exactly their fields', () => {
    expect(parseIndexMessage({ type: 'index', subdir: 'noarch', publish_id: 'p', extra: 1 })).toEqual({ type: 'index', subdir: 'noarch', publish_id: 'p' });
    expect(parseIndexMessage({ type: 'index_pkg', name: 'demo', rev: 4 })).toEqual({ type: 'index_pkg', name: 'demo', rev: 4 });
    expect(parseIndexMessage({ type: 'index_takedowns', name: 'ignored' })).toEqual({ type: 'index_takedowns' });
  });

  test('indexKey and the writer agree on where a package lives', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    await publishAll(h, me.token, pkg({ name: 'demo', version: '1.0.0' }));
    expect(h.objects.keys('index/')).toEqual([indexKey('demo')]);
  });
});
