import { createHash } from 'node:crypto';
import { mintToken } from '../../src/auth';
import { route } from '../../src/http/router';
import { bitmapIndexes } from '../../src/group-store';
import { indexKey } from '../../src/index-files';
import { Metrics } from '../../src/metrics';
import { runOps } from '../../src/ops/group-ops';
import { GroupService } from '../../src/publish/group-service';
import { CHAIN_STALL_MS, MAX_RESENDS, sweepGroups } from '../../src/publish/group-sweeper';
import { parseIndexMessage } from '../../src/publish/indexer';
import { MemoryPresigner, MemoryQueue } from '../../src/publish/memory';
import type { QueueMessage } from '../../src/publish/ports';
import { applyEvent, WrongGroup } from '../../src/state';
import { RIGS, type Rig } from '../group-rig';
import { audit, rec } from '../helpers';
import type { VersionRecord } from '../../src/types';
import type { Spec } from '../validate/builder';
import { Chain, label } from './group-chain-env';
import { errorCode, GroupEnv, json } from './group-env';
import { Scenario } from './group-scenario';

/**
 * The yank and unyank of a whole group (src/publish/group-yank.ts and group-yank-request.ts), on both registry adapters, over real
 * archives: the request, the rows, the hops that follow them, the sweeper that resumes a stalled one, and the operator's tool. Each
 * test says what it proves.
 *
 * The group most tests use is the chain's: `app` depends on `lib`, `lib` on `base`; `lib` has its file in linux-64, the others in
 * noarch. The members are listed in name order (app 0, base 1, lib 2) and the write order is base, lib, app. A yank of all three is
 * therefore
 *   rows, repodata linux-64, repodata noarch, index base, index lib, index app.
 */

const MINUTE = 60_000;
const SPECS: Array<Partial<Spec>> = [
  { name: 'app', subdir: 'noarch', index: { depends: ['mojo-compiler ==1.0.0', 'mojo-lib'] }, mopm: { deps: [{ name: 'lib' }] } },
  { name: 'base', subdir: 'noarch' },
  { name: 'lib', subdir: 'linux-64', index: { depends: ['mojo-compiler ==1.0.0', 'mojo-base'] }, mopm: { deps: [{ name: 'base' }] } },
];
const NAMES = ['app', 'base', 'lib'];
const REASON = 'the release is broken';
const sha = (b: Buffer) => createHash('sha256').update(b).digest('hex');

describe.each(RIGS)('the yank of a group: %s', (_label, make) => {
  let rig: Rig;
  let env: GroupEnv;
  let chain: Chain;
  beforeEach(() => {
    rig = make();
    env = new GroupEnv(rig);
    chain = new Chain(env);
  });

  /** A group that has committed and whose chain has run to the end: visible, every member a plain published row, every file written. */
  async function visible(specs: Array<Partial<Spec>> = SPECS): Promise<Scenario> {
    const s = await new Scenario(env, specs).start();
    expect(await s.runAll()).toEqual(['committed']);
    await chain.drain();
    expect((await header(s)).status).toBe('visible');
    return s;
  }
  const header = async (s: Scenario) => (await s.header())!;
  const stored = (name: string) => rig.store.raw.rawGet(name, '1.0.0');
  const put = (s: Scenario, body: unknown, token = s.token) => env.call('PUT', `/api/v1/groups/${s.gid}/yank`, token, body);
  const yank = (s: Scenario, reason = REASON) => put(s, { yanked: true, reason });
  const unyank = (s: Scenario) => put(s, { yanked: false });
  /** Run the whole yank (or unyank) once it is requested; answers what ran, by label. */
  const finish = async () => (await chain.drain()).map(label);
  const queued = () => env.groupQueue.sent.length + env.indexQueue.sent.length;
  const actions = async (name: string) => (await rig.store.listAudit(name)).map((a) => a.action);
  const count = async (name: string, action: string) => (await actions(name)).filter((a) => a === action).length;
  const byHand = async (name: string, event: Parameters<typeof rig.store.updateVersion>[2]) => rig.store.updateVersion(name, '1.0.0', event, audit(name, 'by_hand', '1.0.0'));

  /** The package names a subdir's repodata lists as available, and those it lists as removed. */
  const repodata = (s: Scenario, subdir: string): { listed: string[]; removed: string[] } => {
    const o = env.objects.objects.get(`${subdir}/repodata.json`);
    if (!o) return { listed: [], removed: [] };
    const doc = JSON.parse(o.body.toString('utf8')) as { 'packages.conda': Record<string, { name: string }>; removed: string[] };
    const nameOf = (filename: string) => s.pkgs.find((p) => p.filename === filename)?.name ?? filename;
    return { listed: Object.values(doc['packages.conda']).map((p) => p.name.replace(/^mojo-/, '')).sort(), removed: doc.removed.map(nameOf).sort() };
  };
  /** The state a package's sparse-index file gives its version. */
  const indexState = (name: string): string | undefined => {
    const o = env.objects.objects.get(indexKey(name));
    if (!o) return undefined;
    const lines = o.body.toString('utf8').trim().split('\n');
    return (JSON.parse(lines[lines.length - 1]!) as { state: string }).state;
  };
  /** Every file the chains write, by key, as a hash of its bytes. */
  const files = (): Map<string, string> =>
    new Map(env.objects.keys().filter((k) => k.startsWith('index/') || k.endsWith('repodata.json') || k.endsWith('repodata.json.zst')).map((k) => [k, sha(env.objects.objects.get(k)!.body)]));
  /** Builds nobody asked for: every subdir's repodata, every member's index file and the takedown log. */
  async function strays(subdirs: readonly string[] = ['linux-64', 'noarch'], names: readonly string[] = NAMES) {
    const send = (body: object): QueueMessage => ({ body: JSON.stringify(body), groupId: 'stray', dedupId: 'stray' });
    for (const subdir of subdirs) await chain.runIndex(send({ type: 'index', subdir }));
    for (const name of names) await chain.runIndex(send({ type: 'index_pkg', name, rev: 0 }));
    await chain.runIndex(send({ type: 'index_takedowns' }));
  }

  describe('the request', () => {
    test.each(['open', 'validating', 'committed'])('a group that is %s cannot be yanked or unyanked: 409 group_not_settled, and nothing is written', async (stage) => {
      const s = new Scenario(env, SPECS);
      if (stage === 'open') await s.create();
      else await s.start();
      if (stage === 'committed') expect(await s.runAll()).toEqual(['committed']);
      const before = await header(s);
      const messages = queued();
      for (const body of [{ yanked: true, reason: REASON }, { yanked: false }]) {
        const r = await put(s, body);
        expect(r.statusCode).toBe(409);
        expect(errorCode(r)).toBe('group_not_settled');
        expect(json(r).error.message).toContain(`it is ${stage}`);
      }
      expect(await header(s)).toEqual(before);
      expect(queued()).toBe(messages);
      expect(await actions(`grp#${s.gid}`)).not.toContain('group_yank_request');
    });

    test('a group that is visible is yanked: the intent is on the header, the group stays visible, the rows are queued, and the answer is 202 with the group', async () => {
      const s = await visible();
      const r = await yank(s);
      expect(r.statusCode).toBe(202);
      expect(json(r)).toMatchObject({
        group_id: s.gid,
        status: 'visible',
        yank: { state: 'yanking', reason: REASON, yanked_members: 0 },
        members: [
          { name: 'app', state: 'published' },
          { name: 'base', state: 'published' },
          { name: 'lib', state: 'published' },
        ],
      });
      const h = await header(s);
      expect(h).toMatchObject({ status: 'visible', sweep_pk: 'active', resend: 0 });
      expect(h.yank).toEqual({ reason: REASON, by: 'u:1', requested_at: env.clock.now().toISOString(), yanked_set: '', seq: 1, state: 'yanking' });
      expect(env.groupQueue.sent.map((m) => ({ groupId: m.groupId, dedupId: m.dedupId, body: JSON.parse(m.body) }))).toEqual([
        { groupId: s.gid, dedupId: `grp:${s.gid}:1:y1:rows:0`, body: { type: 'yank_group', group_id: s.gid, attempt: 1, op: 'yank', seq: 1, resend: 0 } },
      ]);
      expect(env.indexQueue.sent).toEqual([]);
      // Nothing has been yanked yet: the request writes the intent and no row.
      for (const n of NAMES) expect((await stored(n))!.state).toBe('published');
      expect(await count(`grp#${s.gid}`, 'group_yank_request')).toBe(1);
    });

    test('the same request again, even at once, is one yank: one intent, one audit row, one message', async () => {
      const s = await visible();
      const both = await Promise.all([yank(s), yank(s)]);
      expect(both.map((r) => r.statusCode)).toEqual([202, 202]);
      const again = await yank(s, 'another reason');
      expect(again.statusCode).toBe(202);
      expect(json(again).yank.reason).toBe(REASON); // the first reason stands, as for a single version
      expect((await header(s)).yank!.seq).toBe(1);
      expect(await count(`grp#${s.gid}`, 'group_yank_request')).toBe(1);
      expect(env.groupQueue.sent).toHaveLength(1);
    });

    test('a request that died after writing the intent and before queueing the rows is repaired by the same request', async () => {
      const s = await visible();
      const send = env.groupQueue.send.bind(env.groupQueue);
      let broken = true;
      env.groupQueue.send = async (m) => {
        if (broken) {
          broken = false;
          throw new Error('the queue is down');
        }
        return send(m);
      };
      const first = await yank(s);
      expect(first.statusCode).toBe(500);
      expect((await header(s)).yank).toMatchObject({ state: 'yanking', seq: 1 });
      expect(env.groupQueue.sent).toEqual([]);
      expect((await yank(s)).statusCode).toBe(202);
      expect(env.groupQueue.sent).toHaveLength(1);
      expect(await finish()).toEqual(['rows yank', 'repodata linux-64', 'repodata noarch', 'index base', 'index lib', 'index app']);
      expect((await header(s)).yank!.state).toBe('yanked');
    });

    test('a yank is refused while an unyank runs and an unyank while a yank runs; a group never yanked, or restored, has nothing to unyank', async () => {
      const s = await visible();
      // Nothing to restore yet: as asked already, no message.
      const none = await unyank(s);
      expect(none.statusCode).toBe(200);
      expect((await header(s)).yank).toBeUndefined();
      expect(queued()).toBe(0);

      expect((await yank(s)).statusCode).toBe(202);
      const during = await unyank(s);
      expect(during.statusCode).toBe(409);
      expect(errorCode(during)).toBe('group_not_settled');
      expect(json(during).error.message).toContain('being yanked');
      expect((await header(s)).yank!.state).toBe('yanking');
      await finish();

      expect((await unyank(s)).statusCode).toBe(202);
      const back = await yank(s);
      expect(back.statusCode).toBe(409);
      expect(json(back).error.message).toContain('being unyanked');
      expect((await header(s)).yank!.state).toBe('unyanking');
      await finish();
      expect((await header(s)).yank!.state).toBe('restored');

      // Restored: an unyank again is as asked already.
      const rest = await unyank(s);
      expect(rest.statusCode).toBe(200);
      expect(json(rest).yank.state).toBe('restored');
      expect(queued()).toBe(0);
    });

    test('a group that is already yanked answers 200 as it is and queues nothing', async () => {
      const s = await visible();
      await yank(s);
      await finish();
      const again = await yank(s);
      expect(again.statusCode).toBe(200);
      expect(json(again).yank).toMatchObject({ state: 'yanked', yanked_members: 3 });
      expect(queued()).toBe(0);
    });

    test('a request whose write keeps losing to other writers is tried three times and then refused as group_not_settled, and queues nothing', async () => {
      const s = await visible();
      const get = rig.store.getGroup.bind(rig.store);
      const update = rig.store.updateGroup.bind(rig.store);
      // The write never lands (the group changed under it each time), and the header cannot be read again after the first read.
      let reads = 0;
      rig.store.getGroup = async (gid) => (reads++ === 0 ? get(gid) : undefined);
      rig.store.updateGroup = async () => undefined;
      const yanking = await yank(s);
      expect(yanking.statusCode).toBe(409);
      expect(errorCode(yanking)).toBe('group_not_settled');
      expect(json(yanking).error.message).toContain('changed while the request was being handled');
      rig.store.getGroup = get;
      rig.store.updateGroup = update;
      expect((await header(s)).yank).toBeUndefined();
      expect(queued()).toBe(0);

      expect((await yank(s)).statusCode).toBe(202);
      await finish();
      rig.store.updateGroup = async () => undefined;
      const restoring = await unyank(s);
      expect(restoring.statusCode).toBe(409);
      expect(json(restoring).error.message).toContain('changed while the request was being handled');
      rig.store.updateGroup = update;
      expect((await header(s)).yank!.state).toBe('yanked');
      expect(queued()).toBe(0);
    });

    test('a request repeated while the yank or unyank runs answers 202 as it is, and queues the rows again only while they are not done', async () => {
      const s = await visible();
      await yank(s);
      expect(env.groupQueue.sent).toHaveLength(1);
      await chain.step(); // the rows
      expect(env.indexQueue.sent).toHaveLength(1);
      expect((await yank(s)).statusCode).toBe(202);
      expect(queued()).toBe(1); // nothing new: the rows are done and the first hop is queued
      await finish();

      await unyank(s);
      expect((await unyank(s)).statusCode).toBe(202);
      expect(env.groupQueue.sent).toHaveLength(1); // the same rows message: the queue drops the repeat
      await chain.step();
      expect((await unyank(s)).statusCode).toBe(202);
      expect(queued()).toBe(1);
      await finish();
      expect((await header(s)).yank!.state).toBe('restored');
    });

    test('a second yank after a restore is a yank of its own: a new sequence number on the rows, and messages the queue does not drop as repeats', async () => {
      const s = await visible();
      const ids: string[] = [];
      const run = async (request: () => ReturnType<typeof yank>) => {
        expect((await request()).statusCode).toBe(202);
        ids.push(env.groupQueue.sent[0]!.dedupId);
        await finish();
      };
      await run(() => yank(s));
      await run(() => unyank(s));
      await run(() => yank(s, 'again'));
      expect(ids).toEqual([`grp:${s.gid}:1:y1:rows:0`, `grp:${s.gid}:1:u1:rows:0`, `grp:${s.gid}:1:y2:rows:0`]);
      const h = await header(s);
      expect(h.yank).toMatchObject({ seq: 2, state: 'yanked', reason: 'again' });
      for (const n of NAMES) expect(await stored(n)).toMatchObject({ state: 'yanked', yank_reason: 'again', group_yank_seq: 2 });
      expect(indexState('lib')).toBe('yanked');
    });

    test('read-only mode does not stop a yank or an unyank, as it does not stop a single version\'s: both are accepted and their chains run', async () => {
      const s = await visible();
      env.flags.ro = true;
      expect((await yank(s)).statusCode).toBe(202);
      await finish();
      expect((await header(s)).yank).toMatchObject({ state: 'yanked', reason: REASON });
      for (const n of NAMES) expect(await stored(n)).toMatchObject({ state: 'yanked' });
      expect(indexState('lib')).toBe('yanked');
      expect((await unyank(s)).statusCode).toBe(202);
      await finish();
      expect((await header(s)).yank).toMatchObject({ state: 'restored' });
      for (const n of NAMES) expect(await stored(n)).toMatchObject({ state: 'published' });
      expect(indexState('lib')).toBe('published');
    });

    test('a token that does not cover every member, an unknown group and a stranger are refused, and so is a bad body; the group is unchanged', async () => {
      const s = await visible();
      const before = await header(s);

      const partial = await env.token(1, ['app', 'base']);
      const scope = await put(s, { yanked: true, reason: REASON }, partial);
      expect(scope.statusCode).toBe(403);
      expect(errorCode(scope)).toBe('scope_missing');

      const stranger = await env.account(2, 'other', ['zzz']);
      expect((await put(s, { yanked: true, reason: REASON }, stranger)).statusCode).toBe(404);
      const nobody = await env.call('PUT', `/api/v1/groups/${s.gid}/yank`, undefined, { yanked: true, reason: REASON });
      expect(nobody.statusCode).toBe(401);
      const unknown = await env.call('PUT', `/api/v1/groups/grp_${'0'.repeat(32)}/yank`, s.token, { yanked: true, reason: REASON });
      expect(errorCode(unknown)).toBe('group_not_found');

      for (const body of [{ yanked: true }, { yanked: true, reason: 'x'.repeat(281) }, { yanked: 'yes' }, '{not json']) {
        const bad = await put(s, body);
        expect(bad.statusCode).toBe(400);
        expect(errorCode(bad)).toBe('invalid_request');
      }
      expect(await header(s)).toEqual(before);
      expect(queued()).toBe(0);

      // A token with the yank scope alone is enough.
      const t = env.clock.now();
      const yankOnly = await mintToken(env.authStore, { kind: 'api', github_id: 1, name: 'y', scopes: ['yank'], packages: NAMES, all_current: false, created_at: t.toISOString(), expires_at: new Date(t.getTime() + 86_400_000).toISOString() });
      expect((await put(s, { yanked: true, reason: REASON }, yankOnly.secret)).statusCode).toBe(202);
    });

    test('the creator who is no longer an owner of one member is refused a yank and an unyank with 403 not_owner, the token still holding its scopes, and nothing is written; an owner of every member is not', async () => {
      const s = await visible();
      expect((await yank(s)).statusCode).toBe(202);
      await finish();
      const yanked = await header(s);
      await rig.store.removeOwner('lib', 1);
      const messages = queued();
      for (const body of [{ yanked: false }, { yanked: true, reason: 'again' }]) {
        const r = await put(s, body);
        expect(r.statusCode).toBe(403);
        expect(errorCode(r)).toBe('not_owner');
        expect(json(r).error.message).toContain("'lib'");
      }
      expect(await header(s)).toEqual(yanked);
      expect(queued()).toBe(messages);
      expect(await actions(`grp#${s.gid}`)).not.toContain('group_unyank_request');
      // Owning every member again restores the right to unyank.
      await rig.store.addOwner({ name: 'lib', github_id: 1, handle: 'owner', added_at: env.clock.now().toISOString() });
      expect((await unyank(s)).statusCode).toBe(202);
    });

    test('a deployment without the group queue answers unavailable and writes nothing', async () => {
      const s = await visible();
      const before = await header(s);
      const groups = new GroupService({ registry: rig.store, publishes: env.publishes, objects: env.objects, presigner: new MemoryPresigner(), config: env.config, now: env.clock.now });
      const deps = { ...env.deps, publish: { ...env.deps.publish!, groups } };
      const r = await route({ method: 'PUT', path: `/api/v1/groups/${s.gid}/yank`, query: {}, headers: { authorization: `Bearer ${s.token}` }, body: JSON.stringify({ yanked: true, reason: REASON }) }, deps, 'req-1');
      expect(r.statusCode).toBe(503);
      expect(errorCode(r)).toBe('unavailable');
      expect(await header(s)).toEqual(before);
    });
  });

  describe('the yank', () => {
    test('touches only the members that are published, records exactly those in yanked_set, and leaves a member yanked by hand, or taken down, as it is', async () => {
      const s = await visible();
      const lib0 = (await stored('lib'))!;
      await byHand('app', { type: 'yank', reason: 'by hand' });
      await byHand('base', { type: 'tombstone', reason_code: 'security', date: '2026-10-20' });
      const appBefore = (await stored('app'))!;
      const baseBefore = (await stored('base'))!;

      expect((await yank(s)).statusCode).toBe(202);
      const ran = await chain.drain();
      expect(ran.map(label)).toEqual(['rows yank', 'repodata linux-64', 'index lib']);
      expect(ran[0]).toMatchObject({ queue: 'yank', outcome: 'done' });

      const h = await header(s);
      expect(h.status).toBe('visible');
      expect(h.yank).toMatchObject({ state: 'yanked', seq: 1, rows_done: true, repodata_done: ['linux-64'], index_done: [1] });
      expect(bitmapIndexes(h.yank!.yanked_set)).toEqual([2]); // lib alone: app was yanked by hand and base taken down
      expect(h.sweep_pk).toBeUndefined();
      expect(h.sweep_at).toBeUndefined();
      expect(h.resend).toBe(0);
      expect((await rig.store.listActiveGroups()).map((g) => g.group_id)).not.toContain(s.gid);

      // The one member the yank changed carries the reason and the marker of the yank.
      expect(await stored('lib')).toMatchObject({ state: 'yanked', yank_reason: REASON, group_yank_seq: 1, rev: lib0.rev + 1 });
      // The others are the rows they were, byte for byte.
      expect(await stored('app')).toEqual(appBefore);
      expect(await stored('base')).toEqual(baseBefore);
      expect((await stored('app'))!.group_yank_seq).toBeUndefined();

      // Audit: one row for the member that changed, none for the others; the group's own rows.
      expect(await count('lib', 'group_yank')).toBe(1);
      expect((await rig.store.listAudit('lib')).find((a) => a.action === 'group_yank')).toMatchObject({ actor: 'u:1', version: '1.0.0', detail: { group_id: s.gid, reason: REASON } });
      expect(await count('app', 'group_yank')).toBe(0);
      expect(await count('base', 'group_yank')).toBe(0);
      expect(await actions(`grp#${s.gid}`)).toEqual(expect.arrayContaining(['group_yank_request', 'group_yanked']));
      expect(await count(`grp#${s.gid}`, 'group_yanked')).toBe(1);

      // The files follow: lib leaves repodata's available packages, and its index file says yanked.
      expect(repodata(s, 'linux-64')).toEqual({ listed: [], removed: ['lib'] });
      expect(indexState('lib')).toBe('yanked');
      // What the API shows.
      const shown = await env.call('GET', '/api/v1/packages/lib/1.0.0');
      expect(json(shown)).toMatchObject({ state: 'yanked', yank_reason: REASON });
      const status = json(await env.get(s.token, s.gid));
      expect(status.yank).toMatchObject({ state: 'yanked', yanked_members: 1 });
      expect(status.members.map((m: { name: string; state: string }) => [m.name, m.state])).toEqual([['app', 'published'], ['base', 'published'], ['lib', 'yanked']]);
    });

    test('a yank of every member runs the rows, the repodata hops and the index hops in dependency order, and ends once', async () => {
      const s = await visible();
      await yank(s);
      const ran = await chain.drain();
      expect(ran.map(label)).toEqual(['rows yank', 'repodata linux-64', 'repodata noarch', 'index base', 'index lib', 'index app']);
      const h = await header(s);
      expect(bitmapIndexes(h.yank!.yanked_set)).toEqual([0, 1, 2]);
      expect(h.yank).toMatchObject({ state: 'yanked', index_done: [0, 1, 2] });
      for (const n of NAMES) {
        expect(indexState(n)).toBe('yanked');
        expect(await stored(n)).toMatchObject({ state: 'yanked', group_yank_seq: 1 });
      }
      expect(repodata(s, 'linux-64')).toEqual({ listed: [], removed: ['lib'] });
      expect(repodata(s, 'noarch')).toEqual({ listed: [], removed: ['app', 'base'] });
      expect(await count(`grp#${s.gid}`, 'group_yanked')).toBe(1);
      expect(env.indexQueue.sent).toEqual([]);
      expect(env.groupQueue.sent).toEqual([]);
    });

    test('the dedup ids of the steps carry the yank, the step and the resend count', async () => {
      const s = await visible();
      await yank(s);
      const ids: string[] = [];
      for (let m = env.groupQueue.take() ?? env.indexQueue.take(); m; m = env.indexQueue.take() ?? env.groupQueue.take()) {
        ids.push(m.dedupId);
        if (JSON.parse(m.body).type === 'yank_group') await chain.runYank(m);
        else await chain.runIndex(m);
      }
      expect(ids).toEqual(['rows', 'r-linux-64', 'r-noarch', 'i-0', 'i-1', 'i-2'].map((step) => `grp:${s.gid}:1:y1:${step}:0`));
    });
  });

  describe('the unyank', () => {
    test('restores only the members the yank changed: a member yanked by hand stays yanked, a member taken down stays taken down', async () => {
      const s = await visible();
      await byHand('app', { type: 'yank', reason: 'by hand' });
      await byHand('base', { type: 'tombstone', reason_code: 'security', date: '2026-10-20' });
      await yank(s);
      await finish();
      const yankedLib = (await stored('lib'))!;
      const appAfterYank = (await stored('app'))!;
      const baseAfterYank = (await stored('base'))!;

      const r = await unyank(s);
      expect(r.statusCode).toBe(202);
      expect(json(r).yank).toMatchObject({ state: 'unyanking', yanked_members: 1 });
      expect(json(r).members.find((m: { name: string }) => m.name === 'lib').state).toBe('yanked'); // until the unyank has ended
      expect(await header(s)).toMatchObject({ sweep_pk: 'active', yank: { state: 'unyanking', unyank_by: 'u:1', seq: 1 } });
      expect((await header(s)).yank!.rows_done).toBeUndefined();

      expect(await finish()).toEqual(['rows unyank', 'repodata linux-64', 'index lib']);
      const h = await header(s);
      expect(h.yank).toMatchObject({ state: 'restored', rows_done: true, repodata_done: ['linux-64'], index_done: [1] });
      expect(bitmapIndexes(h.yank!.yanked_set)).toEqual([2]);
      expect(h.sweep_pk).toBeUndefined();

      const lib = (await stored('lib'))!;
      expect(lib).toMatchObject({ state: 'published', rev: yankedLib.rev + 1 });
      expect(lib.yank_reason).toBeUndefined();
      expect(lib.group_yank_seq).toBeUndefined();
      expect(await stored('app')).toEqual(appAfterYank); // yanked by hand, and stays so
      expect(await stored('base')).toEqual(baseAfterYank);
      expect(await count('lib', 'group_unyank')).toBe(1);
      expect(await count('app', 'group_unyank')).toBe(0);
      expect(await actions(`grp#${s.gid}`)).toEqual(expect.arrayContaining(['group_unyank_request', 'group_unyanked']));

      expect(repodata(s, 'linux-64')).toEqual({ listed: ['lib'], removed: [] });
      expect(indexState('lib')).toBe('published');
      const status = json(await env.get(s.token, s.gid));
      expect(status.yank.state).toBe('restored');
      expect(status.members.find((m: { name: string }) => m.name === 'lib').state).toBe('published');
    });

    test('a member that somebody unyanked and yanked again by hand after the group yank is not restored by the group unyank', async () => {
      const s = await visible();
      await yank(s);
      await finish();
      await byHand('app', { type: 'unyank' });
      expect((await stored('app'))!.group_yank_seq).toBeUndefined(); // the hand cleared the group's mark
      await byHand('app', { type: 'yank', reason: 'again by hand' });
      expect((await stored('app'))!.group_yank_seq).toBeUndefined();

      await unyank(s);
      expect(await finish()).toEqual(['rows unyank', 'repodata linux-64', 'repodata noarch', 'index base', 'index lib', 'index app']);
      expect(await stored('app')).toMatchObject({ state: 'yanked', yank_reason: 'again by hand' });
      expect(await stored('base')).toMatchObject({ state: 'published' });
      expect(await stored('lib')).toMatchObject({ state: 'published' });
      expect(indexState('app')).toBe('yanked');
      expect(indexState('base')).toBe('published');
      expect(repodata(s, 'noarch')).toEqual({ listed: ['base'], removed: ['app'] });
    });

    test('the second yank is undone by the second unyank, not by the first one\'s marks', async () => {
      const s = await visible();
      await yank(s);
      await finish();
      await unyank(s);
      await finish();
      await byHand('lib', { type: 'yank', reason: 'by hand, between' });
      await yank(s, 'again');
      await finish();
      // The hand's yank was first and the group's second yank left it alone.
      expect(await stored('lib')).toMatchObject({ state: 'yanked', yank_reason: 'by hand, between' });
      expect(bitmapIndexes((await header(s)).yank!.yanked_set)).toEqual([0, 1]);
      await unyank(s);
      await finish();
      expect(await stored('lib')).toMatchObject({ state: 'yanked', yank_reason: 'by hand, between' });
      expect(await stored('app')).toMatchObject({ state: 'published' });
    });
  });

  describe('delivered more than once', () => {
    test('the rows of a yank twice change each row once: one audit row, one revision, and the next hop queued once', async () => {
      const s = await visible();
      const revs = await Promise.all(NAMES.map(async (n) => (await stored(n))!.rev));
      await yank(s);
      const raw = env.groupQueue.take()!;
      expect(await chain.runYank(raw)).toMatchObject({ outcome: 'done' });
      expect(await chain.runYank(raw)).toMatchObject({ outcome: 'already' });
      expect(await Promise.all(NAMES.map(async (n) => (await stored(n))!.rev))).toEqual(revs.map((r) => r + 1));
      for (const n of NAMES) expect(await count(n, 'group_yank')).toBe(1);
      expect(env.indexQueue.sent.map((m) => m.groupId)).toEqual(['linux-64']);
      expect(bitmapIndexes((await header(s)).yank!.yanked_set)).toEqual([0, 1, 2]);
      expect(await finish()).toEqual(['repodata linux-64', 'repodata noarch', 'index base', 'index lib', 'index app']);
    });

    test('rows that were changed before the header could say so are found again by their mark: the set is complete and no row is written twice', async () => {
      const s = await visible();
      await yank(s);
      const raw = env.groupQueue.take()!;
      const update = rig.store.updateGroup.bind(rig.store);
      let crash = true;
      rig.store.updateGroup = async (gid, fn, a) => {
        if (crash) {
          crash = false;
          throw new Error('the job died after changing the rows');
        }
        return update(gid, fn, a);
      };
      await expect(chain.runYank(raw)).rejects.toThrow('died');
      for (const n of NAMES) expect(await stored(n)).toMatchObject({ state: 'yanked', group_yank_seq: 1 });
      expect((await header(s)).yank!.yanked_set).toBe('');
      const revs = await Promise.all(NAMES.map(async (n) => (await stored(n))!.rev));

      // The redelivered message finds nothing to change, and still records the members as the yank's.
      expect(await chain.runYank(raw)).toMatchObject({ outcome: 'done' });
      expect(bitmapIndexes((await header(s)).yank!.yanked_set)).toEqual([0, 1, 2]);
      expect(await Promise.all(NAMES.map(async (n) => (await stored(n))!.rev))).toEqual(revs);
      for (const n of NAMES) expect(await count(n, 'group_yank')).toBe(1);
      await finish();
      expect((await header(s)).yank!.state).toBe('yanked');
    });

    test('the rows of an unyank twice restore each row once', async () => {
      const s = await visible();
      await yank(s);
      await finish();
      const yankedRevs = await Promise.all(NAMES.map(async (n) => (await stored(n))!.rev));
      await unyank(s);
      const raw = env.groupQueue.take()!;
      expect(await chain.runYank(raw)).toMatchObject({ outcome: 'done' });
      expect(await chain.runYank(raw)).toMatchObject({ outcome: 'already' });
      expect(await Promise.all(NAMES.map(async (n) => (await stored(n))!.rev))).toEqual(yankedRevs.map((r) => r + 1));
      for (const n of NAMES) expect(await count(n, 'group_unyank')).toBe(1);
      expect(env.indexQueue.sent).toHaveLength(1);
      await finish();
      expect((await header(s)).yank!.state).toBe('restored');
    });

    test('a hop twice writes the same bytes, sets its gate once and queues the next step once', async () => {
      const s = await visible();
      await yank(s);
      await chain.step(); // the rows
      const hop = env.indexQueue.take()!;
      await chain.runIndex(hop);
      const afterFirst = files();
      const gates = (await header(s)).yank!;
      expect(gates.repodata_done).toEqual(['linux-64']);
      expect(env.indexQueue.sent.map((m) => m.groupId)).toEqual(['noarch']);
      await chain.runIndex(hop);
      expect(files()).toEqual(afterFirst);
      expect((await header(s)).yank).toEqual({ ...gates });
      expect(env.indexQueue.sent).toHaveLength(1); // the queue dropped the second copy of the next step
    });

    test('an index hop twice writes the same bytes, releases its position once and queues the next step once; a position beyond the write order is refused', async () => {
      const s = await visible();
      await yank(s);
      for (let i = 0; i < 3; i++) await chain.step(); // the rows, and the two repodata hops
      const hop = env.indexQueue.take()!;
      await chain.runIndex(hop);
      const afterFirst = files();
      const gates = (await header(s)).yank!;
      expect(gates.index_done).toEqual([0]);
      expect(env.indexQueue.sent.map((m) => m.groupId)).toEqual(['pkg:lib']);
      await chain.runIndex(hop);
      expect(files()).toEqual(afterFirst);
      expect((await header(s)).yank).toEqual(gates);
      expect(env.indexQueue.sent).toHaveLength(1);

      const beyond: QueueMessage = { body: JSON.stringify({ type: 'index_pkg', name: 'base', rev: 0, group: { group_id: s.gid, attempt: 1, resend: 0, yank: { op: 'yank', seq: 1 }, position: 9 } }), groupId: 'pkg:base', dedupId: 'beyond' };
      await chain.runIndex(beyond);
      expect((await header(s)).yank).toEqual(gates);
      expect(files()).toEqual(afterFirst);
      expect(await finish()).toEqual(['index lib', 'index app']);
    });

    test('rows of a yank whose group stopped being in that yank while they were changed leave the group as it is and queue nothing', async () => {
      const s = await visible();
      await yank(s);
      const raw = env.groupQueue.take()!;
      const apply = rig.store.applyGroupEvent.bind(rig.store);
      let once = true;
      rig.store.applyGroupEvent = async (name, version, event, a) => {
        const row = await apply(name, version, event, a);
        if (once) {
          once = false;
          // Another worker ended the yank meanwhile.
          await rig.store.updateGroup(s.gid, (cur) => ({ ...cur, yank: { ...cur.yank!, state: 'yanked' } }));
        }
        return row;
      };
      expect(await chain.runYank(raw)).toMatchObject({ outcome: 'skipped' });
      expect(env.indexQueue.sent).toEqual([]);
      expect((await header(s)).yank!.rows_done).toBeUndefined();
    });

    test('every message of a finished yank, delivered again, does nothing: no byte, no row, no audit row, no message', async () => {
      const s = await visible();
      await yank(s);
      const ran = await chain.drain();
      expect(ran).toHaveLength(6);
      const settled = { files: files(), header: await header(s), rows: await Promise.all(NAMES.map((n) => stored(n))), audits: await actions(`grp#${s.gid}`) };
      chain.log.length = 0;
      for (const r of ran) {
        if (r.queue === 'yank') expect(await chain.runYank(r.raw)).toMatchObject({ outcome: 'skipped' });
        else if (r.queue === 'index') await chain.runIndex(r.raw);
      }
      expect(files()).toEqual(settled.files);
      expect(await header(s)).toEqual(settled.header);
      expect(await Promise.all(NAMES.map((n) => stored(n)))).toEqual(settled.rows);
      expect(await actions(`grp#${s.gid}`)).toEqual(settled.audits);
      expect(queued()).toBe(0);
      expect(chain.log.filter((l) => String(l.msg).includes('nothing done'))).toHaveLength(6);
    });

    test('hops that are not for the yank that is running release nothing and build nothing', async () => {
      const s = await visible();
      // `app` and `base` are taken down, so the yank changes `lib` alone: its subdir is linux-64, and its place in the write order is 1.
      await byHand('app', { type: 'tombstone', reason_code: 'security', date: '2026-10-20' });
      await byHand('base', { type: 'tombstone', reason_code: 'security', date: '2026-10-20' });
      await yank(s);
      const hop = (yankOf: { op: string; seq: number } | undefined, over: { group_id?: string; attempt?: number } = {}) => ({
        group_id: over.group_id ?? s.gid,
        attempt: over.attempt ?? 1,
        resend: 0,
        ...(yankOf ? { yank: yankOf } : {}),
      });
      const repodataMsg = (subdir: string, h: object): QueueMessage => ({ body: JSON.stringify({ type: 'index', subdir, then: { group: h } }), groupId: subdir, dedupId: `x-${Math.random()}` });
      const indexMsg = (name: string, position: number, h: object): QueueMessage => ({ body: JSON.stringify({ type: 'index_pkg', name, rev: 0, group: { ...h, position } }), groupId: `pkg:${name}`, dedupId: `x-${Math.random()}` });
      const keys = () => env.objects.keys().sort();
      const settled = { keys: keys(), files: files(), header: await header(s) };
      const nothing = async () => {
        expect(keys()).toEqual(settled.keys);
        expect(files()).toEqual(settled.files);
        expect(await header(s)).toEqual(settled.header);
      };
      const mine = { op: 'yank', seq: 1 };

      // Before the rows: the repodata hop is stale, and an index hop sends the rows again (a repeat the queue drops).
      await chain.runIndex(repodataMsg('linux-64', hop(mine)));
      await nothing();
      await chain.runIndex(indexMsg('lib', 1, hop(mine)));
      await nothing();
      expect(chain.log.some((l) => String(l.msg).includes('arrived before the rows were done'))).toBe(true);
      expect(env.groupQueue.sent).toHaveLength(1);

      await chain.step(); // the rows
      const real = env.indexQueue.take()!;
      const rowsDone = await header(s);
      settled.header = rowsDone;
      settled.files = files();
      settled.keys = keys();

      // Another yank's number, another attempt, another group, an unyank of this yank, a yank hop of a group with no yank.
      await chain.runIndex(repodataMsg('linux-64', hop({ op: 'yank', seq: 2 })));
      await chain.runIndex(repodataMsg('linux-64', hop(mine, { attempt: 2 })));
      await chain.runIndex(repodataMsg('linux-64', hop(mine, { group_id: `grp_${'0'.repeat(32)}` })));
      await chain.runIndex(repodataMsg('linux-64', hop({ op: 'unyank', seq: 1 })));
      await nothing();
      // A subdir none of the yanked members has a file in; a member that was not yanked.
      await chain.runIndex(repodataMsg('noarch', hop(mine)));
      await chain.runIndex(indexMsg('base', 0, hop(mine)));
      await chain.runIndex(indexMsg('lib', 0, hop(mine))); // lib's place is 1: a name at the wrong place
      await nothing();
      // An index hop before the repodata gate: it releases nothing and the step that is missing is the one already queued.
      await chain.runIndex(indexMsg('lib', 1, hop(mine)));
      await nothing();
      expect(chain.log.some((l) => String(l.msg).includes('arrived before the steps it follows'))).toBe(true);

      // The real hop goes on.
      await chain.runIndex(real);
      expect((await header(s)).yank!.repodata_done).toEqual(['linux-64']);
      expect(await finish()).toEqual(['index lib']);
      expect((await header(s)).yank!.state).toBe('yanked');
    });
  });

  describe('builds nobody asked for', () => {
    test('a yank while stray builds run converges: the files are those a build after the yank writes, and every member is yanked in each', async () => {
      const s = await visible();
      await strays();
      const before = files();
      await yank(s);
      await strays();
      await chain.drain(async () => {
        await strays();
      });
      const after = files();
      expect(after).not.toEqual(before);
      await strays();
      expect(files()).toEqual(after);
      for (const n of NAMES) expect(indexState(n)).toBe('yanked');
      expect(repodata(s, 'linux-64')).toEqual({ listed: [], removed: ['lib'] });
      expect(repodata(s, 'noarch')).toEqual({ listed: [], removed: ['app', 'base'] });
      expect((await header(s)).yank!.state).toBe('yanked');
    });

    test('a build between the rows and the hops of a yank already says yanked everywhere: the yank direction is the safe one', async () => {
      const s = await visible();
      await yank(s);
      await chain.step(); // the rows
      expect((await header(s)).yank!.repodata_done).toBeUndefined();
      await strays();
      for (const n of NAMES) expect(indexState(n)).toBe('yanked');
      expect(repodata(s, 'linux-64').listed).toEqual([]);
      expect(repodata(s, 'noarch').listed).toEqual([]);
      await finish();
      const settled = files();
      await strays();
      expect(files()).toEqual(settled);
    });

    test('an unyank while stray builds run converges to the files of a group that was never yanked', async () => {
      const s = await visible();
      await strays();
      const original = files();
      await yank(s);
      await finish();
      await unyank(s);
      await strays();
      await chain.drain(async () => {
        await strays();
      });
      await strays();
      // The index files carry the revision of the rows (a yank and an unyank are two changes), so compare what they say.
      for (const n of NAMES) expect(indexState(n)).toBe('published');
      expect(repodata(s, 'linux-64')).toEqual({ listed: ['lib'], removed: [] });
      expect(repodata(s, 'noarch')).toEqual({ listed: ['app', 'base'], removed: [] });
      for (const k of ['linux-64/repodata.json', 'noarch/repodata.json']) expect(files().get(k)).toBe(original.get(k));
    });

    test('between the rows and the repodata hops of an unyank, a build nobody asked for can list a restored member in the index before repodata lists it, as for a single version; the hops put both right', async () => {
      const s = await visible();
      await yank(s);
      await finish();
      await unyank(s);
      await chain.step(); // the rows: lib is a published row again
      await strays([], ['lib']);
      expect(indexState('lib')).toBe('published');
      expect(repodata(s, 'linux-64')).toEqual({ listed: [], removed: ['lib'] });
      expect(await finish()).toEqual(['repodata linux-64', 'repodata noarch', 'index base', 'index lib', 'index app']);
      expect(repodata(s, 'linux-64')).toEqual({ listed: ['lib'], removed: [] });
      expect(indexState('lib')).toBe('published');
    });
  });

  describe('the sweeper looks after a yank or unyank that stopped', () => {
    const sweep = (lines?: Array<Record<string, unknown>>) =>
      sweepGroups({ groups: rig.store, groupQueue: env.groupQueue, indexQueue: env.indexQueue, now: env.clock.now, metrics: new Metrics((l) => lines?.push(l)), log: (l) => chain.log.push(l) });
    const takeNext = () => env.indexQueue.take() ?? env.groupQueue.take();
    const STEPS = ['rows', 'repodata linux-64', 'repodata noarch', 'index base', 'index lib', 'index app'];

    describe.each(['yank', 'unyank'] as const)('a %s', (op) => {
      /** A visible group, with the request of `op` made (an unyank is of a group that has been yanked and is at rest). */
      async function requested(): Promise<Scenario> {
        const s = await visible();
        if (op === 'unyank') {
          await yank(s);
          await finish();
        }
        expect((await (op === 'yank' ? yank(s) : unyank(s))).statusCode).toBe(202);
        return s;
      }

      test.each(STEPS.map((step, k) => [step, k] as const))('a lost %s message (message %i) is sent again once the group has been quiet for ten minutes, and the chain finishes from it', async (_step, k) => {
        const s = await requested();
        for (let i = 0; i < k; i++) await chain.step();
        const lost = takeNext()!;
        expect(lost).toBeDefined();
        expect(queued()).toBe(0);

        env.clock.advance(CHAIN_STALL_MS - MINUTE);
        expect(await sweep()).toMatchObject({ yanking: 1, resent: [], gaveUp: [] });
        expect(queued()).toBe(0);

        env.clock.advance(2 * MINUTE);
        const r = await sweep();
        expect(r).toMatchObject({ yanking: 1, resent: [s.gid], gaveUp: [] });
        expect((await header(s)).resend).toBe(1);
        const again = takeNext()!;
        // The same step under a dedup id of its own: the queue remembers the lost message's id and would have dropped a copy of it.
        expect(JSON.parse(again.body)).toEqual(JSON.parse(lost.body.replace(/"resend":0/g, '"resend":1')));
        expect(again.groupId).toBe(lost.groupId);
        expect(again.dedupId).toBe(lost.dedupId.replace(/:0$/, ':1'));
        expect(await actions(`grp#${s.gid}`)).toContain('group_resend');

        // It is not sent again before the group has had the time again.
        env.clock.advance(5 * MINUTE);
        expect((await sweep()).resent).toEqual([]);

        (again.groupId === s.gid ? env.groupQueue : env.indexQueue).sent.unshift(again);
        await chain.drain();
        const h = await header(s);
        expect(h).toMatchObject({ status: 'visible', resend: 0, yank: { state: op === 'yank' ? 'yanked' : 'restored' } });
        expect(h.sweep_pk).toBeUndefined();
        for (const n of NAMES) expect(indexState(n)).toBe(op === 'yank' ? 'yanked' : 'published');
        expect((await rig.store.listActiveGroups()).map((g) => g.group_id)).not.toContain(s.gid);
      });

      test('a step that keeps being lost is sent again three times and then left to a person, with the alarm metric', async () => {
        const s = await requested();
        const lines: Array<Record<string, unknown>> = [];
        const ids: string[] = [];
        takeNext(); // lost
        for (let k = 1; k <= MAX_RESENDS; k++) {
          env.clock.advance(CHAIN_STALL_MS + MINUTE);
          expect((await sweep(lines)).resent).toEqual([s.gid]);
          ids.push(takeNext()!.dedupId); // lost again
        }
        const tag = op === 'yank' ? 'y1' : 'u1';
        expect(ids).toEqual([1, 2, 3].map((n) => `grp:${s.gid}:1:${tag}:rows:${n}`));
        env.clock.advance(CHAIN_STALL_MS + MINUTE);
        expect(await sweep(lines)).toMatchObject({ resent: [], gaveUp: [s.gid] });
        expect(queued()).toBe(0);
        expect(lines.map((l) => l.group_sweeper_gave_up)).toEqual([0, 0, 0, 1]);
        expect(await header(s)).toMatchObject({ status: 'visible', resend: MAX_RESENDS, yank: { state: op === 'yank' ? 'yanking' : 'unyanking' } });
        expect(chain.log.some((l) => String(l.msg).includes('as often as it will'))).toBe(true);
      });

      test('one that is moving is left alone, and a hop is a sign of life that sets the resend count back', async () => {
        const s = await requested();
        for (let i = 0; i < 3; i++) {
          env.clock.advance(CHAIN_STALL_MS - MINUTE);
          expect((await sweep()).resent).toEqual([]);
          await chain.step();
        }
        takeNext(); // lost
        env.clock.advance(CHAIN_STALL_MS + MINUTE);
        expect((await sweep()).resent).toEqual([s.gid]);
        expect((await header(s)).resend).toBe(1);
        await chain.drain();
        expect((await header(s)).resend).toBe(0);
        expect((await header(s)).yank!.state).toBe(op === 'yank' ? 'yanked' : 'restored');
      });
    });

    test('a yank whose last hop wrote its file and died before the end is finished by the sweeper, with no message', async () => {
      const s = await visible();
      await yank(s);
      for (let i = 0; i < 5; i++) await chain.step();
      const update = rig.store.updateGroup.bind(rig.store);
      let crash = true;
      rig.store.updateGroup = async (gid, fn, a) => {
        if (crash && a?.action === 'group_yanked') {
          crash = false;
          throw new Error('the hop died before the end');
        }
        return update(gid, fn, a);
      };
      await expect(chain.step()).rejects.toThrow('before the end');
      expect(indexState('app')).toBe('yanked'); // the last file is written
      expect(await header(s)).toMatchObject({ sweep_pk: 'active', yank: { state: 'yanking', index_done: [0, 1, 2] } });

      env.clock.advance(CHAIN_STALL_MS + MINUTE);
      expect((await sweep()).resent).toEqual([s.gid]);
      expect(queued()).toBe(0);
      const h = await header(s);
      expect(h).toMatchObject({ yank: { state: 'yanked' }, resend: 0 });
      expect(h.sweep_pk).toBeUndefined();
      expect(await count(`grp#${s.gid}`, 'group_yanked')).toBe(1);
    });

    test('a visible group whose yank has ended is not in the sweeper\'s hands even if its index entry is late', async () => {
      const s = await visible();
      await yank(s);
      await finish();
      env.clock.advance(CHAIN_STALL_MS + MINUTE);
      // The index is eventually consistent: an entry of a group whose yank ended is read again from the header and left alone.
      const list = rig.store.listActiveGroups.bind(rig.store);
      rig.store.listActiveGroups = async () => [{ group_id: s.gid, status: 'visible', attempt: 1, actor: 'u:1', rev: 1, progress_at: '2026-10-14T12:00:00Z', sweep_at: '2026-10-14T12:00:00Z', deadline_at: '2026-10-15T00:00:00Z', resend: 0 }, ...(await list())];
      expect(await sweep()).toMatchObject({ yanking: 1, resent: [], gaveUp: [] });
      expect(queued()).toBe(0);
    });
  });

  describe("the operator's tool", () => {
    const out: Array<Record<string, unknown>> = [];
    const status = () => runOps({ mode: 'status', apply: false }, { groups: rig.store, queueDepth: async () => [], now: env.clock.now, out: (l) => out.push(l) });
    const groupLine = () => out.filter((l) => l.kind === 'group').at(-1);
    beforeEach(() => {
      out.length = 0;
    });

    test('says a group is not safe to revert from the request of a yank until its end, and how far it is; a yank that is over is not listed', async () => {
      const s = await visible();
      expect(await status()).toBe(0);
      expect(out.at(-1)).toMatchObject({ kind: 'verdict', safe_to_revert: true, groups_not_over: 0 });

      await yank(s);
      out.length = 0;
      expect(await status()).toBe(3);
      expect(groupLine()).toMatchObject({ group_id: s.gid, status: 'visible', yank: 'yanking', yanked_members: 0, committed: true, unflipped: 0, members: 3 });
      expect(out.at(-1)).toMatchObject({ kind: 'verdict', safe_to_revert: false, groups_not_over: 1 });

      await chain.step(); // the rows
      out.length = 0;
      expect(await status()).toBe(3);
      expect(groupLine()).toMatchObject({ yank: 'yanking', yanked_members: 3 });

      await chain.drain();
      out.length = 0;
      expect(await status()).toBe(0);
      expect(out.filter((l) => l.kind === 'group')).toEqual([]);
      expect(out.at(-1)).toMatchObject({ kind: 'verdict', safe_to_revert: true, groups_not_over: 0 });
    });

    test('says the same of an unyank, and lists its state', async () => {
      const s = await visible();
      await yank(s);
      await finish();
      await unyank(s);
      expect(await status()).toBe(3);
      expect(groupLine()).toMatchObject({ group_id: s.gid, yank: 'unyanking', yanked_members: 3 });
      expect(out.at(-1)).toMatchObject({ safe_to_revert: false });
      await finish();
      out.length = 0;
      expect(await status()).toBe(0);
      expect(out.at(-1)).toMatchObject({ safe_to_revert: true });
    });

    test('lists a group that was never yanked with no yank', async () => {
      const s = await new Scenario(env, SPECS).start();
      expect(await s.runAll()).toEqual(['committed']);
      expect(await status()).toBe(3);
      expect(groupLine()).toMatchObject({ status: 'committed', yank: null, yanked_members: null });
    });
  });
});

describe('the events of a group yank on a row', () => {
  const gid = 'grp_0123456789abcdef0123456789abcdef';
  const row = (over: Partial<VersionRecord> = {}) => rec({ name: 'lib', version: '1.0.0', group_id: gid, staged_attempt: 1, rev: 2, ...over });
  const yankEvent = { type: 'group_yank', group_id: gid, seq: 3, reason: 'broken' } as const;
  const unyankEvent = { type: 'group_unyank', group_id: gid, seq: 3 } as const;

  test('a published member becomes yanked with the reason and the mark of the yank, and the same event again changes nothing', () => {
    const r = row();
    const yanked = applyEvent(r, yankEvent);
    expect(yanked).toMatchObject({ state: 'yanked', yank_reason: 'broken', group_yank_seq: 3, rev: 3, group_id: gid });
    expect(applyEvent(yanked, yankEvent)).toBe(yanked);
  });

  test('a member yanked by hand, taken down or not yet published is left as it is', () => {
    for (const r of [row({ state: 'yanked', yank_reason: 'by hand' }), row({ state: 'tombstoned', tombstone: { reason_code: 'security', date: '2026-10-20' } }), row({ state: 'pending' })]) {
      expect(applyEvent(r, yankEvent)).toBe(r);
    }
  });

  test('an unyank restores a member that carries its mark and no other: not one yanked by hand, one with another yank\'s mark, or one that is published', () => {
    const yanked = applyEvent(row(), yankEvent);
    const restored = applyEvent(yanked, unyankEvent);
    expect(restored).toMatchObject({ state: 'published', rev: 4 });
    expect(restored.yank_reason).toBeUndefined();
    expect(restored.group_yank_seq).toBeUndefined();
    expect(applyEvent(restored, unyankEvent)).toBe(restored);
    const byHand = row({ state: 'yanked', yank_reason: 'by hand' });
    expect(applyEvent(byHand, unyankEvent)).toBe(byHand);
    const other = row({ state: 'yanked', yank_reason: 'x', group_yank_seq: 2 });
    expect(applyEvent(other, unyankEvent)).toBe(other);
    const tombstoned = row({ state: 'tombstoned', tombstone: { reason_code: 'security', date: '2026-10-20' } });
    expect(applyEvent(tombstoned, unyankEvent)).toBe(tombstoned);
  });

  test('a row of another group, or of none, is refused', () => {
    expect(() => applyEvent(row({ group_id: 'grp_ffffffffffffffffffffffffffffffff' }), yankEvent)).toThrow(WrongGroup);
    const single = row();
    delete single.group_id;
    expect(() => applyEvent(single, unyankEvent)).toThrow(WrongGroup);
  });

  test('anything that moves a member on by hand drops the mark: an unyank, a tombstone', () => {
    const yanked = applyEvent(row(), yankEvent);
    const unyanked = applyEvent(yanked, { type: 'unyank' });
    expect(unyanked.state).toBe('published');
    expect(unyanked.group_yank_seq).toBeUndefined();
    const taken = applyEvent(yanked, { type: 'tombstone', reason_code: 'security', date: '2026-10-20' });
    expect(taken.state).toBe('tombstoned');
    expect(taken.group_yank_seq).toBeUndefined();
    expect(taken.yank_reason).toBeUndefined();
  });
});

describe('the hops of a group yank as messages', () => {
  const gid = 'grp_0123456789abcdef0123456789abcdef';
  const hop = (yank: unknown) => ({ group_id: gid, attempt: 1, resend: 2, ...(yank === undefined ? {} : { yank }) });

  test('a repodata hop and an index hop that name a yank are read as sent', () => {
    const y = { op: 'unyank', seq: 4 };
    expect(parseIndexMessage({ type: 'index', subdir: 'noarch', then: { group: hop(y) } })).toEqual({ type: 'index', subdir: 'noarch', then: { group: hop(y) } });
    expect(parseIndexMessage({ type: 'index_pkg', name: 'lib', rev: 0, group: { ...hop(y), position: 1 } })).toEqual({ type: 'index_pkg', name: 'lib', rev: 0, group: { ...hop(y), position: 1 } });
    // A hop of the commit's chain names no yank, and is read as before.
    expect(parseIndexMessage({ type: 'index', subdir: 'noarch', then: { group: hop(undefined) } })).toEqual({ type: 'index', subdir: 'noarch', then: { group: hop(undefined) } });
  });

  test.each([
    ['an operation that is neither', { op: 'pause', seq: 1 }],
    ['a negative number', { op: 'yank', seq: -1 }],
    ['a number that is not whole', { op: 'yank', seq: 1.5 }],
    ['no number', { op: 'yank' }],
    ['a yank that is null', null],
    ['a yank that is a string', 'yank'],
  ])('a hop with %s is refused', (_what, y) => {
    expect(parseIndexMessage({ type: 'index', subdir: 'noarch', then: { group: hop(y) } })).toBeUndefined();
    expect(parseIndexMessage({ type: 'index_pkg', name: 'lib', rev: 0, group: { ...hop(y), position: 1 } })).toBeUndefined();
  });

  test('the queue fake the tests use drops a repeated dedup id (so the tests that count messages count what a FIFO queue keeps)', async () => {
    const q = new MemoryQueue();
    await q.send({ body: 'a', groupId: 'g', dedupId: 'same' });
    await q.send({ body: 'b', groupId: 'g', dedupId: 'same' });
    expect(q.sent).toHaveLength(1);
  });
});
