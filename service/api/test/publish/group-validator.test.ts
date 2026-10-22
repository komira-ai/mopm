import { createHash } from 'node:crypto';
import { bitmapIndexes } from '../../src/group-store';
import { expireIfDue } from '../../src/publish/group-lifecycle';
import { validateGroup, writeOrder } from '../../src/publish/group-validator';
import { RIGS, type Rig } from '../group-rig';
import { errorCode, GroupEnv } from './group-env';
import { Scenario } from './group-scenario';

/**
 * The group's validator (src/publish/group-validator.ts) against real archives, on both registry adapters (memory, and
 * DynamoDB over the in-process fake). Each test states what it proves. A job is run the way the group queue runs it: one
 * message at a time, and a message that is not acknowledged (the job threw) is delivered again.
 */

const sha = (b: Uint8Array | string) => createHash('sha256').update(b).digest('hex');
const HOUR = 3_600_000;
const LATER = new Date('2030-01-01T00:00:00Z');

/** Copies into the channel, as the object store's log saw them (the log also holds the test's own uploads to quarantine). */
const channelPuts = (env: GroupEnv) => env.objects.log.filter((l) => l.startsWith('put ') && !l.startsWith('put quarantine/'));

describe.each(RIGS)('the group validator: %s', (_label, make) => {
  let rig: Rig;
  let env: GroupEnv;
  beforeEach(() => {
    rig = make();
    env = new GroupEnv(rig);
  });
  const actions = async (name: string) => (await rig.store.listAudit(name)).map((a) => a.action);

  describe('a group of valid packages', () => {
    test('is validated, staged, copied and committed: the API shows every member, the channel holds the bytes, quarantine is empty', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }, { name: 'gamma' }]).start();
      expect(await s.runAll()).toEqual(['committed']);

      const h = (await s.header())!;
      expect(h).toMatchObject({ status: 'committed', attempt: 1, phase: 3, resend: 0, write_order: [0, 1, 2] });
      expect(h.committed_at).toBeDefined();
      for (const field of ['validated', 'staged', 'copied'] as const) expect(bitmapIndexes(h[field])).toEqual([0, 1, 2]);
      // The header stays in the sweeper's index until the chain that follows a commit exists; nothing here ends it.
      expect(h.sweep_pk).toBe('active');
      expect(h.expires_at).toBeUndefined();

      for (const p of s.pkgs) {
        expect(sha((await env.objects.get(`noarch/${p.filename}`))!)).toBe(p.sha256);
        // As the stage left it: pending, filled, stamped. The API shows it as published at the commit time.
        expect(await s.row(p.name)).toMatchObject({ state: 'pending', group_id: s.gid, staged_attempt: 1, build: 'mojo1.0.0_0', requires_mojo: '==1.0.0', manifest_sha256: p.manifest, published_by: 'octocat' });
        expect(await s.shown(p.name)).toMatchObject({
          state: 'published',
          published_at: h.committed_at,
          files: [{ subdir: 'noarch', filename: p.filename, sha256: p.sha256, size: p.bytes.length, url: `https://conda.example.invalid/noarch/${p.filename}` }],
        });
        expect((await actions(p.name)).sort()).toEqual(['group_reserve', 'group_stage']);
      }
      expect(env.objects.keys('quarantine/')).toEqual([]);
      expect((await rig.store.listAudit(`grp#${s.gid}`)).map((a) => a.action).sort()).toEqual(['group_commit', 'group_commit_request', 'group_create']);
    });

    test('the display fields of the commit request reach the member rows', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).create();
      await s.upload();
      const body = { members: [{ name: 'alpha', manifest_sha256: s.pkgs[0]!.manifest, description: 'The first', license: 'MIT', keywords: ['one'] }, { name: 'beta', manifest_sha256: s.pkgs[1]!.manifest }] };
      expect((await s.commit(body)).statusCode).toBe(202);
      expect(await s.runAll()).toEqual(['committed']);
      expect(await s.shown('alpha')).toMatchObject({ description: 'The first', license: 'MIT', keywords: ['one'] });
      expect((await s.shown('beta'))!.description).toBeUndefined();
    });

    test('write_order puts a package after the packages of the group it depends on', async () => {
      const s = await new Scenario(env, [
        { name: 'app', index: { depends: ['mojo-compiler ==1.0.0', 'mojo-lib'] }, mopm: { deps: [{ name: 'lib' }] } },
        { name: 'lib', index: { depends: ['mojo-compiler ==1.0.0', 'mojo-base'] }, mopm: { deps: [{ name: 'base' }] } },
        { name: 'base' },
      ]).start();
      expect(await s.runAll()).toEqual(['committed']);
      // Members are listed in name order: app 0, base 1, lib 2. The chain writes base, then lib, then app.
      expect((await s.header())!.write_order).toEqual([1, 2, 0]);
    });
  });

  describe('a group with a member that is not valid', () => {
    test('is rejected before anything is copied: nothing is in the channel, nothing is committed, and every number is free again', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'broken', drop: ['info/index.json'] }, { name: 'gamma' }]).start();
      expect(await s.runAll()).toEqual(['rejected']);

      const h = (await s.header())!;
      expect(h).toMatchObject({ status: 'rejected', failure: { member: 'broken' } });
      expect(h.failure!.code).toEqual(expect.any(String));
      expect(h.committed_at).toBeUndefined();
      expect(h.sweep_pk).toBeUndefined();
      expect(channelPuts(env)).toEqual([]);
      expect(s.channelFiles()).toEqual([]);
      // alpha was staged before the bad member was met; it shows nowhere.
      expect((await s.shown('alpha'))!.state).toBe('pending');
      expect((await s.shown('gamma'))!.state).toBe('pending');
      // The numbers are free: a single publish takes them.
      expect((await env.begin(s.token, 'alpha')).statusCode).toBe(200);
      expect((await env.begin(s.token, 'broken')).statusCode).toBe(200);
    });

    test('a manifest the archive does not carry is rejected the same way', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).create();
      await s.upload();
      const body = { members: [{ name: 'alpha', manifest_sha256: s.pkgs[0]!.manifest }, { name: 'beta', manifest_sha256: 'e'.repeat(64) }] };
      expect((await s.commit(body)).statusCode).toBe(202);
      expect(await s.runAll()).toEqual(['rejected']);
      expect((await s.header())!.failure).toMatchObject({ member: 'beta' });
      expect(channelPuts(env)).toEqual([]);
    });

    test('a rejected group opens again with the next attempt, and the stage of the old attempt is not the new one', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'broken', drop: ['info/index.json'] }]).start();
      expect(await s.runAll()).toEqual(['rejected']);
      expect((await s.row('alpha'))!.staged_attempt).toBe(1);
      // The same request again opens it again (attempt 2); the staged row keeps its old stamp until the new attempt stages it.
      expect((await s.recreate()).statusCode).toBe(201);
      expect((await s.header())).toMatchObject({ status: 'open', attempt: 2 });
      expect((await s.header())!.failure).toBeUndefined();
      expect((await s.header())!.expires_at).toBeUndefined();
      expect((await s.shown('alpha'))!.state).toBe('pending');
    });
  });

  describe('the files copied into the channel', () => {
    test('a quarantine object that changed after it was validated burns the group: nothing is committed and the numbers stay taken', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).start();
      const key = s.keyOf('beta');
      const real = env.objects.get.bind(env.objects);
      let reads = 0;
      env.objects.get = async (k: string) => {
        const bytes = await real(k);
        // The first read of the file is its validation; after that the object is replaced.
        if (k === key && ++reads === 1) env.objects.objects.get(k)!.body = Buffer.from('swapped after validation');
        return bytes;
      };
      expect(await s.runAll()).toEqual(['failed']);

      const h = (await s.header())!;
      expect(h).toMatchObject({ status: 'failed', failure: { code: 'sha256_mismatch', member: 'beta' } });
      expect(h.committed_at).toBeUndefined();
      expect(h.expires_at).toEqual(expect.any(Number));
      // Both numbers are burned, as a rejected single publish burns its own: a tombstone with nothing of the files kept.
      for (const n of ['alpha', 'beta']) {
        expect(await s.row(n)).toMatchObject({ state: 'tombstoned', tombstone: { reason_code: 'sha256_mismatch' }, files: [] });
        expect(await actions(n)).toContain('group_burn');
        expect((await s.shown(n))!.state).toBe('tombstoned');
        expect((await env.begin(s.token, n)).statusCode).toBe(409);
      }
      // alpha's copy was made before beta was met and stays in the channel; nothing links to it.
      expect(s.channelFiles()).toEqual([`noarch/${s.pkgs[0]!.filename}`]);
    });

    test('a file already in the channel with other bytes burns the group; one with the same bytes is a repeat of the step', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).start();
      await env.objects.put(`noarch/${s.pkgs[1]!.filename}`, Buffer.from('other bytes'), { contentType: 'application/octet-stream' });
      expect(await s.runAll()).toEqual(['failed']);
      expect((await s.header())!.failure).toMatchObject({ code: 'sha256_mismatch', member: 'beta' });
      expect((await s.header())!.failure!.message).toContain('already holds other bytes');
      expect((await s.row('alpha'))!.state).toBe('tombstoned');

      const t = await new Scenario(env, [{ name: 'gamma' }, { name: 'delta' }], 2).start();
      await env.objects.put(`noarch/${t.pkgs[1]!.filename}`, t.pkgs[1]!.bytes, { contentType: 'application/octet-stream' });
      expect(await t.runAll()).toEqual(['committed']);
    });

    test('a quarantine object that is gone when the copies begin fails the group and burns its numbers', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).start();
      const key = s.keyOf('alpha');
      const real = env.objects.get.bind(env.objects);
      let reads = 0;
      env.objects.get = async (k: string) => {
        const bytes = await real(k);
        if (k === key && ++reads === 1) env.objects.objects.delete(k);
        return bytes;
      };
      expect(await s.runAll()).toEqual(['failed']);
      expect((await s.header())).toMatchObject({ status: 'failed', failure: { code: 'upload_missing', member: 'alpha' } });
      expect((await s.row('alpha'))!.state).toBe('tombstoned');
      expect((await s.row('beta'))!.state).toBe('tombstoned');
      expect(channelPuts(env)).toEqual([]);
    });

    test('a deadline that passes while the files are copied fails the group, and one that passes before they are rejects it', async () => {
      const late = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).start();
      const put = env.objects.put.bind(env.objects);
      env.objects.put = async (k, body, opts) => {
        const r = await put(k, body, opts);
        if (!k.startsWith('quarantine/')) env.clock.advance(13 * HOUR);
        return r;
      };
      expect(await late.runAll()).toEqual(['failed']);
      expect((await late.header())).toMatchObject({ status: 'failed', failure: { code: 'deadline_passed' } });
      expect((await late.row('alpha'))!.state).toBe('tombstoned');
    });

    test('a deadline that passes while the archives are checked rejects the group with nothing copied', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).start();
      const get = env.objects.get.bind(env.objects);
      let first = true;
      env.objects.get = async (k: string) => {
        if (first) {
          first = false;
          env.clock.advance(13 * HOUR);
        }
        return get(k);
      };
      expect(await s.runAll()).toEqual(['rejected']);
      expect((await s.header())).toMatchObject({ status: 'rejected', failure: { code: 'deadline_passed' } });
      expect(channelPuts(env)).toEqual([]);
      expect((await env.begin(s.token, 'alpha')).statusCode).toBe(200);
    });
  });

  describe('uploads that are too old', () => {
    test('an upload begun more than 18 hours ago is rejected before phase 2: nothing is copied', async () => {
      // A group that was aborted and made again keeps the upload records of its first attempt.
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).create();
      await s.upload();
      expect((await env.abort(s.token, s.gid)).statusCode).toBe(200);
      env.clock.advance(20 * HOUR);
      expect((await s.recreate()).statusCode).toBe(201);
      await s.upload();
      expect((await s.commit()).statusCode).toBe(202);
      expect(await s.runAll()).toEqual(['rejected']);

      const h = (await s.header())!;
      expect(h).toMatchObject({ status: 'rejected', attempt: 2, failure: { code: 'upload_too_old' } });
      expect(h.failure!.message).toContain('20 hours ago');
      expect(channelPuts(env)).toEqual([]);
      expect(bitmapIndexes(h.validated)).toEqual([]);
    });

    test('the limit is 24 hours less the hours reserved for validation (a configured value)', async () => {
      const tight = new GroupEnv(make(), { groupValidateHours: 23 });
      const s = await new Scenario(tight, [{ name: 'alpha' }]).create();
      await s.upload();
      tight.clock.advance(2 * HOUR);
      expect((await s.commit()).statusCode).toBe(202);
      expect(await s.runAll()).toEqual(['rejected']);
      expect((await s.header())!.failure).toMatchObject({ code: 'upload_too_old' });
    });

    test('an upload that is not in quarantine at its declared size, or whose record is gone, is rejected before any archive is opened', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).start();
      env.objects.objects.delete(s.keyOf('beta'));
      expect(await s.runAll()).toEqual(['rejected']);
      expect((await s.header())!.failure).toMatchObject({ code: 'upload_missing', member: 'beta' });

      const t = await new Scenario(env, [{ name: 'gamma' }], 2).start();
      env.publishes.uploads.clear();
      expect(await t.runAll()).toEqual(['rejected']);
      expect((await t.header())!.failure).toMatchObject({ code: 'upload_missing', member: 'gamma' });
    });

    test('a group that declares more bytes than the group cap allows is rejected', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).start();
      env.config.groupMaxBytes = 100; // the cap was lowered after the group was created
      expect(await s.runAll()).toEqual(['rejected']);
      expect((await s.header())!.failure).toMatchObject({ code: 'limit_exceeded' });
    });
  });

  describe('a job that is interrupted', () => {
    test('after the copies resumes from the bitmaps: the members already copied are not copied again', async () => {
      const names = Array.from({ length: 10 }, (_x, i) => `pkg${i}`);
      const s = await new Scenario(env, names.map((name) => ({ name }))).start();
      const message = JSON.parse(env.groupQueue.sent[0]!.body);
      const last = `noarch/${s.pkgs[9]!.filename}`;
      const put = env.objects.put.bind(env.objects);
      env.objects.put = async (k, body, opts) => {
        if (k === last) throw new Error('the Lambda died');
        return put(k, body, opts);
      };
      await expect(validateGroup(env.validatorDeps(), message)).rejects.toThrow('the Lambda died');

      // The header holds what was saved: the archives are all checked, and the first eight copies are recorded.
      const saved = (await s.header())!;
      expect(saved).toMatchObject({ status: 'validating', phase: 2 });
      expect(bitmapIndexes(saved.validated)).toEqual([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
      expect(bitmapIndexes(saved.copied)).toEqual([0, 1, 2, 3, 4, 5, 6, 7]);

      env.objects.put = put;
      env.objects.log.length = 0;
      expect(await validateGroup(env.validatorDeps(), message)).toBe('committed');
      // Only the members the bitmap did not record were copied again.
      expect(channelPuts(env)).toEqual([`put noarch/${s.pkgs[8]!.filename}`, `put noarch/${s.pkgs[9]!.filename}`]);
      expect((await actions('pkg0')).sort()).toEqual(['group_reserve', 'group_stage']);
      expect(bitmapIndexes((await s.header())!.copied)).toEqual([0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    });

    test('after the commit resumes without a second commit: the message finds the group committed and changes nothing', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).start();
      const message = JSON.parse(env.groupQueue.sent[0]!.body);
      const commit = rig.store.commitGroup.bind(rig.store);
      let died = false;
      rig.store.commitGroup = async (gid, c) => {
        const out = await commit(gid, c);
        if (!died) {
          died = true;
          throw new Error('the Lambda died after the commit');
        }
        return out;
      };
      await expect(validateGroup(env.validatorDeps(), message)).rejects.toThrow('the Lambda died after the commit');
      const committed = (await s.header())!;
      expect(committed.status).toBe('committed');

      expect(await validateGroup(env.validatorDeps(), message)).toBe('already');
      expect(await s.header()).toEqual(committed);
      expect((await rig.store.listAudit(`grp#${s.gid}`)).filter((a) => a.action === 'group_commit')).toHaveLength(1);
      // A redelivery of the commit message does nothing either.
      expect(await validateGroup(env.validatorDeps(), message)).toBe('already');
      expect(await s.header()).toEqual(committed);
    });

    test('a failure the group cannot explain by its archives is thrown, not decided: the group stays validating for the retry', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).start();
      const message = JSON.parse(env.groupQueue.sent[0]!.body);
      const stage = rig.store.applyGroupEvent.bind(rig.store);
      rig.store.applyGroupEvent = async () => {
        throw new Error('DynamoDB is down');
      };
      await expect(validateGroup(env.validatorDeps(), message)).rejects.toThrow('DynamoDB is down');
      expect((await s.header())!.status).toBe('validating');
      rig.store.applyGroupEvent = stage;
      expect(await validateGroup(env.validatorDeps(), message)).toBe('committed');
    });

    test('a job whose time is spent saves its progress and queues the rest, once more for each time it runs out, and the group finishes', async () => {
      const slow = new GroupEnv(make(), { groupBudgetMs: 1000 });
      const s = await new Scenario(slow, Array.from({ length: 5 }, (_x, i) => ({ name: `pkg${i}` }))).start();
      const sent: Array<{ dedupId: string; body: string }> = [];
      const send = slow.groupQueue.send.bind(slow.groupQueue);
      slow.groupQueue.send = async (m) => {
        sent.push({ dedupId: m.dedupId, body: m.body });
        return send(m);
      };
      let t = 0;
      const over = { clock: () => (t += 600) };

      expect(await slow.runGroupJob(over)).toBe('requeued');
      const paused = (await s.header())!;
      // Two members were started before the budget ran out; their progress is saved.
      expect(bitmapIndexes(paused.validated)).toEqual([0, 1]);
      expect(bitmapIndexes(paused.staged)).toEqual([0, 1]);
      expect(paused.status).toBe('validating');
      expect(JSON.parse(slow.groupQueue.sent[0]!.body)).toEqual({ type: 'validate_group', group_id: s.gid, attempt: 1, n: 1 });

      const outcomes = await slow.runGroupJobs(over);
      expect(outcomes.slice(0, -1).every((o) => o === 'requeued')).toBe(true);
      expect(outcomes[outcomes.length - 1]).toBe('committed');
      // Phase 1 takes three jobs and phase 2 three more, and the third does both: five jobs, four continuations.
      expect(sent).toHaveLength(4);
      expect(new Set(sent.map((m) => m.dedupId)).size).toBe(4);
      expect(sent.map((m) => JSON.parse(m.body).n)).toEqual([1, 2, 3, 4]);
      const h = (await s.header())!;
      expect(h.status).toBe('committed');
      for (const field of ['validated', 'staged', 'copied'] as const) expect(bitmapIndexes(h[field])).toEqual([0, 1, 2, 3, 4]);
    });
  });

  describe('a group that is validating', () => {
    test('is not ended by abort or expiry: both only end a group that is open', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).start();
      const seen: unknown[] = [];
      const put = env.objects.put.bind(env.objects);
      let once = true;
      env.objects.put = async (k, body, opts) => {
        if (once && !k.startsWith('quarantine/')) {
          once = false;
          // Phase 2 has begun: the owner aborts, and a reader long after the deadline asks for the group.
          const aborted = await env.abort(s.token, s.gid);
          seen.push(aborted.statusCode, errorCode(aborted));
          const h = (await rig.store.getGroup(s.gid))!;
          seen.push((await expireIfDue(rig.store, h, LATER)).status);
        }
        return put(k, body, opts);
      };
      expect(await s.runAll()).toEqual(['committed']);
      expect(seen).toEqual([409, 'group_not_open', 'validating']);
      expect((await s.header())!.status).toBe('committed');
    });

    test('a group that is ended by the operator while its job runs stops the job: it saves nothing and commits nothing', async () => {
      const s = await new Scenario(env, Array.from({ length: 10 }, (_x, i) => ({ name: `pkg${i}` }))).start();
      const put = env.objects.put.bind(env.objects);
      let n = 0;
      env.objects.put = async (k, body, opts) => {
        if (!k.startsWith('quarantine/') && ++n === 9) {
          await rig.store.updateGroup(s.gid, (cur) => ({ ...cur, status: 'failed', sweep_pk: undefined, expires_at: 1 }));
        }
        return put(k, body, opts);
      };
      // The job finds the group failed at its next save (after the eighth copy) and stops; the failed group's rows are burned by whoever failed it.
      expect(await s.runAll()).toEqual(['skipped']);
      expect((await s.header())!.committed_at).toBeUndefined();
    });
  });

  describe('messages the validator does not act on', () => {
    test('a message for an unknown group, an attempt that has been replaced, or a group that is not validating is skipped', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }]).create();
      await s.upload();
      expect(await validateGroup(env.validatorDeps(), { group_id: 'grp_00000000000000000000000000000000', attempt: 1, n: 0 })).toBe('skipped');
      expect(env.jobLogs.some((l) => l.msg === 'a group job for an unknown group')).toBe(true);
      // Open: nobody has asked for the validation.
      expect(await validateGroup(env.validatorDeps(), { group_id: s.gid, attempt: 1, n: 0 })).toBe('skipped');
      // Another attempt than the group's.
      expect(await validateGroup(env.validatorDeps(), { group_id: s.gid, attempt: 7, n: 0 })).toBe('skipped');
      expect((await s.header())!.status).toBe('open');
    });

    test('a failed group whose numbers were not all burned yet (the job died after ending it) has them burned by the next message', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).start();
      const message = JSON.parse(env.groupQueue.sent[0]!.body);
      const burn = rig.store.applyGroupEvent.bind(rig.store);
      rig.store.applyGroupEvent = async (name, version, event, audit) => {
        if (event.type === 'group_burn') throw new Error('the Lambda died while burning');
        return burn(name, version, event, audit);
      };
      // alpha's upload is replaced after it was validated, which ends the group `failed` ...
      const get = env.objects.get.bind(env.objects);
      let reads = 0;
      env.objects.get = async (k: string) => {
        const b = await get(k);
        if (k === s.keyOf('alpha') && ++reads === 1) env.objects.objects.get(k)!.body = Buffer.from('swapped');
        return b;
      };
      // ... and the job dies while it burns the numbers.
      await expect(validateGroup(env.validatorDeps(), message)).rejects.toThrow('the Lambda died while burning');
      expect((await s.header())!.status).toBe('failed');
      expect((await s.row('alpha'))!.state).toBe('pending');

      rig.store.applyGroupEvent = burn;
      expect(await validateGroup(env.validatorDeps(), message)).toBe('failed');
      expect((await s.row('alpha'))!.state).toBe('tombstoned');
      expect((await s.row('beta'))!.state).toBe('tombstoned');
      // And again: nothing is left to burn, and nothing is written.
      const rev = (await s.row('beta'))!.rev;
      expect(await validateGroup(env.validatorDeps(), message)).toBe('failed');
      expect((await s.row('beta'))!.rev).toBe(rev);
    });
  });

  describe('the project total', () => {
    test('is checked again before the commit: a package that filled up meanwhile fails the group and burns its numbers', async () => {
      const full = new GroupEnv(make(), { projectQuotaBytes: 1_000_000 });
      const s = await new Scenario(full, [{ name: 'alpha' }, { name: 'beta' }]).start();
      const put = full.objects.put.bind(full.objects);
      full.objects.put = async (k, body, opts) => {
        // While the files are copied, another version of beta is published (as a single) and takes the room.
        if (k === `noarch/${s.pkgs[1]!.filename}`) {
          await full.rig.store.createVersion(
            { name: 'beta', version: '0.9.0', canonical: '0.9.0', build: 'mojo1.0.0_0', state: 'published', published_at: '2026-10-14T00:00:00Z', requires_mojo: '==1.0.0', deps: [], native: [], files: [{ subdir: 'noarch', filename: 'mojo-beta-0.9.0-mojo1.0.0_0.conda', sha256: 'a'.repeat(64), size: 999_999 }], manifest_sha256: 'f'.repeat(64), rev: 0 },
            { name: 'beta', ts: '2026-10-14T00:00:00Z', id: 'seed', actor: 'test', action: 'seed' },
          );
        }
        return put(k, body, opts);
      };
      expect(await s.runAll()).toEqual(['failed']);
      expect((await s.header())).toMatchObject({ status: 'failed', failure: { code: 'limit_exceeded', member: 'beta' } });
      expect((await s.row('alpha'))!.state).toBe('tombstoned');
    });
  });
});

describe('writeOrder', () => {
  const members = (...names: string[]) => names.map((name) => ({ name, version: '1.0.0', canonical: '1.0.0', subdirs: ['noarch'] }));
  const order = (names: string[], deps: Record<string, string[]>) => writeOrder(members(...names), (i) => deps[names[i]!] ?? []).map((i) => names[i]);

  test('dependencies come first, and independent packages are in name order', () => {
    expect(order(['a', 'b', 'c', 'd'], {})).toEqual(['a', 'b', 'c', 'd']);
    expect(order(['a', 'b', 'c'], { a: ['b'], b: ['c'] })).toEqual(['c', 'b', 'a']);
    expect(order(['app', 'base', 'lib', 'zed'], { app: ['lib', 'base'], lib: ['base'] })).toEqual(['base', 'lib', 'app', 'zed']);
  });

  test('a dependency outside the group, a dependency on itself and a repeated dependency are ignored', () => {
    expect(order(['a', 'b'], { a: ['outside', 'a', 'b', 'b'] })).toEqual(['b', 'a']);
  });

  test('members in a cycle are ordered by name inside it, after what they depend on and before what depends on them', () => {
    expect(order(['a', 'b', 'c', 'd'], { d: ['c'], c: ['b'], b: ['c'], a: ['d'] })).toEqual(['b', 'c', 'd', 'a']);
    expect(order(['x', 'y', 'z'], { x: ['y'], y: ['z'], z: ['x'] })).toEqual(['x', 'y', 'z']);
  });

  test('the order does not depend on the order the members are listed in', () => {
    const deps = { app: ['lib'], lib: ['base'] };
    expect(order(['app', 'base', 'lib'], deps)).toEqual(order(['lib', 'app', 'base'], deps));
  });
});
