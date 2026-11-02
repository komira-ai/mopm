import { AuthError } from '../../src/auth/errors';
import type { Principal } from '../../src/auth';
import { headerKey } from '../../src/group';
import { GroupService, groupIdFor } from '../../src/publish/group-service';
import { MemoryObjectStore, MemoryPresigner } from '../../src/publish/memory';
import { PublishService } from '../../src/publish/service';
import { DEFAULT_PUBLISH_CONFIG } from '../../src/publish/config';
import { memoryRig } from '../group-rig';
import { audit, rec } from '../helpers';
import { errorCode, GroupEnv, json } from './group-env';

/**
 * The edges of the group service that the route tests do not reach on their own: a service built with its defaults, a
 * request that is malformed in ways the schema would catch, a list of the actor's groups that is crowded, stale or
 * contended, a store that fails half way, and a caller who is not an account.
 */

const principal = (over: Partial<Principal> = {}): Principal => ({ token_id: 'tok_x', kind: 'api', github_id: 1, scopes: ['publish'], packages: ['alpha'], ...over });

describe('the group service, at its edges', () => {
  let env: GroupEnv;
  beforeEach(() => {
    env = new GroupEnv(memoryRig());
  });
  const store = () => env.rig.store;

  test('built with its defaults (the real clock and time, metric lines on the console) it creates a group', async () => {
    await env.account(1, 'octocat', ['alpha']);
    const log = jest.spyOn(console, 'log').mockImplementation(() => undefined);
    // The default clock reads `new Date()`; the system time is pinned (only Date is faked) so the deadline is an exact sum, not a comparison with the real now.
    const pinned = new Date('2026-03-04T05:06:07.000Z');
    jest.useFakeTimers({
      now: pinned,
      doNotFake: ['hrtime', 'nextTick', 'performance', 'queueMicrotask', 'requestAnimationFrame', 'cancelAnimationFrame', 'requestIdleCallback', 'cancelIdleCallback', 'setImmediate', 'clearImmediate', 'setInterval', 'clearInterval', 'setTimeout', 'clearTimeout'],
    });
    try {
      const svc = new GroupService({ registry: store(), publishes: env.publishes, objects: env.objects, presigner: new MemoryPresigner(), config: DEFAULT_PUBLISH_CONFIG });
      const out = await svc.create(principal(), svc.parse({ members: [env.member('alpha')] }));
      expect(out.created).toBe(true);
      expect(out.body.status).toBe('open');
      expect(out.body.deadline_at).toBe(new Date(pinned.getTime() + DEFAULT_PUBLISH_CONFIG.groupDeadlineHours * 3_600_000).toISOString());
      expect(log).toHaveBeenCalled(); // the pending-rows metric line
    } finally {
      jest.useRealTimers();
      log.mockRestore();
    }
  });

  test('a member that is not an object, or has a name or version that is not a string, is invalid_request', () => {
    for (const members of [[1], [null], [{ name: 3, version: '1.0.0', files: [] }], [{ name: 'alpha', version: 1, files: [] }], [{ name: 'alpha', version: '1.0.0' }], 'alpha']) {
      expect(() => env.groups.parse({ members })).toThrow(/not valid/);
    }
    expect(() => env.groups.parse([])).toThrow(/not a JSON object/);
  });

  test('a token with no account behind it is refused by the service itself, naming the first package', async () => {
    await env.own(1, 'octocat', ['alpha']);
    const req = env.groups.parse({ members: [env.member('alpha')] });
    await expect(env.groups.create(principal({ github_id: undefined, kind: 'oidc' }), req)).rejects.toBeInstanceOf(AuthError);
  });

  test('a group that is on the list but has no header yet counts as open for two minutes (a create still writing it), and not after', async () => {
    env = new GroupEnv(memoryRig(), { groupOpenPerActor: 1 });
    const me = await env.account(1, 'octocat', ['alpha', 'beta']);
    const ghost = 'grp_' + 'f'.repeat(32);
    await env.publishes.putActorGroups('u:1', [{ id: ghost, at: env.clock.now().toISOString() }], undefined);
    expect(errorCode(await env.create(me, [env.member('alpha')]))).toBe('group_conflict');

    env.clock.advance(121_000);
    expect((await env.create(me, [env.member('beta')])).statusCode).toBe(201);
    // The stale entry was dropped when the list was written back.
    expect((await env.publishes.getActorGroups('u:1'))!.groups.map((g) => g.id)).not.toContain(ghost);
  });

  test('a list that keeps changing under a create is given up on after a few tries: unavailable, nothing created', async () => {
    const me = await env.account(1, 'octocat', ['alpha']);
    const spy = jest.spyOn(env.publishes, 'putActorGroups').mockResolvedValue(false);
    const r = await env.create(me, [env.member('alpha')]);
    expect(r.statusCode).toBe(503);
    expect(errorCode(r)).toBe('unavailable');
    expect(spy).toHaveBeenCalledTimes(5);
    expect(await store().raw.rawGet('alpha', '1.0.0')).toBeUndefined();
  });

  test('a create that fails gives its place back; a failure to give it back does not hide the first error', async () => {
    const me = await env.account(1, 'octocat', ['alpha', 'beta']);
    await store().createVersion(rec({ name: 'alpha', version: '1.0.0' }), audit('alpha', 'seed', '1.0.0'));
    expect(errorCode(await env.create(me, [env.member('alpha')]))).toBe('version_exists');
    expect((await env.publishes.getActorGroups('u:1'))!.groups).toEqual([]);

    const real = env.publishes.getActorGroups.bind(env.publishes);
    let calls = 0;
    jest.spyOn(env.publishes, 'getActorGroups').mockImplementation(async (a) => {
      if (++calls > 1) throw new Error('the list cannot be read');
      return real(a);
    });
    const again = await env.create(me, [env.member('alpha'), env.member('beta')]);
    expect(errorCode(again)).toBe('version_exists');
  });

  test('a store that throws while the group reserves its rows surfaces the error and leaves the group open, with the members reserved so far checkpointed', async () => {
    const me = await env.account(1, 'octocat', ['alpha', 'beta']);
    const orig = store().adoptVersion.bind(store());
    store().adoptVersion = async (r, a, f) => {
      if (r.name === 'beta') throw new Error('the table is gone');
      return orig(r, a, f);
    };
    const spy = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    try {
      expect((await env.create(me, [env.member('alpha'), env.member('beta')])).statusCode).toBe(500);
    } finally {
      spy.mockRestore();
    }
    const header = (await store().getGroup(groupIdFor('u:1', env.groups.parse({ members: [env.member('alpha'), env.member('beta')] }))))!;
    expect(header.status).toBe('open');
    expect(header.reserved).toBe('1');
  });

  test('two identical creates at once make one group, and the upload record both write is the same', async () => {
    const me = await env.account(1, 'octocat', ['alpha']);
    const [a, b] = await Promise.all([env.create(me, [env.member('alpha')]), env.create(me, [env.member('alpha')])]);
    expect([a.statusCode, b.statusCode].every((s) => s === 200 || s === 201)).toBe(true);
    expect(json(a).group_id).toBe(json(b).group_id);
    expect(env.publishes.uploads.size).toBe(1);
  });

  test('an upload record written by a request that ran at the same time is read back; one that cannot be written or read is an error', async () => {
    const me = await env.account(1, 'octocat', ['alpha', 'beta']);
    const put = env.publishes.putUpload.bind(env.publishes);
    jest.spyOn(env.publishes, 'putUpload').mockImplementation(async (u) => {
      await put(u);
      throw new Error('already exists');
    });
    expect((await env.create(me, [env.member('alpha')])).statusCode).toBe(201);
    jest.spyOn(env.publishes, 'putUpload').mockImplementation(async () => {
      throw new Error('the table is gone');
    });
    const spy = jest.spyOn(console, 'error').mockImplementation(() => undefined);
    try {
      expect((await env.create(me, [env.member('beta')])).statusCode).toBe(500);
    } finally {
      spy.mockRestore();
    }
  });

  test('a header with no member list is shown with no members, to its creator only; an account with no id sees nothing of it', async () => {
    const me = await env.account(1, 'octocat', ['alpha']);
    const gid = 'grp_' + 'e'.repeat(32);
    env.rig.putGroupItem(headerKey(gid), {
      group_id: gid,
      status: 'open',
      attempt: 1,
      rev: 0,
      actor: 'u:1',
      member_count: 1,
      created_at: env.clock.now().toISOString(),
      deadline_at: new Date(env.clock.t + 3_600_000).toISOString(),
      progress_at: env.clock.now().toISOString(),
      reserved: '',
      validated: '',
      staged: '',
      copied: '',
      flipped: '',
      resend: 0,
    });
    expect(json(await env.get(me, gid)).members).toEqual([]);
    const other = await env.token(2, []);
    expect(errorCode(await env.get(other, gid))).toBe('group_not_found');
    const ci = await env.ciToken('alpha', '1.0.0');
    expect(errorCode(await env.get(ci, gid))).toBe('group_not_found');
  });

  test('a committed group is shown with its commit time', async () => {
    const me = await env.account(1, 'octocat', ['alpha']);
    const gid = json(await env.create(me, [env.member('alpha')])).group_id as string;
    await store().updateGroup(gid, (c) => ({ ...c, status: 'validating' }));
    const h = (await store().getGroup(gid))!;
    const at = env.clock.now().toISOString();
    await store().commitGroup(gid, { rev: h.rev, writeOrder: [0], now: at, audit: { name: 'grp#' + gid, ts: at, id: 'c', actor: 'u:1', action: 'group_commit' } });
    expect(json(await env.get(me, gid))).toMatchObject({ status: 'committed', committed_at: at });
  });

  test('an abort whose header vanishes under it is group_not_open, not a crash', async () => {
    const me = await env.account(1, 'octocat', ['alpha']);
    const gid = json(await env.create(me, [env.member('alpha')])).group_id as string;
    jest.spyOn(store(), 'updateGroup').mockResolvedValue(undefined);
    const r = await env.abort(me, gid);
    expect(r.statusCode).toBe(409);
    expect(errorCode(r)).toBe('group_not_open');
  });

  test('a single publish with no group store never takes a group\'s number, dead or not', async () => {
    const me = await env.account(1, 'octocat', ['alpha']);
    const gid = json(await env.create(me, [env.member('alpha')])).group_id as string;
    await env.abort(me, gid);
    const single = new PublishService({
      registry: store(),
      publishes: env.publishes,
      objects: new MemoryObjectStore(),
      presigner: new MemoryPresigner(),
      validateQueue: { send: async () => undefined },
      config: env.config,
      now: env.clock.now,
    });
    const body = { subdir: 'linux-64', filename: 'mojo-alpha-1.0.0-mojo1.0.0_0.conda', sha256: 'c'.repeat(64), size: 5 };
    await expect(single.begin(principal(), 'alpha', '1.0.0', body)).rejects.toMatchObject({ code: 'version_exists' });
  });
});
