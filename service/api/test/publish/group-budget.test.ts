import { bitmapIndexes } from '../../src/group-store';
import { groupIdFor } from '../../src/publish/group-service';
import { RIGS, type Rig } from '../group-rig';
import { GroupEnv, json } from './group-env';

/**
 * How long one POST /groups call takes, with a clock that charges every store and S3 call: the preflight (the owner reads of
 * every member and the read of their rows) as much as the reservations. The API Lambda ends a call at its timeout and the gateway
 * then answers a bare HTTP 500, so a call must end soon after its budget whatever the members before it cost.
 *
 * The clock is virtual time with real concurrency: a call sleeps for `CALL_MS`, and the time moves on to the next sleeper only when
 * nothing else can run, so the sixteen members of a batch (which run at once) take as long as one member, and calls one after the
 * other add up. Nothing here asserts wall-clock time.
 */

const N = 170;
const CALL_MS = 20;
/** A little above the preflight of a resumed call (about 0.48 s here: two reads for each of the 170 members, sixteen at a time), so a call has time for a few batches. */
const BUDGET_MS = 560;
/** One batch after the budget has been looked at: a reservation and the checkpoint, with room for a call the store makes twice. */
const MEMBER_MS = 4 * CALL_MS;
/** What the last call of a group adds: the files of every member, read sixteen members at a time (a getUpload and a head each). */
const FILES_MS = Math.ceil(N / 16) * 2 * CALL_MS;

const names = Array.from({ length: N }, (_, i) => `p${String(i).padStart(3, '0')}`);

/** Virtual time: `sleep` is resolved in the order of its due times once every other promise has settled. */
class VirtualTime {
  now = 0;
  private sleepers: Array<{ at: number; wake: () => void }> = [];
  private armed = false;
  constructor(private readonly moved: (now: number) => void) {}
  sleep(ms: number): Promise<void> {
    return new Promise((wake) => {
      this.sleepers.push({ at: this.now + ms, wake });
      this.arm();
    });
  }
  private arm() {
    if (this.armed) return;
    this.armed = true;
    setImmediate(() => {
      this.armed = false;
      if (this.sleepers.length === 0) return;
      const at = Math.min(...this.sleepers.map((s) => s.at));
      this.now = at;
      this.moved(at);
      const due = this.sleepers.filter((s) => s.at <= at);
      this.sleepers = this.sleepers.filter((s) => s.at > at);
      for (const s of due) s.wake();
      if (this.sleepers.length > 0) this.arm();
    });
  }
}

/** Make these methods of `target` take `ms` of virtual time each, and count the calls by method name. */
function charged(target: object, methods: readonly string[], time: VirtualTime, calls: Map<string, number>) {
  const t = target as Record<string, (...a: unknown[]) => Promise<unknown>>;
  for (const m of methods) {
    const orig = t[m]!.bind(target);
    t[m] = async (...a) => {
      calls.set(m, (calls.get(m) ?? 0) + 1);
      await time.sleep(CALL_MS);
      return orig(...a);
    };
  }
}

describe.each(RIGS)('the time of a group create: %s', (_label, make) => {
  let rig: Rig;
  let env: GroupEnv;
  let time: VirtualTime;
  let calls: Map<string, number>;
  let me: string;
  let members: ReturnType<GroupEnv['member']>[];
  let gid: string;

  beforeEach(async () => {
    rig = make();
    env = new GroupEnv(rig, { groupCreateBudgetMs: BUDGET_MS });
    me = await env.account(1, 'octocat', names);
    members = names.map((n) => env.member(n));
    gid = groupIdFor('u:1', env.groups.parse({ members }));
    time = new VirtualTime((now) => (env.mono = now));
    calls = new Map();
    charged(rig.store, ['getPackage', 'listOwners', 'versionsOf', 'getGroup', 'getGroupMembers', 'createGroup', 'updateGroup', 'adoptVersion'], time, calls);
    charged(env.publishes, ['getActorGroups', 'putActorGroups', 'hit', 'versionHolder', 'getUpload', 'putUpload'], time, calls);
    charged(env.objects, ['head'], time, calls);
  });

  /** One call of the create, and the virtual time it took. */
  const round = async () => {
    const from = time.now;
    const r = await env.create(me, members);
    expect([200, 201]).toContain(r.statusCode);
    return { took: time.now - from, body: json(r) as { reserving?: { done: number; total: number }; members: Array<{ name: string; files: unknown[] }> } };
  };
  const reservedCount = async () => bitmapIndexes((await rig.store.getGroup(gid))!.reserved).length;
  /** Rounds with a budget so small that each reserves one batch, until `k` members are reserved (k a multiple of sixteen). */
  const reserveUpTo = async (k: number) => {
    env.config.groupCreateBudgetMs = 1;
    while ((await reservedCount().catch(() => 0)) < k) await round();
    expect(await reservedCount()).toBe(k);
    env.config.groupCreateBudgetMs = BUDGET_MS;
  };

  test('no call lasts longer than the budget plus one batch, the preflight included; only the call that answers every member adds the lookup of their files', async () => {
    const reached: number[] = [];
    for (let i = 0; ; i++) {
      expect(i).toBeLessThan(20);
      const { took, body } = await round();
      if (body.reserving === undefined) {
        expect(took).toBeLessThanOrEqual(BUDGET_MS + MEMBER_MS + FILES_MS);
        expect(body.members).toHaveLength(N);
        expect(body.members.every((m) => m.files.length === 1)).toBe(true);
        break;
      }
      expect(took).toBeLessThanOrEqual(BUDGET_MS + MEMBER_MS);
      reached.push(body.reserving.done);
    }
    // The budget did split the group over several calls (the test would prove nothing if the first call had reserved it all).
    expect(reached.length).toBeGreaterThanOrEqual(2);
    expect(await reservedCount()).toBe(N);
    // Each member was reserved once, and no call before the last asked for the files of any member.
    expect(calls.get('adoptVersion')).toBe(N);
  });

  test('a resumed call whose first members are all reserved already stops within the budget, though it has not got through them yet', async () => {
    await reserveUpTo(96);
    const { took, body } = await round();
    // A few batches fit in what the preflight left of the budget. The 96 reserved members cost the call nothing.
    expect(body.reserving).toBeDefined();
    expect(body.reserving!.done).toBeGreaterThan(96);
    expect(took).toBeLessThanOrEqual(BUDGET_MS + MEMBER_MS);
  });

  test('a call whose preflight has spent the whole budget still reserves one batch, and answers `reserving` after it', async () => {
    await reserveUpTo(96);
    env.config.groupCreateBudgetMs = 1;
    const { body } = await round();
    expect(body.reserving).toEqual({ done: 112, total: N });
    expect(await reservedCount()).toBe(112);
  });

  test('the time of a call that answers `reserving` does not grow with the members that were reserved before it, and it looks at none of their files', async () => {
    await reserveUpTo(32);
    env.config.groupCreateBudgetMs = 1;
    calls.clear();
    const few = await round();
    expect(few.body.reserving).toEqual({ done: 48, total: N });
    await reserveUpTo(144);
    env.config.groupCreateBudgetMs = 1;
    calls.clear();
    const many = await round();
    expect(many.body.reserving).toEqual({ done: 160, total: N });
    // The same members to reserve, the same time (within one member's), though 112 more were reserved already.
    expect(Math.abs(many.took - few.took)).toBeLessThanOrEqual(MEMBER_MS);
    // Their files were not looked at: the call answers `reserving`, and the client reads only the counts.
    expect(calls.get('head') ?? 0).toBe(0);
    expect(calls.get('getUpload') ?? 0).toBe(0);
  });
});
