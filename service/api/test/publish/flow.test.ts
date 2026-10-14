import { indexSubdir } from '../../src/publish/indexer';
import { Harness, pkg, sha256 } from './harness';

/**
 * The whole pipeline in memory: begin -> PUT to the fake S3 -> commit -> validator -> index writer, over the real
 * router, service, state machine, validator and repodata writer. Only the ports (S3, queues, CloudFront, DynamoDB)
 * are fakes. What each test proves and the defect it would catch are stated in its name or its first comment.
 */
describe('the happy path', () => {
  test('begin, PUT, commit, validate, index: the package ends up in the channel and in repodata.json', async () => {
    const h = new Harness();
    const me = await h.account(4242, 'octo', ['demo']);
    const p = pkg({ name: 'demo', version: '1.0.0', subdir: 'noarch' });

    const id = await h.publish(me.token, p);
    expect((await h.status(me.token, id)).body.status).toBe('pending');
    // A pending version is a reserved number and shows nowhere.
    expect((await h.call('GET', '/api/v1/packages/demo/versions')).body).toContain('"versions":[]');

    await h.runValidator();
    expect((await h.status(me.token, id)).body.status).toBe('indexing');
    // Files are in the channel before repodata mentions them (the spec: repodata is written last).
    expect(h.objects.keys('noarch/')).toEqual([`noarch/${p.filename}`]);
    expect((await h.registry.getVersion('demo', '1.0.0'))?.state).toBe('published');

    await h.runIndexer();
    expect((await h.status(me.token, id)).body).toEqual({ publish_id: id, name: 'demo', version: '1.0.0', status: 'published' });

    const repo = h.repodata('noarch');
    expect(Object.keys(repo['packages.conda'])).toEqual([p.filename]);
    expect(repo['packages.conda'][p.filename]).toMatchObject({ name: 'mojo-demo', version: '1.0.0', sha256: p.sha256 });
    // The published bytes are the uploaded bytes.
    expect(sha256((await h.objects.get(`noarch/${p.filename}`))!)).toBe(p.sha256);
    // The two repodata paths of that subdir were invalidated, and only those.
    expect(h.invalidator.batches.map((b) => b.paths)).toEqual([['/noarch/repodata.json', '/noarch/repodata.json.zst']]);
    // The quarantine object is gone.
    expect(h.objects.keys('quarantine/')).toEqual([]);
    // The version record carries what the archive said.
    const v = (await h.registry.getVersion('demo', '1.0.0'))!;
    expect(v).toMatchObject({
      state: 'published',
      build: 'mojo1.0.0_0',
      requires_mojo: '==1.0.0',
      manifest_sha256: p.manifest,
      published_by: 'octo',
      files: [{ subdir: 'noarch', filename: p.filename, sha256: p.sha256, size: p.bytes.length, url: `https://conda.example.invalid/noarch/${p.filename}` }],
    });
    // It is visible through the read API now.
    expect(JSON.parse((await h.call('GET', '/api/v1/packages/demo/versions')).body).versions.map((x: { version: string }) => x.version)).toEqual(['1.0.0']);
  });

  test('the index writer creates the empty index of the other subdirs, create-only, and never replaces an existing one', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    // A subdir that already has an index (a stage deployed with the old seed) keeps it.
    const old = Buffer.from('{"info":{"subdir":"osx-arm64"},"old":true}');
    await h.objects.put('osx-arm64/repodata.json', old, { contentType: 'application/json' });

    await h.publish(me.token, pkg({ name: 'demo', version: '1.0.0', subdir: 'linux-64' }));
    await h.runValidator();
    await h.runIndexer();

    for (const s of ['noarch', 'linux-aarch64']) expect(h.repodata(s)['packages.conda']).toEqual({});
    expect(h.objects.objects.get('osx-arm64/repodata.json')!.body.equals(old)).toBe(true);
    expect(h.objects.objects.has('noarch/repodata.json.zst')).toBe(true);
    expect(Object.keys(h.repodata('linux-64')['packages.conda'])).toHaveLength(1);
  });

  test('a version with files in two subdirs becomes published only when both subdirs list it', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const a = pkg({ name: 'demo', version: '1.0.0', subdir: 'linux-64' });
    const b = pkg({ name: 'demo', version: '1.0.0', subdir: 'osx-arm64' });
    const ua = await h.upload(me.token, a);
    const ub = await h.upload(me.token, b);
    expect((await h.commit(me.token, 'demo', '1.0.0', [ua.upload_id!, ub.upload_id!], a.manifest)).statusCode).toBe(202);
    await h.runValidator();
    const id = [...h.publishes.publishes.keys()][0]!;
    expect(h.indexQueue.sent.map((m) => m.groupId).sort()).toEqual(['linux-64', 'osx-arm64']);

    const first = h.indexQueue.take()!;
    await indexSubdir(h.indexerDeps, JSON.parse(first.body));
    expect((await h.status(me.token, id)).body.status).toBe('indexing');
    await h.runIndexer();
    expect((await h.status(me.token, id)).body.status).toBe('published');
    expect(Object.keys(h.repodata('linux-64')['packages.conda'])).toEqual([a.filename]);
    expect(Object.keys(h.repodata('osx-arm64')['packages.conda'])).toEqual([b.filename]);
  });
});

describe('the presigned upload is pinned to the declared bytes', () => {
  test('the fake storage layer refuses a wrong length, a wrong body and an expired URL; the right bytes pass', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const p = pkg({ name: 'demo', version: '1.0.0' });
    const longer = Buffer.concat([p.bytes, Buffer.from('x')]);
    const flipped = Buffer.from(p.bytes);
    flipped[flipped.length - 1] ^= 1;
    expect((await h.upload(me.token, p, { bytes: longer })).put).toBe('bad_length');
    expect((await h.upload(me.token, p, { bytes: flipped })).put).toBe('bad_checksum');
    expect(h.objects.keys('quarantine/')).toEqual([]);
    expect((await h.upload(me.token, p)).put).toBe('ok');
    expect(h.objects.keys('quarantine/')).toHaveLength(1);

    // five minutes and a second later
    const late = await h.call('POST', '/api/v1/packages/demo/1.0.0/files', me.token, { subdir: 'noarch', filename: p.filename, sha256: p.sha256, size: p.bytes.length });
    const body = JSON.parse(late.body);
    h.clock.advance(301_000);
    const rec = (await h.publishes.getUpload(body.upload_id))!;
    expect(await h.s3.put(rec.key, { url: body.put_url, headers: body.put_headers }, p.bytes, h.clock.now(), new Date(body.expires_at))).toBe('expired');
  });

  test('begin answers with the key under quarantine/, the exact length and the base64 sha256, and a short expiry', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const p = pkg({ name: 'demo', version: '1.0.0' });
    const res = await h.call('POST', '/api/v1/packages/demo/1.0.0/files', me.token, { subdir: 'noarch', filename: p.filename, sha256: p.sha256, size: p.bytes.length });
    expect(res.statusCode).toBe(200);
    const body = JSON.parse(res.body);
    const rec = (await h.publishes.getUpload(body.upload_id))!;
    expect(rec.key).toBe(`quarantine/${body.upload_id}/${p.filename}`);
    expect(body.put_headers).toEqual({ 'content-length': String(p.bytes.length), 'x-amz-checksum-sha256': Buffer.from(p.sha256, 'hex').toString('base64') });
    expect(Date.parse(body.expires_at) - h.clock.now().getTime()).toBe(300_000);
  });
});

describe('rejections', () => {
  async function rejected(h: Harness, token: string, p: ReturnType<typeof pkg>, opts: { bytes?: Buffer; sha256?: string } = {}) {
    // The fake S3 would refuse wrong bytes; the validator must still refuse them if they ever got there.
    const begin = await h.call('POST', `/api/v1/packages/${p.name}/${p.version}/files`, token, {
      subdir: p.subdir,
      filename: p.filename,
      sha256: opts.sha256 ?? p.sha256,
      size: (opts.bytes ?? p.bytes).length,
    });
    expect(begin.statusCode).toBe(200);
    const uploadId = JSON.parse(begin.body).upload_id as string;
    const rec = (await h.publishes.getUpload(uploadId))!;
    await h.objects.put(rec.key, opts.bytes ?? p.bytes, { contentType: 'application/octet-stream' });
    const c = await h.commit(token, p.name, p.version, [uploadId], p.manifest);
    expect(c.statusCode).toBe(202);
    await h.runValidator();
    return { id: JSON.parse(c.body).publish_id as string, rec };
  }

  test('an archive that is not a package: rejected with the validator code, quarantine emptied, repodata untouched, number burned', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const p = pkg({ name: 'demo', version: '1.0.0' });
    const junk = Buffer.from('this is not an archive');
    const { id } = await rejected(h, me.token, p, { bytes: junk, sha256: sha256(junk) });
    const st = await h.status(me.token, id);
    expect(st.body).toMatchObject({ status: 'rejected', rejection_code: 'archive_invalid', message: expect.stringContaining('neither a .conda') });
    expect(h.objects.keys('quarantine/')).toEqual([]);
    expect(h.objects.keys('noarch/')).toEqual([]);
    expect(h.indexQueue.sent).toEqual([]);
    const v = (await h.registry.getVersion('demo', '1.0.0'))!;
    expect(v.state).toBe('tombstoned');
    expect(v.tombstone?.reason_code).toBe('archive_invalid');
    expect(v.files).toEqual([]);
    // The number is burned: a new begin for it (even spelled 1.0) is version_exists.
    const again = await h.call('POST', '/api/v1/packages/demo/1.0/files', me.token, { subdir: 'noarch', filename: 'mojo-demo-1.0-mojo1.0.0_0.conda', sha256: p.sha256, size: 10 });
    expect(again.statusCode).toBe(409);
    expect(JSON.parse(again.body).error.code).toBe('version_exists');
  });

  test('bytes that do not hash to the declared sha256: sha256_mismatch', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const p = pkg({ name: 'demo', version: '1.0.0' });
    const { id } = await rejected(h, me.token, p, { sha256: sha256('something else') });
    expect((await h.status(me.token, id)).body).toMatchObject({ status: 'rejected', rejection_code: 'sha256_mismatch' });
  });

  test('a package whose metadata names another package: manifest_invalid', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const p = pkg({ name: 'demo', version: '1.0.0', mopm: { name: 'other' } });
    const { id } = await rejected(h, me.token, p);
    expect((await h.status(me.token, id)).body).toMatchObject({ status: 'rejected', rejection_code: 'manifest_invalid' });
  });

  test('a declared manifest hash that is not the embedded manifest: sha256_mismatch', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const p = pkg({ name: 'demo', version: '1.0.0' });
    const u = await h.upload(me.token, p);
    const c = await h.commit(me.token, 'demo', '1.0.0', [u.upload_id!], sha256('not the manifest'));
    await h.runValidator();
    expect((await h.status(me.token, JSON.parse(c.body).publish_id)).body).toMatchObject({ status: 'rejected', rejection_code: 'sha256_mismatch' });
  });

  test('two files of one version built with different compilers: manifest_invalid, and nothing reaches the channel', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    // Each archive is valid on its own (its file name, metadata and build agree); together they are not one version.
    const a = pkg({ name: 'demo', version: '1.0.0', subdir: 'linux-64', compiler: '1.0.0' });
    const b = pkg({ name: 'demo', version: '1.0.0', subdir: 'osx-arm64', compiler: '1.1.0' });
    const ua = await h.upload(me.token, a);
    const ub = await h.upload(me.token, b);
    const c = await h.commit(me.token, 'demo', '1.0.0', [ua.upload_id!, ub.upload_id!], a.manifest);
    expect(c.statusCode).toBe(202);
    await h.runValidator();
    expect((await h.status(me.token, JSON.parse(c.body).publish_id)).body).toMatchObject({
      status: 'rejected',
      rejection_code: 'manifest_invalid',
      message: expect.stringContaining('disagrees'),
    });
    expect(h.objects.keys('linux-64/')).toEqual([]);
    expect(h.objects.keys('osx-arm64/')).toEqual([]);
    expect(h.objects.keys('quarantine/')).toEqual([]);
  });

  test('a rejected publish does not disturb the others in the index', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['good', 'bad']);
    const good = pkg({ name: 'good', version: '1.0.0' });
    await h.publish(me.token, good);
    const junk = Buffer.from('nope');
    await rejected(h, me.token, pkg({ name: 'bad', version: '1.0.0' }), { bytes: junk, sha256: sha256(junk) });
    await h.runValidator();
    await h.runIndexer();
    expect(Object.keys(h.repodata('noarch')['packages.conda'])).toEqual([good.filename]);
  });
});

describe('commit', () => {
  test('committing the same uploads again resumes the same publish and queues it once', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const p = pkg({ name: 'demo', version: '1.0.0' });
    const u = await h.upload(me.token, p);
    const c1 = await h.commit(me.token, 'demo', '1.0.0', [u.upload_id!], p.manifest);
    const c2 = await h.commit(me.token, 'demo', '1.0.0', [u.upload_id!], p.manifest);
    expect(c1.statusCode).toBe(202);
    expect(c2.statusCode).toBe(202);
    expect(JSON.parse(c2.body)).toEqual(JSON.parse(c1.body));
    expect(JSON.parse(c1.body).status_url).toBe(`/api/v1/publishes/${JSON.parse(c1.body).publish_id}`);
    expect(h.validateQueue.sent).toHaveLength(1);
    expect(h.validateQueue.sent[0]).toMatchObject({ groupId: 'demo', dedupId: JSON.parse(c1.body).publish_id });
  });

  test('upload_invalid: a file that was never uploaded, an unknown id, another caller\'s upload, another version\'s upload', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const other = await h.account(2, 'b', ['demo']);
    const p = pkg({ name: 'demo', version: '1.0.0' });
    const begun = await h.upload(me.token, p, { bytes: Buffer.concat([p.bytes, Buffer.from('x')]) }); // refused by S3: nothing stored
    expect(begun.put).toBe('bad_length');
    const code = async (r: ReturnType<Harness['commit']>) => JSON.parse((await r).body).error?.code;
    expect(await code(h.commit(me.token, 'demo', '1.0.0', [begun.upload_id!], p.manifest))).toBe('upload_invalid');
    expect(await code(h.commit(me.token, 'demo', '1.0.0', ['upl_unknown'], p.manifest))).toBe('upload_invalid');
    const ok = await h.upload(me.token, p);
    expect(await code(h.commit(other.token, 'demo', '1.0.0', [ok.upload_id!], p.manifest))).toBe('upload_invalid');
    expect(await code(h.commit(me.token, 'demo', '1.0.1', [ok.upload_id!], p.manifest))).toBe('upload_invalid');
  });

  test('upload_used: an upload that a publish already took cannot join another one', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const p = pkg({ name: 'demo', version: '1.0.0', subdir: 'linux-64' });
    const q = pkg({ name: 'demo', version: '1.0.0', subdir: 'osx-arm64' });
    const up = await h.upload(me.token, p);
    const uq = await h.upload(me.token, q);
    expect((await h.commit(me.token, 'demo', '1.0.0', [up.upload_id!], p.manifest)).statusCode).toBe(202);
    // A second commit of the same version with another set is refused; and so is reusing the taken id.
    const second = await h.commit(me.token, 'demo', '1.0.0', [up.upload_id!, uq.upload_id!], p.manifest);
    expect(second.statusCode).toBe(409);
    expect(JSON.parse(second.body).error.code).toBe('upload_used');
  });

  test('a different set of uploads for a version that has a publish is version_exists', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const p = pkg({ name: 'demo', version: '1.0.0' });
    const u1 = await h.upload(me.token, p);
    const u2 = await h.upload(me.token, p);
    expect((await h.commit(me.token, 'demo', '1.0.0', [u1.upload_id!], p.manifest)).statusCode).toBe(202);
    const res = await h.commit(me.token, 'demo', '1.0.0', [u2.upload_id!], p.manifest);
    expect(res.statusCode).toBe(409);
    expect(JSON.parse(res.body).error).toMatchObject({ code: 'version_exists', message: expect.stringContaining(p.sha256) });
  });

  test('status is visible only to the caller who made the publish', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const other = await h.account(2, 'b', ['demo2']);
    const id = await h.publish(me.token, pkg({ name: 'demo', version: '1.0.0' }));
    const r = await h.call('GET', `/api/v1/publishes/${id}`, other.token);
    expect(r.statusCode).toBe(404);
    expect(JSON.parse(r.body).error.code).toBe('publish_not_found');
    expect((await h.call('GET', '/api/v1/publishes/pub_nothing', me.token)).statusCode).toBe(404);
  });
});

describe('begin: names, versions, owners and the version number', () => {
  const body = (p: ReturnType<typeof pkg>) => ({ subdir: p.subdir, filename: p.filename, sha256: p.sha256, size: p.bytes.length });
  const err = (r: { body: string }) => JSON.parse(r.body).error.code as string;

  test('1.0 and 1.0.0 are one version: the second begin after a commit is version_exists; before a commit the reservation is shared', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const p = pkg({ name: 'demo', version: '1.0.0' });
    const q = pkg({ name: 'demo', version: '1.0' });
    // Before any commit the number is only reserved: a second begin (same or equivalent spelling) joins it.
    expect((await h.call('POST', '/api/v1/packages/demo/1.0.0/files', me.token, body(p))).statusCode).toBe(200);
    expect((await h.call('POST', '/api/v1/packages/demo/1.0/files', me.token, body(q))).statusCode).toBe(200);
    // Once a publish holds it, no begin gets in.
    await h.publish(me.token, p);
    const r = await h.call('POST', '/api/v1/packages/demo/1.0/files', me.token, body(q));
    expect(r.statusCode).toBe(409);
    expect(err(r)).toBe('version_exists');
    // ... and after it is published as well.
    await h.runValidator();
    await h.runIndexer();
    expect(err(await h.call('POST', '/api/v1/packages/demo/1/files', me.token, body(pkg({ name: 'demo', version: '1' }))))).toBe('version_exists');
  });

  test('two begins at once for a new version both succeed; two commits at once: exactly one wins', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const p = pkg({ name: 'demo', version: '2.0.0' });
    const [a, b] = await Promise.all([h.upload(me.token, p), h.upload(me.token, p)]);
    expect([a.res.statusCode, b.res.statusCode]).toEqual([200, 200]);
    const [c1, c2] = await Promise.all([h.commit(me.token, 'demo', '2.0.0', [a.upload_id!], p.manifest), h.commit(me.token, 'demo', '2.0.0', [b.upload_id!], p.manifest)]);
    expect([c1.statusCode, c2.statusCode].sort()).toEqual([202, 409]);
    expect(h.validateQueue.sent).toHaveLength(1);
  });

  test('invalid name, invalid version, unknown package, wrong subdir, bad file name, bad sha256, bad size', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const p = pkg({ name: 'demo', version: '1.0.0' });
    const good = body(p);
    const post = (path: string, b: unknown) => h.call('POST', path, me.token, b);
    // the token's scope is for 'demo'; a name it does not cover is scope_missing before anything else
    expect(err(await post('/api/v1/packages/Demo/1.0.0/files', good))).toBe('scope_missing');
    expect(err(await post('/api/v1/packages/demo/one/files', good))).toBe('invalid_version');
    expect(err(await post('/api/v1/packages/demo/1.0.0/files', { ...good, subdir: 'win-64' }))).toBe('invalid_request');
    expect(err(await post('/api/v1/packages/demo/1.0.0/files', { ...good, filename: '../x.conda' }))).toBe('invalid_request');
    expect(err(await post('/api/v1/packages/demo/1.0.0/files', { ...good, filename: 'mojo-demo-2.0.0-mojo1.0.0_0.conda' }))).toBe('upload_invalid');
    expect(err(await post('/api/v1/packages/demo/1.0.0/files', { ...good, filename: 'mojo-demo-1.0.0-build.conda' }))).toBe('upload_invalid');
    expect(err(await post('/api/v1/packages/demo/1.0.0/files', { ...good, sha256: 'ABC' }))).toBe('invalid_request');
    expect(err(await post('/api/v1/packages/demo/1.0.0/files', { ...good, size: 0 }))).toBe('invalid_request');
    expect(err(await post('/api/v1/packages/demo/1.0.0/files', { ...good, size: 1.5 }))).toBe('invalid_request');
    expect(err(await post('/api/v1/packages/demo/1.0.0/files', '[1]'))).toBe('invalid_request');
    expect(err(await post('/api/v1/packages/demo/1.0.0/files', '{not json'))).toBe('invalid_request');
    expect(h.publishes.uploads.size).toBe(0);
    expect((await h.registry.listVersions('demo')).length).toBe(0);

    // a token that covers a name that is not claimed
    const ghost = await h.token(1, ['ghost'], ['publish']);
    const g = pkg({ name: 'ghost', version: '1.0.0' });
    expect(err(await h.call('POST', '/api/v1/packages/ghost/1.0.0/files', ghost, body(g)))).toBe('package_not_found');
  });

  test('a token outlives an ownership change: a removed owner is refused (not_owner) although the token still names the package', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const p = pkg({ name: 'demo', version: '1.0.0' });
    await h.registry.removeOwner('demo', 1);
    const r = await h.call('POST', '/api/v1/packages/demo/1.0.0/files', me.token, body(p));
    expect(r.statusCode).toBe(403);
    expect(err(r)).toBe('not_owner');
  });
});
