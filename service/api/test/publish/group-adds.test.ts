import { buildsOf } from '../../src/builds';
import { bitmapIndexes } from '../../src/group-store';
import { indexKey } from '../../src/index-files';
import { quarantineKeyFor } from '../../src/publish/group-keys';
import { groupIdFor } from '../../src/publish/group-service';
import { runOps } from '../../src/ops/group-ops';
import { RIGS, type Rig } from '../group-rig';
import { audit } from '../helpers';
import type { Spec } from '../validate/builder';
import { Chain } from './group-chain-env';
import { errorCode, GroupEnv, json } from './group-env';
import { pkg, sha256, type Pkg } from './harness';

/**
 * A group member that adds a build to a version that is published (src/publish/group-service.ts, `resolveAdds`), on both registry
 * adapters, over real archives: the create that tells an add from a new version, the commit that compares the version's manifest, the
 * validator that checks the sources, the rows an add keeps (`<version>+<build>`), what a reader sees and when, the chain, the yank
 * of a group, and the group that ends. Each test says what it proves.
 */

const SOURCE = '5'.repeat(64);
const NAMES = ['alpha', 'beta', 'gamma'];

/** The archive of one build of `name` 1.0.0 for noarch, built from one source whatever the compiler. */
const build = (name: string, compiler = '1.0.0', over: Partial<Spec> = {}): Pkg => pkg({ name, subdir: 'noarch', compiler, mopm: { source_sha256: SOURCE }, ...over });

interface Created {
  group_id: string;
  members: Array<{ name: string; action: string; files: Array<{ filename: string; upload_id: string }> }>;
}

/** One group of real packages, step by step: a member is the list of its archives. */
class Flow {
  gid = '';
  created!: Created;
  constructor(
    readonly env: GroupEnv,
    readonly token: string,
    readonly members: Pkg[][],
    readonly api: 'v1' | 'v2' = 'v1',
  ) {}

  body() {
    return this.members.map((ps) => ({ name: ps[0]!.name, version: ps[0]!.version, files: ps.map((p) => ({ subdir: p.subdir, filename: p.filename, sha256: p.sha256, size: p.bytes.length })) }));
  }
  async create() {
    const r = await this.env.create(this.token, this.body(), {}, this.api);
    if (r.statusCode === 200 || r.statusCode === 201) {
      this.created = json(r);
      this.gid = this.created.group_id;
    }
    return r;
  }
  /** PUT every file where the group's upload URLs point. */
  async upload() {
    for (const m of this.created.members) {
      for (const f of m.files) {
        const p = this.members.flat().find((x) => x.name === m.name && x.filename === f.filename)!;
        await this.env.objects.put(quarantineKeyFor(f.upload_id, f.filename), p.bytes, { contentType: 'application/octet-stream' });
      }
    }
  }
  /** `manifests: false` leaves out each member's `manifest_sha256` (a commit may). */
  commitBody(manifests = true) {
    return { members: this.members.map((ps) => ({ name: ps[0]!.name, ...(manifests ? { manifest_sha256: ps[0]!.manifest } : {}) })) };
  }
  commit(body: unknown = this.commitBody()) {
    return this.env.call('POST', `/api/${this.api}/groups/${this.gid}/commit`, this.token, body);
  }
  /** create, upload, commit: the group is validating and its job is on the queue. */
  async start(body: unknown = this.commitBody()) {
    expect((await this.create()).statusCode).toBe(201);
    await this.upload();
    expect((await this.commit(body)).statusCode).toBe(202);
    return this;
  }
  header() {
    return this.env.rig.store.getGroup(this.gid);
  }
}

describe.each(RIGS)('a group that adds builds to published versions: %s', (_label, make) => {
  let rig: Rig;
  let env: GroupEnv;
  let chain: Chain;
  let token: string;
  let other: string;
  beforeEach(async () => {
    rig = make();
    env = new GroupEnv(rig);
    chain = new Chain(env);
    token = await env.account(1, 'octocat', NAMES);
    other = await env.account(2, 'hubot', NAMES);
  });

  const row = (name: string, key = '1.0.0') => rig.store.raw.rawGet(name, key);
  const buildRow = (name: string, compiler = '1.1.0') => row(name, `1.0.0+mojo${compiler}_0`);
  /** A version as a reader sees it: its row with the builds added to it folded in (the API lists versions this way). */
  const shown = async (name: string) => (await rig.store.listVersions(name)).find((v) => v.canonical === '1.0.0');
  const shownBuilds = async (name: string) => {
    const v = await shown(name);
    return v === undefined ? undefined : buildsOf(v).map((b) => b.build);
  };
  /** A group of single-build members, committed, run and visible. */
  async function published(names: string[], compiler = '1.0.0', over: Partial<Spec> = {}): Promise<Flow> {
    const f = await new Flow(env, token, names.map((n) => [build(n, compiler, over)])).start();
    expect(await env.runGroupJobs()).toEqual(['committed']);
    await chain.drain();
    expect((await f.header())!.status).toBe('visible');
    return f;
  }
  const fileKeys = (subdir: string): string[] => {
    const o = env.objects.objects.get(`${subdir}/repodata.json`);
    return o ? Object.keys((JSON.parse(o.body.toString('utf8')) as { 'packages.conda': Record<string, unknown> })['packages.conda']).sort() : [];
  };

  describe('what a reader sees', () => {
    test('a group that adds 1.1.0 builds to two published versions and publishes a new version: none of it is seen before the commit, all of it at once after', async () => {
      await published(['alpha', 'beta']);
      const versionRows = [await row('alpha'), await row('beta')];
      const f = new Flow(env, token, [[build('alpha', '1.1.0')], [build('beta', '1.1.0')], [build('gamma')]]);

      expect((await f.create()).statusCode).toBe(201);
      expect(f.created.members.map((m) => [m.name, m.action])).toEqual([['alpha', 'new'], ['beta', 'new'], ['gamma', 'new']]);
      // Reserved: each add holds a row of its own, and the version's row is as it was.
      expect(await buildRow('alpha')).toMatchObject({ state: 'pending', group_id: f.gid, version: '1.0.0', canonical: '1.0.0+mojo1.1.0_0' });
      expect([await row('alpha'), await row('beta')]).toEqual(versionRows);
      await f.upload();
      expect(await shownBuilds('alpha')).toEqual(['mojo1.0.0_0']);

      expect((await f.commit()).statusCode).toBe(202);
      expect(await shownBuilds('alpha')).toEqual(['mojo1.0.0_0']);
      expect(await shownBuilds('beta')).toEqual(['mojo1.0.0_0']);
      expect((await shown('gamma'))?.state).not.toBe('published');
      // Validated and staged, not committed: still nothing to a reader, and the add's row is filled with its own build only.
      const h = (await f.header())!;
      expect(h.status).toBe('validating');
      expect(await shownBuilds('alpha')).toEqual(['mojo1.0.0_0']);

      expect(await env.runGroupJobs()).toEqual(['committed']);
      expect(await buildRow('alpha')).toMatchObject({ state: 'pending', staged_attempt: 1, build: 'mojo1.1.0_0', requires_mojo: '==1.1.0' });
      expect((await buildRow('alpha'))!.files.map((x) => x.filename)).toEqual(['mojo-alpha-1.0.0-mojo1.1.0_0.conda']);
      // Committed: two builds, the primary one is still the lowest compiler's.
      expect(await shownBuilds('alpha')).toEqual(['mojo1.0.0_0', 'mojo1.1.0_0']);
      expect(await shownBuilds('beta')).toEqual(['mojo1.0.0_0', 'mojo1.1.0_0']);
      expect(await shown('alpha')).toMatchObject({ state: 'published', build: 'mojo1.0.0_0', requires_mojo: '==1.0.0' });
      expect(await shown('gamma')).toMatchObject({ state: 'published' });
      // The version's rows were never written.
      expect([await row('alpha'), await row('beta')]).toEqual(versionRows);

      await chain.drain();
      expect((await f.header())!.status).toBe('visible');
      expect(await buildRow('alpha')).toMatchObject({ state: 'published' });
      expect([await row('alpha'), await row('beta')]).toEqual(versionRows);
      expect(await shownBuilds('beta')).toEqual(['mojo1.0.0_0', 'mojo1.1.0_0']);
      expect(fileKeys('noarch')).toEqual(
        ['mojo-alpha-1.0.0-mojo1.0.0_0.conda', 'mojo-alpha-1.0.0-mojo1.1.0_0.conda', 'mojo-beta-1.0.0-mojo1.0.0_0.conda', 'mojo-beta-1.0.0-mojo1.1.0_0.conda', 'mojo-gamma-1.0.0-mojo1.0.0_0.conda'].sort(),
      );
      const lines = env.objects.objects.get(indexKey('alpha'))!.body.toString('utf8').trim().split('\n');
      // A flat name's index line is the v1 line: it lists the primary build only, and the added build is in the channel's repodata.
      expect(JSON.parse(lines[lines.length - 1]!)).toMatchObject({ state: 'published', build: 'mojo1.0.0_0', files: [{ filename: 'mojo-alpha-1.0.0-mojo1.0.0_0.conda' }] });
      // The channel holds the added bytes.
      expect(await env.objects.get('noarch/mojo-alpha-1.0.0-mojo1.1.0_0.conda')).toBeDefined();
    });

    test('the member list and the status: a member that adds a build is keyed by the build row, and answers the version as the request spelled it', async () => {
      await published(['alpha']);
      const f = new Flow(env, token, [[build('alpha', '1.1.0')], [build('beta')]]);
      expect((await f.create()).statusCode).toBe(201);
      await f.upload();
      expect(await rig.store.getGroupMembers(f.gid)).toEqual({
        members: [
          { name: 'alpha', version: '1.0.0', canonical: '1.0.0+mojo1.1.0_0', subdirs: ['noarch'] },
          { name: 'beta', version: '1.0.0', canonical: '1.0.0', subdirs: ['noarch'] },
        ],
      });
      const status = json(await env.get(token, f.gid));
      expect(status.members).toEqual([
        { name: 'alpha', version: '1.0.0', state: 'reserved', files: [{ subdir: 'noarch', filename: 'mojo-alpha-1.0.0-mojo1.1.0_0.conda', sha256: f.members[0]![0]!.sha256, size: f.members[0]![0]!.bytes.length, uploaded: true }] },
        { name: 'beta', version: '1.0.0', state: 'reserved', files: [{ subdir: 'noarch', filename: 'mojo-beta-1.0.0-mojo1.0.0_0.conda', sha256: f.members[1]![0]!.sha256, size: f.members[1]![0]!.bytes.length, uploaded: true }] },
      ]);
    });

    test('a repeat of the create is the same group: it continues, and once the group is committed it answers as it is, with the add already among the builds', async () => {
      await published(['alpha']);
      const f = new Flow(env, token, [[build('alpha', '1.1.0')]]);
      expect((await f.create()).statusCode).toBe(201);
      const again = await env.create(token, f.body());
      expect(again.statusCode).toBe(200);
      expect(json(again).group_id).toBe(f.gid);
      expect(json(again).members.map((m: { action: string }) => m.action)).toEqual(['join']);
      await f.upload();
      expect((await f.commit()).statusCode).toBe(202);
      expect(await env.runGroupJobs()).toEqual(['committed']);
      await chain.drain();
      // The version now has the build, yet the same request is the same group and is answered as that group.
      const done = await env.create(token, f.body());
      expect(done.statusCode).toBe(200);
      expect(json(done)).toMatchObject({ group_id: f.gid, status: 'visible' });
    });

    test('a new version with the files of two builds is published as a new version', async () => {
      const f = new Flow(env, token, [[build('alpha', '1.0.0'), build('alpha', '1.1.0')]]);
      await f.start();
      expect(await env.runGroupJobs()).toEqual(['committed']);
      await chain.drain();
      expect(await shownBuilds('alpha')).toEqual(['mojo1.0.0_0', 'mojo1.1.0_0']);
      expect(await rig.store.raw.rawGet('alpha', '1.0.0+mojo1.1.0_0')).toBeUndefined();
    });
  });

  describe('the create refuses', () => {
    const nothingWritten = async (f: Flow, name = 'alpha') => {
      const gid = groupIdFor('u:1', env.groups.parse({ members: f.body() }));
      expect(await rig.store.getGroup(gid)).toBeUndefined();
      expect(await rig.store.getGroupMembers(gid)).toBeUndefined();
      expect(await buildRow(name)).toBeUndefined();
      expect((await env.publishes.getActorGroups('u:1'))?.groups.map((g) => g.id) ?? []).not.toContain(gid);
    };

    test('a member whose build the version has: version_exists, naming the build, and nothing is written', async () => {
      await published(['alpha']);
      const f = new Flow(env, token, [[build('alpha', '1.0.0', { pkgExtra: [{ path: 'lib/mojo/extra.txt', data: 'other bytes' }] })]]);
      const r = await f.create();
      expect(r.statusCode).toBe(409);
      expect(errorCode(r)).toBe('version_exists');
      expect(json(r).error.message).toBe(`'alpha' 1.0.0 (build mojo1.0.0_0) already exists (sha256 ${(await row('alpha'))!.files[0]!.sha256}); versions are immutable.`);
      await nothingWritten(f);
    });

    test('a member whose build was added before: version_exists too', async () => {
      await published(['alpha']);
      await published(['alpha'], '1.1.0');
      expect(await shownBuilds('alpha')).toEqual(['mojo1.0.0_0', 'mojo1.1.0_0']);
      const r = await new Flow(env, token, [[build('alpha', '1.1.0', { pkgExtra: [{ path: 'lib/mojo/extra.txt', data: 'other bytes' }] })]]).create();
      expect(errorCode(r)).toBe('version_exists');
      expect(json(r).error.message).toContain('(build mojo1.1.0_0)');
    });

    test('a member with the files of two builds for a published version: invalid_request, and nothing is written', async () => {
      await published(['alpha']);
      const f = new Flow(env, token, [[build('alpha', '1.1.0'), build('alpha', '1.2.0')]]);
      const r = await f.create();
      expect(r.statusCode).toBe(400);
      expect(errorCode(r)).toBe('invalid_request');
      expect(json(r).error.message).toBe("The request is not valid: 'alpha' 1.0.0 is published, and a build is added to it one at a time; the files are of mojo1.1.0_0, mojo1.2.0_0.");
      await nothingWritten(f);
    });

    test('a member whose version is yanked: version_exists, and no build is added to it', async () => {
      await published(['alpha']);
      await rig.store.updateVersion('alpha', '1.0.0', { type: 'yank', reason: 'broken' }, audit('alpha', 'yank', '1.0.0'));
      const f = new Flow(env, token, [[build('alpha', '1.1.0')]]);
      const r = await f.create();
      expect(r.statusCode).toBe(409);
      expect(errorCode(r)).toBe('version_exists');
      await nothingWritten(f);
    });

    test('a member that adds a build while another account\'s open group holds that build: number_held', async () => {
      await published(['alpha']);
      const first = new Flow(env, other, [[build('alpha', '1.1.0')]]);
      expect((await first.create()).statusCode).toBe(201);
      const second = new Flow(env, token, [[build('alpha', '1.1.0')]]);
      const r = await second.create();
      expect(r.statusCode).toBe(409);
      expect(errorCode(r)).toBe('group_conflict');
      expect(json(r).error.reason).toBe('number_held');
      // Only the first group holds the build's row, and the version's row is the version's.
      expect(await buildRow('alpha')).toMatchObject({ group_id: first.gid, state: 'pending' });
      expect((await row('alpha'))!.group_id).not.toBe(first.gid);
    });

    test('two groups of one account for one build: the second supersedes the first, which holds the same row', async () => {
      await published(['alpha']);
      const first = new Flow(env, token, [[build('alpha', '1.1.0')]]);
      expect((await first.create()).statusCode).toBe(201);
      const second = new Flow(env, token, [[build('alpha', '1.1.0')], [build('gamma')]]);
      const r = await second.create();
      expect(r.statusCode).toBe(201);
      expect(json(r).superseded).toEqual([first.gid]);
      expect((await rig.store.getGroup(first.gid))!.status).toBe('superseded');
      expect(await buildRow('alpha')).toMatchObject({ group_id: second.gid, state: 'pending' });
    });

    test('a dead group\'s row for the build is taken over by a later group, which publishes it', async () => {
      await published(['alpha']);
      const dead = new Flow(env, other, [[build('alpha', '1.1.0')]]);
      expect((await dead.create()).statusCode).toBe(201);
      expect((await env.abort(other, dead.gid)).statusCode).toBe(200);
      expect(await buildRow('alpha')).toMatchObject({ group_id: dead.gid, state: 'pending' });

      const later = new Flow(env, token, [[build('alpha', '1.1.0')]]);
      await later.start();
      expect(await buildRow('alpha')).toMatchObject({ group_id: later.gid, state: 'pending' });
      expect(await env.runGroupJobs()).toEqual(['committed']);
      await chain.drain();
      expect(await buildRow('alpha')).toMatchObject({ group_id: later.gid, state: 'published' });
      expect(await shownBuilds('alpha')).toEqual(['mojo1.0.0_0', 'mojo1.1.0_0']);
    });
  });

  describe('the commit', () => {
    test('refuses a manifest that is not the version\'s: group_commit_refused, the group stays open, and nothing is validated', async () => {
      await published(['alpha']);
      const f = new Flow(env, token, [[build('alpha', '1.1.0')]]);
      expect((await f.create()).statusCode).toBe(201);
      await f.upload();
      const wrong = sha256('some other manifest');
      const r = await f.commit({ members: [{ name: 'alpha', manifest_sha256: wrong }] });
      expect(r.statusCode).toBe(409);
      expect(errorCode(r)).toBe('group_commit_refused');
      expect(json(r).error.message).toBe(
        `The group cannot be committed: the manifest_sha256 of 'alpha' is ${wrong}, but alpha 1.0.0 has ${(await row('alpha'))!.manifest_sha256}: the mojo1.1.0_0 build was built from other sources.`,
      );
      expect((await f.header())!.status).toBe('open');
      // Nothing was queued for validation, and the group has no commit request.
      expect(env.groupQueue.sent).toEqual([]);
      expect((await f.header())!.commit_hash).toBeUndefined();
    });

    test('takes the version\'s own manifest, and a commit that declares none', async () => {
      await published(['alpha', 'beta']);
      const a = new Flow(env, token, [[build('alpha', '1.1.0')]]);
      await a.start();
      expect((await a.header())!.status).toBe('validating');
      const b = new Flow(env, token, [[build('beta', '1.1.0')]]);
      await b.start(b.commitBody(false));
      expect((await b.header())!.status).toBe('validating');
    });

    test('refuses an add whose version was yanked after the create: group_commit_refused', async () => {
      await published(['alpha']);
      const f = new Flow(env, token, [[build('alpha', '1.1.0')]]);
      expect((await f.create()).statusCode).toBe(201);
      await f.upload();
      await rig.store.updateVersion('alpha', '1.0.0', { type: 'yank', reason: 'broken' }, audit('alpha', 'yank', '1.0.0'));
      const r = await f.commit();
      expect(r.statusCode).toBe(409);
      expect(errorCode(r)).toBe('group_commit_refused');
      expect(json(r).error.message).toBe('The group cannot be committed: alpha 1.0.0 is not published, and a build is added to a published version only.');
    });
  });

  describe('the validator', () => {
    test('an archive built from other sources is rejected in phase 1 with the group: nothing is visible, the version is untouched, and the numbers are free', async () => {
      await published(['alpha']);
      const versionRow = await row('alpha');
      const f = new Flow(env, token, [[build('alpha', '1.1.0', { mopm: { source_sha256: '6'.repeat(64) } })], [build('gamma')]]);
      // The member does not declare a manifest: the validator is what compares the sources.
      await f.start({ members: [{ name: 'alpha' }, { name: 'gamma', manifest_sha256: build('gamma').manifest }] });
      expect(await env.runGroupJobs()).toEqual(['rejected']);

      const h = (await f.header())!;
      expect(h.status).toBe('rejected');
      expect(h.failure).toMatchObject({ code: 'manifest_invalid', member: 'alpha' });
      expect(h.failure!.message).toContain('a build added to a version must come from the same source');
      expect(await shownBuilds('alpha')).toEqual(['mojo1.0.0_0']);
      expect((await shown('gamma'))?.state).not.toBe('published');
      expect(await row('alpha')).toEqual(versionRow);
      // Phase 1 copies nothing, and the build's row is pending, as reserved: free for any group.
      expect(env.objects.keys().filter((k) => !k.startsWith('quarantine/') && k.includes('mojo1.1.0'))).toEqual([]);
      expect(await buildRow('alpha')).toMatchObject({ state: 'pending', group_id: f.gid });
      expect(await buildRow('alpha')).not.toHaveProperty('staged_attempt');
    });

    test('a version published without a source digest takes no added build: rejected, and the message says to publish a new version', async () => {
      await published(['alpha'], '1.0.0', { mopm: {} });
      const f = new Flow(env, token, [[build('alpha', '1.1.0', { mopm: {} })]]);
      await f.start(f.commitBody(false));
      expect(await env.runGroupJobs()).toEqual(['rejected']);
      expect((await f.header())!.failure).toMatchObject({ code: 'manifest_invalid', message: 'alpha 1.0.0 carries no source digest, so no build can be added to it: publish a new version' });
    });

    test('an add whose version was yanked after the commit request is rejected: version_exists', async () => {
      await published(['alpha']);
      const f = await new Flow(env, token, [[build('alpha', '1.1.0')]]).start();
      await rig.store.updateVersion('alpha', '1.0.0', { type: 'yank', reason: 'broken' }, audit('alpha', 'yank', '1.0.0'));
      expect(await env.runGroupJobs()).toEqual(['rejected']);
      expect((await f.header())!.failure).toEqual({ code: 'version_exists', message: 'alpha 1.0.0 is not published, and a build is added to a published version only', member: 'alpha' });
    });

    test('a group that fails after its copies burns the build rows and leaves the versions as they were', async () => {
      await published(['alpha']);
      const versionRow = await row('alpha');
      const add = build('alpha', '1.1.0');
      const f = new Flow(env, token, [[add], [build('gamma')]]);
      await f.start();
      // Other bytes already stand under the add's name in the channel: the copy refuses them and the group fails.
      await env.objects.put(`noarch/${add.filename}`, Buffer.from('not the same bytes'), { contentType: 'application/octet-stream' });
      expect(await env.runGroupJobs()).toEqual(['failed']);

      expect((await f.header())!.status).toBe('failed');
      expect(await buildRow('alpha')).toMatchObject({ state: 'tombstoned', group_id: f.gid });
      expect(await row('alpha')).toEqual(versionRow);
      expect(await shownBuilds('alpha')).toEqual(['mojo1.0.0_0']);
      expect(await shown('alpha')).toMatchObject({ state: 'published' });
      expect(await row('gamma')).toMatchObject({ state: 'tombstoned' });
      // The same request is a failed group; another group asking for the burned build is refused, naming it.
      expect(errorCode(await env.create(token, f.body()))).toBe('group_conflict');
      const again = await new Flow(env, token, [[build('alpha', '1.1.0', { pkgExtra: [{ path: 'lib/mojo/extra.txt', data: 'x' }] })]]).create();
      expect(errorCode(again)).toBe('version_exists');
      expect(json(again).error.message).toContain('(build mojo1.1.0_0)');
      expect(await shownBuilds('alpha')).toEqual(['mojo1.0.0_0']);
    });
  });

  describe('the yank of a group', () => {
    /** A group that adds a build to alpha and publishes gamma 1.0.0, visible; beta 1.0.0 is published before it. */
    async function visibleAdd(): Promise<Flow> {
      await published(['alpha', 'beta']);
      const f = await new Flow(env, token, [[build('alpha', '1.1.0')], [build('gamma')]]).start();
      expect(await env.runGroupJobs()).toEqual(['committed']);
      await chain.drain();
      expect((await f.header())!.status).toBe('visible');
      return f;
    }
    const yank = (f: Flow, yanked: boolean) => env.call('PUT', `/api/v1/groups/${f.gid}/yank`, token, yanked ? { yanked: true, reason: 'broken' } : { yanked: false });

    test('yanks the new version and leaves the version that got a build, its builds, and every other version as they were; the unyank restores the new version only', async () => {
      const f = await visibleAdd();
      const before = { alpha: await row('alpha'), build: await buildRow('alpha'), beta: await row('beta') };

      expect((await yank(f, true)).statusCode).toBe(202);
      await chain.drain();
      const h = (await f.header())!;
      expect(h.yank).toMatchObject({ state: 'yanked' });
      // alpha is member 0 and gamma member 1: only gamma is in the set the yank changed.
      expect(bitmapIndexes(h.yank!.yanked_set)).toEqual([1]);
      expect(await row('gamma')).toMatchObject({ state: 'yanked' });
      expect({ alpha: await row('alpha'), build: await buildRow('alpha'), beta: await row('beta') }).toEqual(before);
      expect(await shownBuilds('alpha')).toEqual(['mojo1.0.0_0', 'mojo1.1.0_0']);
      expect(await shown('alpha')).toMatchObject({ state: 'published' });
      expect(fileKeys('noarch')).toContain('mojo-alpha-1.0.0-mojo1.1.0_0.conda');

      const status = json(await env.get(token, f.gid));
      expect(status.yank).toMatchObject({ state: 'yanked', yanked_members: 1 });
      // A status has no state for a member that has none of its own: the add shows as it was when the group became visible.
      expect(status.members.map((m: { name: string; state: string }) => [m.name, m.state])).toEqual([['alpha', 'published'], ['gamma', 'yanked']]);

      expect((await yank(f, false)).statusCode).toBe(202);
      await chain.drain();
      expect((await f.header())!.yank).toMatchObject({ state: 'restored' });
      expect(await row('gamma')).toMatchObject({ state: 'published' });
      expect({ alpha: await row('alpha'), build: await buildRow('alpha'), beta: await row('beta') }).toEqual(before);
    });

    test('a build that another group added in a directory the yanked group has no file in: the yank lists it under removed there, and the unyank lists it again', async () => {
      // Group A publishes alpha for linux-64 only; group B adds the Mojo 1.1.0 build, for osx-arm64.
      const a = await new Flow(env, token, [[build('alpha', '1.0.0', { subdir: 'linux-64' })]]).start();
      expect(await env.runGroupJobs()).toEqual(['committed']);
      await chain.drain();
      const file = build('alpha', '1.1.0', { subdir: 'osx-arm64' });
      const b = await new Flow(env, token, [[file]]).start();
      expect(await env.runGroupJobs()).toEqual(['committed']);
      await chain.drain();
      expect(await rig.store.getGroupMembers(b.gid)).toEqual({ members: [{ name: 'alpha', version: '1.0.0', canonical: '1.0.0+mojo1.1.0_0', subdirs: ['osx-arm64'] }] });
      const repodata = () => JSON.parse(env.objects.objects.get('osx-arm64/repodata.json')!.body.toString('utf8')) as { 'packages.conda': Record<string, unknown>; removed: string[] };
      expect([Object.keys(repodata()['packages.conda']), repodata().removed]).toEqual([[file.filename], []]);

      expect((await yank(a, true)).statusCode).toBe(202);
      await chain.drain();
      expect((await a.header())!.yank).toMatchObject({ state: 'yanked', repodata_dirs: ['linux-64', 'osx-arm64'] });
      expect([Object.keys(repodata()['packages.conda']), repodata().removed]).toEqual([[], [file.filename]]);

      expect((await yank(a, false)).statusCode).toBe(202);
      await chain.drain();
      expect((await a.header())!.yank).toMatchObject({ state: 'restored' });
      expect([Object.keys(repodata()['packages.conda']), repodata().removed]).toEqual([[file.filename], []]);
    });

    test('a group of adds only has nothing of its own to yank: the yank ends with no member changed, and the versions and their builds stay published', async () => {
      await published(['alpha', 'beta']);
      const f = await new Flow(env, token, [[build('alpha', '1.1.0')], [build('beta', '1.1.0')]]).start();
      expect(await env.runGroupJobs()).toEqual(['committed']);
      await chain.drain();
      const before = [await row('alpha'), await buildRow('alpha'), await row('beta'), await buildRow('beta')];

      expect((await yank(f, true)).statusCode).toBe(202);
      await chain.drain();
      const h = (await f.header())!;
      expect(h.yank).toMatchObject({ state: 'yanked', rows_done: true });
      expect(bitmapIndexes(h.yank!.yanked_set)).toEqual([]);
      expect([await row('alpha'), await buildRow('alpha'), await row('beta'), await buildRow('beta')]).toEqual(before);
      expect(await shownBuilds('beta')).toEqual(['mojo1.0.0_0', 'mojo1.1.0_0']);

      expect((await yank(f, false)).statusCode).toBe(202);
      await chain.drain();
      expect((await f.header())!.yank).toMatchObject({ state: 'restored' });
      expect([await row('alpha'), await buildRow('alpha'), await row('beta'), await buildRow('beta')]).toEqual(before);
    });
  });
});

describe.each(RIGS)('a group that adds a build to a version of a namespace: %s', (_label, make) => {
  test('the namespace\'s repodata lists the added build once the group is visible, and its index line lists both builds', async () => {
    const rig = make();
    const env = new GroupEnv(rig, {}, true);
    const chain = new Chain(env);
    await env.ownNamespaces(1, 'octocat', ['acme']);
    const token = await env.account(1, 'octocat', ['acme/alpha']);
    const ns = (compiler: string) => build('acme/alpha', compiler);

    const base = await new Flow(env, token, [[ns('1.0.0')]], 'v2').start();
    expect(await env.runGroupJobs()).toEqual(['committed']);
    await chain.drain();
    expect((await base.header())!.status).toBe('visible');

    const add = await new Flow(env, token, [[ns('1.1.0')]], 'v2').start();
    expect(await rig.store.getGroupMembers(add.gid)).toEqual({ members: [{ name: 'acme/alpha', version: '1.0.0', canonical: '1.0.0+mojo1.1.0_0', subdirs: ['noarch'] }] });
    expect(await env.runGroupJobs()).toEqual(['committed']);
    await chain.drain();
    expect((await add.header())!.status).toBe('visible');

    const repodata = JSON.parse(env.objects.objects.get('acme/noarch/repodata.json')!.body.toString('utf8')) as { 'packages.conda': Record<string, unknown> };
    expect(Object.keys(repodata['packages.conda']).sort()).toEqual(['mojo-acme.alpha-1.0.0-mojo1.0.0_0.conda', 'mojo-acme.alpha-1.0.0-mojo1.1.0_0.conda']);
    const lines = env.objects.objects.get(indexKey('acme/alpha'))!.body.toString('utf8').trim().split('\n');
    const last = JSON.parse(lines[lines.length - 1]!) as { build: string; builds: Array<{ build: string; requires_mojo: string }> };
    expect(last.build).toBe('mojo1.0.0_0');
    expect(last.builds.map((b) => [b.build, b.requires_mojo])).toEqual([['mojo1.0.0_0', '==1.0.0'], ['mojo1.1.0_0', '==1.1.0']]);
  });
});

describe.each(RIGS)('the operator ends a stuck group that adds a build: %s', (_label, make) => {
  test('--mode=fail --apply on a group that began to copy burns the build row of its add and leaves the version as it was', async () => {
    const rig = make();
    const env = new GroupEnv(rig);
    const chain = new Chain(env);
    const token = await env.account(1, 'octocat', NAMES);
    const first = await new Flow(env, token, [[build('alpha')]]).start();
    expect(await env.runGroupJobs()).toEqual(['committed']);
    await chain.drain();
    expect((await first.header())!.status).toBe('visible');
    const before = await rig.store.raw.rawGet('alpha', '1.0.0');

    const add = await new Flow(env, token, [[build('alpha', '1.1.0')]]).start();
    const put = env.objects.put.bind(env.objects);
    env.objects.put = async (k, body, opts) => {
      if (!k.startsWith('quarantine/')) throw new Error('the Lambda died while copying');
      return put(k, body, opts);
    };
    await expect(env.runGroupJob()).rejects.toThrow('the Lambda died while copying');
    expect((await add.header())!.phase).toBe(2);

    const out: Array<Record<string, unknown>> = [];
    const code = await runOps({ mode: 'fail', group: add.gid, apply: true }, { groups: rig.store, queueDepth: async () => [], now: env.clock.now, out: (l) => out.push(l) });
    expect(code).toBe(0);
    expect(out.map((l) => l.kind)).toEqual(['plan', 'ended', 'burned']);
    expect(await rig.store.raw.rawGet('alpha', '1.0.0+mojo1.1.0_0')).toMatchObject({ state: 'tombstoned', tombstone: { reason_code: 'operator' }, files: [] });
    expect(await rig.store.raw.rawGet('alpha', '1.0.0')).toEqual(before);
    expect(buildsOf((await rig.store.listVersions('alpha'))[0]!).map((b) => b.build)).toEqual(['mojo1.0.0_0']);
  });
});
