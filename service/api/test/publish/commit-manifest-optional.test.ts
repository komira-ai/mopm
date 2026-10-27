import { quarantineKeyFor } from '../../src/publish/group-keys';
import { mopmDefault, type Spec } from '../validate/builder';
import { RIGS, type Rig } from '../group-rig';
import { errorCode, GroupEnv, json } from './group-env';
import { Scenario } from './group-scenario';
import { Harness, pkg, sha256, type Pkg } from './harness';

/**
 * `manifest_sha256` of the two commit requests (a single publish's, and each member of a group's) is optional. Given, it is
 * checked against the hash of the archive's embedded manifest (a bad format is invalid_request, a difference is
 * sha256_mismatch). Absent, the hash the registry computes from the archive is the one the version row holds. Each test names
 * the behaviour it pins.
 */

/** The embedded manifest of `name` written with other white space: the same manifest, other bytes, so another hash. */
const prettyMopm = (name: string): Spec['mopm'] => JSON.stringify(mopmDefault({ name, version: '1.0.0' } as Spec), null, 2);

describe('a single publish commits without manifest_sha256', () => {
  const commitWithout = (h: Harness, token: string, name: string, uploadIds: string[], extra: Record<string, unknown> = {}) =>
    h.call('POST', `/api/v1/packages/${name}/1.0.0/publish`, token, { upload_ids: uploadIds, ...extra });

  test('it is accepted, and the version row holds the hash the registry computed from the archive', async () => {
    const h = new Harness();
    const me = await h.account(1, 'octo', ['demo']);
    const p = pkg({ name: 'demo', version: '1.0.0', subdir: 'noarch' });
    const u = await h.upload(me.token, p);
    const c = await commitWithout(h, me.token, 'demo', [u.upload_id!]);
    expect(c.statusCode).toBe(202);
    // The publish record carries no declared hash: there is none to carry.
    expect([...h.publishes.publishes.values()].map((r) => 'manifest_sha256' in r)).toEqual([false]);
    await h.runValidator();
    expect((await h.status(me.token, JSON.parse(c.body).publish_id)).body.status).toBe('indexing');
    expect((await h.registry.getVersion('demo', '1.0.0'))!.manifest_sha256).toBe(p.manifest);
  });

  test('a hash that is given and right is accepted as before; one that is given and wrong is still sha256_mismatch', async () => {
    const h = new Harness();
    const me = await h.account(1, 'octo', ['demo', 'other']);
    const p = pkg({ name: 'demo', version: '1.0.0', subdir: 'noarch' });
    const q = pkg({ name: 'other', version: '1.0.0', subdir: 'noarch' });
    const ok = await h.upload(me.token, p);
    const bad = await h.upload(me.token, q);
    const a = await h.commit(me.token, 'demo', '1.0.0', [ok.upload_id!], p.manifest);
    const b = await h.commit(me.token, 'other', '1.0.0', [bad.upload_id!], sha256('not the manifest'));
    expect([a.statusCode, b.statusCode]).toEqual([202, 202]);
    await h.runValidator();
    expect((await h.status(me.token, JSON.parse(a.body).publish_id)).body.status).toBe('indexing');
    expect((await h.status(me.token, JSON.parse(b.body).publish_id)).body).toMatchObject({ status: 'rejected', rejection_code: 'sha256_mismatch' });
  });

  test.each([
    ['not a hash', 'abc'],
    ['upper case', 'A'.repeat(64)],
    ['null', null],
    ['a number', 7],
    ['an empty string', ''],
  ])('a value that is given must be 64 lowercase hex digits (%s): invalid_request, and nothing is stored', async (_what, value) => {
    const h = new Harness();
    const me = await h.account(1, 'octo', ['demo']);
    const u = await h.upload(me.token, pkg({ name: 'demo', version: '1.0.0', subdir: 'noarch' }));
    const r = await commitWithout(h, me.token, 'demo', [u.upload_id!], { manifest_sha256: value });
    expect(r.statusCode).toBe(400);
    expect(errorCode(r)).toBe('invalid_request');
    expect(h.publishes.publishes.size).toBe(0);
  });

  test('two files of a version whose manifests differ, with no hash declared: manifest_invalid, and nothing reaches the channel', async () => {
    const h = new Harness();
    const me = await h.account(1, 'octo', ['demo']);
    // Each archive is valid by itself; they carry the same manifest content in other bytes, so there is no one manifest hash for the version.
    const a = pkg({ name: 'demo', version: '1.0.0', subdir: 'linux-64' });
    const b = pkg({ name: 'demo', version: '1.0.0', subdir: 'osx-arm64', mopm: prettyMopm('demo') });
    expect(a.manifest).not.toBe(b.manifest);
    const ua = await h.upload(me.token, a);
    const ub = await h.upload(me.token, b);
    const c = await commitWithout(h, me.token, 'demo', [ua.upload_id!, ub.upload_id!]);
    expect(c.statusCode).toBe(202);
    await h.runValidator();
    expect((await h.status(me.token, JSON.parse(c.body).publish_id)).body).toMatchObject({
      status: 'rejected',
      rejection_code: 'manifest_invalid',
      message: expect.stringContaining('manifest'),
    });
    expect(h.objects.keys('linux-64/')).toEqual([]);
    expect(h.objects.keys('osx-arm64/')).toEqual([]);
    expect(h.objects.keys('quarantine/')).toEqual([]);
  });

  test('two files whose manifests are the same bytes, with no hash declared: published, and the row holds their hash', async () => {
    const h = new Harness();
    const me = await h.account(1, 'octo', ['demo']);
    const a = pkg({ name: 'demo', version: '1.0.0', subdir: 'linux-64' });
    const b = pkg({ name: 'demo', version: '1.0.0', subdir: 'osx-arm64' });
    const ua = await h.upload(me.token, a);
    const ub = await h.upload(me.token, b);
    const c = await commitWithout(h, me.token, 'demo', [ua.upload_id!, ub.upload_id!]);
    expect(c.statusCode).toBe(202);
    await h.runValidator();
    expect((await h.status(me.token, JSON.parse(c.body).publish_id)).body.status).toBe('indexing');
    expect((await h.registry.getVersion('demo', '1.0.0'))!.manifest_sha256).toBe(a.manifest);
  });
});

describe.each(RIGS)('a group commits without manifest_sha256 for some or all members: %s', (_label, make) => {
  let rig: Rig;
  let env: GroupEnv;
  beforeEach(() => {
    rig = make();
    env = new GroupEnv(rig);
  });

  test('every member omitted: accepted, stored without a hash, and each row holds the hash computed from its archive', async () => {
    const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).create();
    await s.upload();
    const r = await s.commit({ members: [{ name: 'alpha' }, { name: 'beta' }] });
    expect(r.statusCode).toBe(202);
    const hash = (await s.header())!.commit_hash!;
    expect(await rig.store.getCommitInput(s.gid, hash, 0)).toEqual({ name: 'alpha' });
    expect(await rig.store.getCommitInput(s.gid, hash, 1)).toEqual({ name: 'beta' });
    expect(await s.runAll()).toEqual(['committed']);
    for (const p of s.pkgs) expect((await s.row(p.name))!.manifest_sha256).toBe(p.manifest);
  });

  test('one member gives its hash and one omits it: both are published with the computed hash', async () => {
    const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).create();
    await s.upload();
    const [a, b] = s.pkgs;
    expect((await s.commit({ members: [{ name: 'alpha', manifest_sha256: a!.manifest }, { name: 'beta' }] })).statusCode).toBe(202);
    const hash = (await s.header())!.commit_hash!;
    expect(await rig.store.getCommitInput(s.gid, hash, 0)).toEqual({ name: 'alpha', manifest_sha256: a!.manifest });
    expect(await rig.store.getCommitInput(s.gid, hash, 1)).toEqual({ name: 'beta' });
    expect(await s.runAll()).toEqual(['committed']);
    expect((await s.row('alpha'))!.manifest_sha256).toBe(a!.manifest);
    expect((await s.row('beta'))!.manifest_sha256).toBe(b!.manifest);
  });

  test('a member that gives a wrong hash is still rejected by name, whether or not the others omit theirs', async () => {
    const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).create();
    await s.upload();
    expect((await s.commit({ members: [{ name: 'alpha' }, { name: 'beta', manifest_sha256: 'e'.repeat(64) }] })).statusCode).toBe(202);
    expect(await s.runAll()).toEqual(['rejected']);
    expect((await s.header())!.failure).toMatchObject({ code: 'sha256_mismatch', member: 'beta' });
  });

  test.each([
    ['not a hash', 'abc'],
    ['null', null],
    ['a number', 7],
  ])('a value that is given must be 64 lowercase hex digits (%s): invalid_request naming the member, and the group stays open', async (_what, value) => {
    const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).create();
    await s.upload();
    const r = await s.commit({ members: [{ name: 'alpha' }, { name: 'beta', manifest_sha256: value }] });
    expect(r.statusCode).toBe(400);
    expect(errorCode(r)).toBe('invalid_request');
    expect(json(r).error.message).toContain("'beta'");
    expect((await s.header())!.status).toBe('open');
    expect(env.groupQueue.sent).toEqual([]);
  });

  test('a retry that gives a hash the first request left out is another request: group_commit_refused; the same request again is the same', async () => {
    const s = await new Scenario(env, [{ name: 'alpha' }]).create();
    await s.upload();
    expect((await s.commit({ members: [{ name: 'alpha' }] })).statusCode).toBe(202);
    expect((await s.commit({ members: [{ name: 'alpha' }] })).statusCode).toBe(202);
    const other = await s.commit({ members: [{ name: 'alpha', manifest_sha256: s.pkgs[0]!.manifest }] });
    expect(other.statusCode).toBe(409);
    expect(errorCode(other)).toBe('group_commit_refused');
  });

  test('a member with two files whose manifests differ and no hash declared: the group is rejected on that member', async () => {
    const token = await env.account(1, 'octocat', ['alpha']);
    const a: Pkg = pkg({ name: 'alpha', version: '1.0.0', subdir: 'linux-64' });
    const b: Pkg = pkg({ name: 'alpha', version: '1.0.0', subdir: 'osx-arm64', mopm: prettyMopm('alpha') });
    expect(a.manifest).not.toBe(b.manifest);
    const files = [a, b].map((p) => ({ subdir: p.subdir, filename: p.filename, sha256: p.sha256, size: p.bytes.length }));
    const created = await env.create(token, [{ name: 'alpha', version: '1.0.0', files }]);
    expect([200, 201]).toContain(created.statusCode);
    const made = json(created) as { group_id: string; members: Array<{ files: Array<{ subdir: string; filename: string; upload_id: string }> }> };
    for (const f of made.members[0]!.files) {
      const p = [a, b].find((x) => x.subdir === f.subdir)!;
      await env.objects.put(quarantineKeyFor(f.upload_id, f.filename), p.bytes, { contentType: 'application/octet-stream' });
    }
    const r = await env.call('POST', `/api/v1/groups/${made.group_id}/commit`, token, { members: [{ name: 'alpha' }] });
    expect(r.statusCode).toBe(202);
    expect(await env.runGroupJobs()).toEqual(['rejected']);
    expect(await rig.store.getGroup(made.group_id)).toMatchObject({ status: 'rejected', failure: { code: 'manifest_invalid', member: 'alpha' } });
  });
});
