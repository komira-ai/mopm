import { MemoryNamespaceStore, NamespaceAccess } from '../../src/auth';
import { publishIdFor } from '../../src/publish/service';
import { audit } from '../helpers';
import { Harness, pkg, sha256, type Pkg } from './harness';

/**
 * One more build for a published version, through the single publish (begin, commit, validator, index writer) over the real
 * router, service, state machine, validator and writers. Only the ports are fakes. A build is the files of a version built
 * with one Mojo compiler; the version carries the source digest its builds share (`source_sha256` of the package metadata).
 */

const SOURCES = sha256('the package sources');
const err = (r: { body: string }) => JSON.parse(r.body).error as { code: string; message: string; detail?: Record<string, string> };
const body = (r: { body: string }) => JSON.parse(r.body);

/** One file of `demo` 1.0.0: `compiler` names its build, `over` changes the archive (the metadata with the digest by default). */
const file = (compiler: string, subdir = 'linux-64', over: Parameters<typeof pkg>[0] = {}): Pkg =>
  pkg({ name: 'demo', version: '1.0.0', subdir, compiler, mopm: { source_sha256: SOURCES }, ...over });

async function setup(...first: Pkg[]) {
  const h = new Harness();
  const me = await h.account(1, 'a', ['demo']);
  if (first.length > 0) await publishAll(h, me.token, first);
  return { h, me };
}

/** begin and PUT of each file, one commit of them all (`extra`: more commit fields); the publish id. */
async function commitAll(h: Harness, token: string, files: Pkg[], manifest = files[0]!.manifest, extra: Record<string, unknown> = {}): Promise<string> {
  const ids: string[] = [];
  for (const f of files) {
    const u = await h.upload(token, f);
    expect(u.res.statusCode).toBe(200);
    ids.push(u.upload_id!);
  }
  const c = await h.commit(token, 'demo', '1.0.0', ids, manifest, extra);
  expect(c.statusCode).toBe(202);
  return body(c).publish_id as string;
}

/** The whole publish: the validator and the index writer run after the commit. */
async function publishAll(h: Harness, token: string, files: Pkg[], extra: Record<string, unknown> = {}): Promise<string> {
  const id = await commitAll(h, token, files, files[0]!.manifest, extra);
  await h.runValidator();
  await h.runIndexer();
  return id;
}

const ROW = '1.0.0+mojo1.1.0_0';
/** A commit that declares no manifest (it is optional): only the validator compares the archive with the version. */
const NO_MANIFEST = { manifest_sha256: undefined };

describe('a build added to a published version', () => {
  test('the version then lists both builds: repodata has both files with their own compiler pins, the top level stays the first build, and the stored version row is untouched', async () => {
    const first = file('1.0.0');
    const added = file('1.1.0');
    const { h, me } = await setup(first);
    const before = (await h.registry.getVersion('demo', '1.0.0'))!;

    const id = await publishAll(h, me.token, [added]);
    expect((await h.status(me.token, id)).body).toEqual({ publish_id: id, name: 'demo', version: '1.0.0', status: 'published' });

    const [folded] = await h.registry.listVersions('demo');
    expect(folded!.files.map((f) => f.filename).sort()).toEqual([first.filename, added.filename].sort());
    expect(folded).toMatchObject({ state: 'published', build: 'mojo1.0.0_0', requires_mojo: '==1.0.0', manifest_sha256: first.manifest });
    const repo = h.repodata('linux-64')['packages.conda'];
    expect(repo[first.filename]).toMatchObject({ build: 'mojo1.0.0_0', depends: ['mojo-compiler ==1.0.0'] });
    expect(repo[added.filename]).toMatchObject({ build: 'mojo1.1.0_0', depends: ['mojo-compiler ==1.1.0'], sha256: added.sha256 });
    expect(sha256((await h.objects.get(`linux-64/${added.filename}`))!)).toBe(added.sha256);

    // The version's own row is as it was; the build is a row of its own, keyed <version>+<build>, in the version's spelling.
    expect(await h.registry.getVersion('demo', '1.0.0')).toEqual(before);
    expect(await h.registry.getVersion('demo', ROW)).toMatchObject({
      canonical: ROW,
      version: '1.0.0',
      state: 'published',
      build: 'mojo1.1.0_0',
      requires_mojo: '==1.1.0',
      manifest_sha256: first.manifest,
      files: [{ subdir: 'linux-64', filename: added.filename, sha256: added.sha256, url: `https://conda.example.invalid/linux-64/${added.filename}` }],
    });
    expect(h.objects.keys('quarantine/')).toEqual([]);
    expect(h.invalidator.batches.at(-1)!.paths).toEqual(['/linux-64/repodata.json', '/linux-64/repodata.json.zst']);
  });

  test('the publish is keyed by the build row: its record and upload carry it, the status answers the version spelling, and the audit names the build', async () => {
    const { h, me } = await setup(file('1.0.0'));
    const added = file('1.1.0');
    const u = await h.upload(me.token, added);
    expect((await h.publishes.getUpload(u.upload_id!))!).toMatchObject({ version: '1.0.0', canonical: ROW });
    const c = await h.commit(me.token, 'demo', '1.0.0', [u.upload_id!], added.manifest);
    const id = body(c).publish_id as string;
    expect(id).toBe(publishIdFor('demo', ROW, [u.upload_id!]));
    expect(id).not.toBe(publishIdFor('demo', '1.0.0', [u.upload_id!]));
    expect(await h.publishes.getPublish(id)).toMatchObject({ version: '1.0.0', canonical: ROW, status: 'pending' });
    expect(await h.publishes.versionHolder('demo', ROW)).toBe(id);
    expect((await h.status(me.token, id)).body).toMatchObject({ version: '1.0.0', status: 'pending' });
    // Pending, the added build shows nowhere.
    expect((await h.registry.listVersions('demo'))[0]!.files).toHaveLength(1);

    await h.runValidator();
    expect((await h.status(me.token, id)).body).toMatchObject({ version: '1.0.0', status: 'indexing' });
    const entries = await h.registry.listAudit('demo');
    expect(entries.find((e) => e.action === 'publish_begin' && e.detail?.build === 'mojo1.1.0_0')).toMatchObject({ version: '1.0.0' });
    expect(entries.find((e) => e.action === 'publish' && e.detail?.build === 'mojo1.1.0_0')).toMatchObject({ version: '1.0.0', detail: { publish_id: id, files: '1', build: 'mojo1.1.0_0' } });
    expect(entries.filter((e) => e.action === 'publish_begin').map((e) => e.detail)).toEqual([undefined, { build: 'mojo1.1.0_0' }]);
  });

  test('an add can carry the display fields and a source commit; they are not written to the version or its row', async () => {
    const { h, me } = await setup(file('1.0.0'));
    await publishAll(h, me.token, [file('1.1.0')], { description: 'another build', source_commit: 'a'.repeat(40) });
    const row = (await h.registry.getVersion('demo', ROW))!;
    expect(row.description).toBeUndefined();
    expect(row.source_commit).toBeUndefined();
    expect((await h.registry.getVersion('demo', '1.0.0'))!.description).toBeUndefined();
  });

  test('a lower compiler becomes the primary build, and a build on another platform adds its platform to the version', async () => {
    const { h, me } = await setup(file('1.1.0', 'linux-64'));
    await publishAll(h, me.token, [file('1.0.0', 'osx-arm64')]);
    const [v] = await h.registry.listVersions('demo');
    expect(v).toMatchObject({ build: 'mojo1.0.0_0', requires_mojo: '==1.0.0' });
    expect(v!.files.map((f) => f.subdir).sort()).toEqual(['linux-64', 'osx-arm64']);
    expect(Object.keys(h.repodata('osx-arm64')['packages.conda'])).toHaveLength(1);
    expect(Object.keys(h.repodata('linux-64')['packages.conda'])).toHaveLength(1);
  });

  test('committing the same uploads again resumes the same publish and queues it once', async () => {
    const { h, me } = await setup(file('1.0.0'));
    const added = file('1.1.0');
    const u = await h.upload(me.token, added);
    const c1 = await h.commit(me.token, 'demo', '1.0.0', [u.upload_id!], added.manifest);
    const c2 = await h.commit(me.token, 'demo', '1.0.0', [u.upload_id!], added.manifest);
    expect(c2.statusCode).toBe(202);
    expect(body(c2).publish_id).toBe(body(c1).publish_id);
    expect(h.publishes.publishes.size).toBe(2);
    expect(h.validateQueue.sent.map((m) => m.dedupId)).toEqual([body(c1).publish_id as string]);
  });

  test('a quota check counts the files of every build: a third build over the limit is refused at begin', async () => {
    const a = file('1.0.0');
    const b = file('1.1.0');
    const { h, me } = await setup(a);
    await publishAll(h, me.token, [b]);
    h.config.projectQuotaBytes = a.bytes.length + b.bytes.length + 1;
    h.build();
    const c = file('1.2.0');
    const res = (await h.upload(me.token, c)).res;
    expect(res.statusCode).toBe(403);
    expect(err(res).message).toBe(`Adding this file would put 'demo' over its storage limit of ${a.bytes.length + b.bytes.length + 1} bytes; 1 bytes are left.`);
  });
});

describe('a build the version already has is refused', () => {
  test('begin of the same build again (a replaced file) is version_exists with the sha256 of the file the version has; nothing is reserved', async () => {
    const first = file('1.0.0');
    const { h, me } = await setup(first);
    const rows = [...(await h.registry.versionsOf(['demo'], { kind: 'api', rows: true })).get('demo')!];
    const uploads = h.publishes.uploads.size;
    const again = file('1.0.0', 'linux-64', { mopm: { source_sha256: SOURCES, deps: [] } });
    for (const f of [again, file('1.0.0', 'osx-arm64')]) {
      const u = await h.upload(me.token, f);
      expect(u.res.statusCode).toBe(409);
      expect(err(u.res)).toEqual({
        code: 'version_exists',
        message: `'demo' 1.0.0 already exists (sha256 ${first.sha256}); versions are immutable.`,
        hint: 'Publish a new version.',
      });
    }
    expect(h.publishes.uploads.size).toBe(uploads);
    expect(await h.registry.versionsOf(['demo'], { kind: 'api', rows: true })).toEqual(new Map([['demo', rows]]));
  });

  test('a build that was added is also refused, the second time', async () => {
    const { h, me } = await setup(file('1.0.0'));
    const added = file('1.1.0');
    await publishAll(h, me.token, [added]);
    const u = await h.upload(me.token, added);
    expect(u.res.statusCode).toBe(409);
    expect(err(u.res).message).toBe(`'demo' 1.0.0 already exists (sha256 ${added.sha256}); versions are immutable.`);
  });

  test('a pending add is joined by a second begin of the same build; once one commit wins, the other is version_exists', async () => {
    const { h, me } = await setup(file('1.0.0'));
    const added = file('1.1.0');
    const a = await h.upload(me.token, added);
    const b = await h.upload(me.token, added);
    expect([a.res.statusCode, b.res.statusCode]).toEqual([200, 200]);
    const [ca, cb] = await Promise.all([
      h.commit(me.token, 'demo', '1.0.0', [a.upload_id!], added.manifest),
      h.commit(me.token, 'demo', '1.0.0', [b.upload_id!], added.manifest),
    ]);
    expect([ca.statusCode, cb.statusCode].sort()).toEqual([202, 409]);
    const loser = ca.statusCode === 409 ? ca : cb;
    expect(err(loser)).toMatchObject({ code: 'version_exists', message: expect.stringContaining("'demo' 1.0.0 already exists") });
    expect(h.publishes.publishes.size).toBe(2);
    await h.runValidator();
    await h.runIndexer();
    expect((await h.registry.listVersions('demo'))[0]!.files).toHaveLength(2);
  });

  test('two concurrent adds of two different builds both land', async () => {
    const { h, me } = await setup(file('1.0.0'));
    const b = file('1.1.0');
    const c = file('1.2.0');
    const ub = await h.upload(me.token, b);
    const uc = await h.upload(me.token, c);
    const [cb, cc] = await Promise.all([h.commit(me.token, 'demo', '1.0.0', [ub.upload_id!], b.manifest), h.commit(me.token, 'demo', '1.0.0', [uc.upload_id!], c.manifest)]);
    expect([cb.statusCode, cc.statusCode]).toEqual([202, 202]);
    await h.runValidator();
    await h.runIndexer();
    expect((await h.registry.listVersions('demo'))[0]!.files).toHaveLength(3);
  });
});

describe('a version that is not published takes no build', () => {
  test.each([
    ['yanked', { type: 'yank', reason: 'broken' }],
    ['taken down', { type: 'tombstone', reason_code: 'archive_invalid', date: '2026-11-21' }],
  ] as const)('%s: begin answers version_exists with the version and no build, and reserves nothing', async (_state, event) => {
    const first = file('1.0.0');
    const { h, me } = await setup(first);
    await h.registry.updateVersion('demo', '1.0.0', event, audit('demo', event.type, '1.0.0'));
    const uploads = h.publishes.uploads.size;
    const u = await h.upload(me.token, file('1.1.0'));
    expect(u.res.statusCode).toBe(409);
    expect(err(u.res).message).toBe(`'demo' 1.0.0 already exists (sha256 ${first.sha256}); versions are immutable.`);
    expect(await h.registry.getVersion('demo', ROW)).toBeUndefined();
    expect(h.publishes.uploads.size).toBe(uploads);
  });

  test('yanked after the begin: commit is version_exists, nothing is claimed and the build is free for later', async () => {
    const { h, me } = await setup(file('1.0.0'));
    const added = file('1.1.0');
    const u = await h.upload(me.token, added);
    await h.registry.updateVersion('demo', '1.0.0', { type: 'yank', reason: 'broken' }, audit('demo', 'yank', '1.0.0'));
    const c = await h.commit(me.token, 'demo', '1.0.0', [u.upload_id!], added.manifest);
    expect(c.statusCode).toBe(409);
    expect(err(c).code).toBe('version_exists');
    expect(h.publishes.locks.size).toBe(1);
    expect(await h.publishes.versionHolder('demo', ROW)).toBeUndefined();
    expect(h.publishes.publishes.size).toBe(1);
    expect((await h.registry.getVersion('demo', ROW))!.state).toBe('pending');
    await h.registry.updateVersion('demo', '1.0.0', { type: 'unyank' }, audit('demo', 'unyank', '1.0.0'));
    expect((await h.commit(me.token, 'demo', '1.0.0', [u.upload_id!], added.manifest)).statusCode).toBe(202);
  });

  test('yanked after the commit: the validator rejects the add, burns the build row only, and the version stays yanked with its one build', async () => {
    const first = file('1.0.0');
    const { h, me } = await setup(first);
    const id = await commitAll(h, me.token, [file('1.1.0')]);
    await h.registry.updateVersion('demo', '1.0.0', { type: 'yank', reason: 'broken' }, audit('demo', 'yank', '1.0.0'));
    await h.runValidator();
    expect((await h.status(me.token, id)).body).toEqual({
      publish_id: id,
      name: 'demo',
      version: '1.0.0',
      status: 'rejected',
      rejection_code: 'manifest_invalid',
      message: 'demo 1.0.0 is yanked, so no build can be added to it: only a published version takes one',
    });
    expect(await h.registry.getVersion('demo', ROW)).toMatchObject({ state: 'tombstoned', files: [] });
    expect(await h.registry.getVersion('demo', '1.0.0')).toMatchObject({ state: 'yanked', files: [{ filename: first.filename }] });
    expect(h.objects.keys('quarantine/')).toEqual([]);
    expect(h.objects.keys('linux-64/').filter((k) => k.includes('mojo1.1.0'))).toEqual([]);
  });

  test('the version row gone after the commit: the validator rejects the add as missing', async () => {
    const { h, me } = await setup(file('1.0.0'));
    const id = await commitAll(h, me.token, [file('1.1.0')]);
    await h.registry.deleteVersionRow('demo', '1.0.0');
    await h.runValidator();
    expect((await h.status(me.token, id)).body).toMatchObject({ status: 'rejected', message: 'demo 1.0.0 is missing, so no build can be added to it: only a published version takes one' });
  });

  test('the version row gone between begin and commit: commit is version_exists with the upload sha256', async () => {
    const { h, me } = await setup(file('1.0.0'));
    const added = file('1.1.0');
    const u = await h.upload(me.token, added);
    await h.registry.deleteVersionRow('demo', '1.0.0');
    const c = await h.commit(me.token, 'demo', '1.0.0', [u.upload_id!], added.manifest);
    expect(c.statusCode).toBe(409);
    expect(err(c).message).toBe(`'demo' 1.0.0 already exists (sha256 ${added.sha256}); versions are immutable.`);
  });
});

describe('the add must come from the same source as the version', () => {
  test('a commit that declares another manifest than the version is version_exists before anything is claimed; the build row is not burned, and a correct add after it lands', async () => {
    const first = file('1.0.0');
    const { h, me } = await setup(first);
    const added = file('1.1.0');
    const u = await h.upload(me.token, added);
    const other = sha256('another manifest');
    const c = await h.commit(me.token, 'demo', '1.0.0', [u.upload_id!], other);
    expect(c.statusCode).toBe(409);
    expect(err(c).message).toBe(`'demo' 1.0.0 already exists (sha256 ${first.manifest}); versions are immutable.`);
    expect(h.publishes.locks.size).toBe(1);
    expect(h.publishes.publishes.size).toBe(1);
    expect((await h.publishes.getUpload(u.upload_id!))!.used_by).toBeUndefined();
    expect(await h.registry.getVersion('demo', ROW)).toMatchObject({ state: 'pending' });

    const id = await publishAll(h, me.token, [added]);
    expect((await h.status(me.token, id)).body.status).toBe('published');
    expect((await h.registry.listVersions('demo'))[0]!.files).toHaveLength(2);
  });

  test('an archive with another manifest than the version, declared truthfully, is rejected by the validator with the manifest hashes named; the version is untouched and the build row is burned', async () => {
    const first = file('1.0.0');
    const { h, me } = await setup(first);
    const before = (await h.registry.getVersion('demo', '1.0.0'))!;
    const other = file('1.1.0', 'linux-64', { mopm: { source_sha256: sha256('other sources') } });
    // The commit declares no manifest (it is optional), so only the validator compares the archive with the version.
    const id = await commitAll(h, me.token, [other], other.manifest, NO_MANIFEST);
    await h.runValidator();
    const status = (await h.status(me.token, id)).body;
    expect(status).toMatchObject({ status: 'rejected', rejection_code: 'manifest_invalid' });
    expect(status.message).toBe(
      `the linux-64 file has manifest ${other.manifest} but demo 1.0.0 has ${first.manifest}: a build added to a version must come from the same source: the same <import>.mopm.json, including source_sha256`,
    );
    expect(await h.registry.getVersion('demo', '1.0.0')).toEqual(before);
    expect((await h.registry.listVersions('demo'))[0]).toMatchObject({ state: 'published', files: [{ filename: first.filename }] });
    expect(await h.registry.getVersion('demo', ROW)).toMatchObject({ state: 'tombstoned', tombstone: { reason_code: 'manifest_invalid' } });
    expect(h.objects.keys('linux-64/').filter((k) => k.endsWith('.conda'))).toEqual([`linux-64/${first.filename}`]);
    // The rejected build is burned, as a rejected version is.
    expect((await h.upload(me.token, file('1.1.0'))).res.statusCode).toBe(409);
  });

  test('an archive that differs from the manifest the commit declared (the version\'s own) is rejected by the validator as any archive is, and the build row is burned', async () => {
    const first = file('1.0.0');
    const { h, me } = await setup(first);
    const other = file('1.1.0', 'linux-64', { mopm: { source_sha256: sha256('other sources') } });
    const id = await commitAll(h, me.token, [other], first.manifest);
    await h.runValidator();
    expect((await h.status(me.token, id)).body).toMatchObject({ status: 'rejected', rejection_code: 'sha256_mismatch' });
    expect(await h.registry.getVersion('demo', ROW)).toMatchObject({ state: 'tombstoned' });
    expect((await h.registry.listVersions('demo'))[0]).toMatchObject({ state: 'published', files: [{ filename: first.filename }] });
  });

  test('an add whose metadata has no source_sha256, to a version that has one, differs in its manifest and is rejected', async () => {
    const first = file('1.0.0');
    const { h, me } = await setup(first);
    const without = file('1.1.0', 'linux-64', { mopm: {} });
    const id = await commitAll(h, me.token, [without], without.manifest, NO_MANIFEST);
    await h.runValidator();
    expect((await h.status(me.token, id)).body).toMatchObject({
      status: 'rejected',
      message: expect.stringContaining(`has manifest ${without.manifest} but demo 1.0.0 has ${first.manifest}`),
    });
  });

  test('a version published without a source digest takes no build, even from the same manifest: it says so', async () => {
    const first = file('1.0.0', 'linux-64', { mopm: {} });
    const { h, me } = await setup(first);
    const added = file('1.1.0', 'linux-64', { mopm: {} });
    expect(added.manifest).toBe(first.manifest);
    const id = await commitAll(h, me.token, [added]);
    await h.runValidator();
    expect((await h.status(me.token, id)).body).toMatchObject({
      status: 'rejected',
      rejection_code: 'manifest_invalid',
      message: 'demo 1.0.0 carries no source digest, so no build can be added to it: publish a new version',
    });
    expect((await h.registry.listVersions('demo'))[0]).toMatchObject({ state: 'published', files: [{ filename: first.filename }] });
  });

  test('an add with other system libraries than the version is rejected naming both lists', async () => {
    const { h, me } = await setup(file('1.0.0'));
    const added = file('1.1.0', 'linux-64', { index: { depends: ['mojo-compiler ==1.1.0', 'libopenssl'] } });
    const id = await commitAll(h, me.token, [added]);
    await h.runValidator();
    expect((await h.status(me.token, id)).body).toMatchObject({
      status: 'rejected',
      rejection_code: 'manifest_invalid',
      message: 'the linux-64 file requires the system libraries [libopenssl] but demo 1.0.0 requires []',
    });
  });
});

describe('what one publish may add', () => {
  test('files of two builds of a published version are two build rows: commit refuses them as one publish, whichever comes first, and claims nothing', async () => {
    const { h, me } = await setup(file('1.0.0'));
    const a = await h.upload(me.token, file('1.1.0', 'linux-64'));
    const b = await h.upload(me.token, file('1.2.0', 'osx-arm64'));
    for (const ids of [[a.upload_id!, b.upload_id!], [b.upload_id!, a.upload_id!]]) {
      const c = await h.commit(me.token, 'demo', '1.0.0', ids, file('1.1.0').manifest);
      expect(c.statusCode).toBe(400);
      expect(err(c).code).toBe('invalid_request');
      expect(err(c).message).toBe('The request is not valid: the uploads are not for one version row: a build added to a published version is one build per publish.');
    }
    expect(h.publishes.locks.size).toBe(1);
    expect(h.publishes.publishes.size).toBe(1);
  });

  test('one upload begun before the version was published and one after (the version row and a build row) are not one publish either', async () => {
    const { h, me } = await setup();
    const plain = file('1.0.0');
    const early = await h.upload(me.token, plain);
    await publishAll(h, me.token, [plain]);
    const late = await h.upload(me.token, file('1.1.0'));
    expect((await h.publishes.getUpload(early.upload_id!))!.canonical).toBe('1.0.0');
    expect((await h.publishes.getUpload(late.upload_id!))!.canonical).toBe(ROW);
    for (const ids of [[early.upload_id!, late.upload_id!], [late.upload_id!, early.upload_id!]]) {
      expect((await h.commit(me.token, 'demo', '1.0.0', ids, plain.manifest)).statusCode).toBe(400);
    }
    // The early one alone is a publish of the version's own number, which is taken.
    const c = await h.commit(me.token, 'demo', '1.0.0', [early.upload_id!], plain.manifest);
    expect(c.statusCode).toBe(409);
  });

  test('a new version may carry several builds in one publish; each is a file of its own, and a later add still takes another build', async () => {
    const { h, me } = await setup();
    const a = file('1.0.0', 'linux-64');
    const b = file('1.1.0', 'linux-64');
    const c = file('1.1.0', 'osx-arm64');
    const id = await publishAll(h, me.token, [a, b, c]);
    expect((await h.status(me.token, id)).body.status).toBe('published');
    const row = (await h.registry.getVersion('demo', '1.0.0'))!;
    expect(row).toMatchObject({ build: 'mojo1.0.0_0', requires_mojo: '==1.0.0' });
    expect(row.files.map((f) => f.filename).sort()).toEqual([a.filename, b.filename, c.filename].sort());
    expect(await h.registry.getVersion('demo', ROW)).toBeUndefined();
    expect(Object.keys(h.repodata('linux-64')['packages.conda']).sort()).toEqual([a.filename, b.filename].sort());
    // Its builds are the version's: a build it has is refused, a build it lacks is added.
    expect((await h.upload(me.token, file('1.1.0', 'linux-aarch64'))).res.statusCode).toBe(409);
    await publishAll(h, me.token, [file('1.2.0')]);
    expect((await h.registry.listVersions('demo'))[0]!.files).toHaveLength(4);
  });
});

describe('yank and unyank act on the whole version, the added builds included', () => {
  test('a build added on another platform is taken out of that platform repodata by a yank and put back by an unyank', async () => {
    const first = file('1.0.0', 'linux-64');
    const added = file('1.1.0', 'osx-arm64');
    const { h, me } = await setup(first);
    await publishAll(h, me.token, [added]);
    expect(Object.keys(h.repodata('osx-arm64')['packages.conda'])).toEqual([added.filename]);

    const yanked = await h.call('PUT', '/api/v1/packages/demo/1.0.0/yank', me.token, { yanked: true, reason: 'broken' });
    expect(yanked.statusCode).toBe(200);
    expect(h.indexQueue.sent.filter((m) => JSON.parse(m.body).type === 'index').map((m) => m.groupId).sort()).toEqual(['linux-64', 'osx-arm64']);
    await h.runIndexer();
    expect(h.repodata('osx-arm64')['packages.conda']).toEqual({});
    expect(h.repodata('osx-arm64').removed).toEqual([added.filename]);
    expect(h.repodata('linux-64').removed).toEqual([first.filename]);

    const back = await h.call('PUT', '/api/v1/packages/demo/1.0.0/yank', me.token, { yanked: false });
    expect(back.statusCode).toBe(200);
    await h.runIndexer();
    expect(Object.keys(h.repodata('osx-arm64')['packages.conda'])).toEqual([added.filename]);
    expect(Object.keys(h.repodata('linux-64')['packages.conda'])).toEqual([first.filename]);
  });
});

describe('a full name: the index line and the version detail list both builds', () => {
  test('the v2 index line has builds, with the top level the first build; getVersion lists both builds in the same order', async () => {
    const h = new Harness();
    const store = new MemoryNamespaceStore();
    const at = h.clock.now().toISOString();
    await store.createNamespace({ namespace: 'alice', kind: 'user', github_id: 7, created_at: at });
    const access = new NamespaceAccess({ namespaces: store, users: h.authStore });
    h.namespaces = access;
    h.v2 = { access, namespaces: store };
    h.build();
    await h.authStore.upsertUser(7, 'alice', at);
    await h.registry.createPackage({ name: 'alice/json', state: 'active', created_at: at });
    const token = await h.token(7, ['alice/json'], ['publish']);
    const make = (compiler: string) => pkg({ name: 'alice/json', version: '1.0.0', subdir: 'linux-64', compiler, mopm: { source_sha256: SOURCES } });
    const put = async (...files: Pkg[]) => {
      const ids: string[] = [];
      for (const f of files) {
        const res = await h.call('POST', `/api/v2/packages/${f.name}/${f.version}/files`, token, { subdir: f.subdir, filename: f.filename, sha256: f.sha256, size: f.bytes.length });
        expect(res.statusCode).toBe(200);
        const up = (await h.publishes.getUpload(body(res).upload_id))!;
        await h.objects.put(up.key, f.bytes, { contentType: 'application/octet-stream' });
        ids.push(up.upload_id);
      }
      const done = await h.call('POST', '/api/v2/packages/alice/json/1.0.0/publish', token, { upload_ids: ids, manifest_sha256: files[0]!.manifest });
      expect(done.statusCode).toBe(202);
      await h.runValidator();
      await h.runIndexer();
      return body(done).publish_id as string;
    };
    const first = make('1.0.0');
    const added = make('1.1.0');
    await put(first);
    const id = await put(added);
    expect(JSON.parse((await h.call('GET', `/api/v2/publishes/${id}`, token)).body)).toMatchObject({ name: 'alice/json', version: '1.0.0', status: 'published' });

    const index = h.indexFile('alice/json')!.trim().split('\n').map((l) => JSON.parse(l));
    expect(index).toHaveLength(1);
    expect(index[0]).toMatchObject({ v: 2, version: '1.0.0', state: 'published', build: 'mojo1.0.0_0', requires_mojo: '==1.0.0' });
    expect(index[0].files.map((f: { filename: string }) => f.filename)).toEqual([first.filename]);
    expect(index[0].builds.map((b: { build: string; files: Array<{ filename: string }> }) => [b.build, b.files.map((f) => f.filename)])).toEqual([
      ['mojo1.0.0_0', [first.filename]],
      ['mojo1.1.0_0', [added.filename]],
    ]);

    const detail = body(await h.call('GET', '/api/v2/packages/alice/json/1.0.0'));
    expect(detail).toMatchObject({ version: '1.0.0', requires_mojo: '==1.0.0' });
    expect(detail.files.map((f: { filename: string }) => f.filename)).toEqual([first.filename]);
    expect(detail.builds.map((b: { build: string; requires_mojo: string }) => [b.build, b.requires_mojo])).toEqual([
      ['mojo1.0.0_0', '==1.0.0'],
      ['mojo1.1.0_0', '==1.1.0'],
    ]);
    expect(await h.call('GET', `/api/v2/packages/alice/json/${encodeURIComponent('1.0.0+mojo1.1.0_0')}`)).toMatchObject({ statusCode: 400 });
  });
});
