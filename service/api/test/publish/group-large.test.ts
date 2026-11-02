import { bitmapIndexes } from '../../src/group-store';
import { indexKey } from '../../src/index-files';
import { groupIdFor } from '../../src/publish/group-service';
import { RIGS, type Rig } from '../group-rig';
import { Chain, label } from './group-chain-env';
import { GroupEnv, json } from './group-env';
import { Scenario } from './group-scenario';

/**
 * Groups far above the handful of members the other group tests use, on both registry adapters: 170 members (ten full batches of
 * sixteen and a short one, and a bitmap whose last character holds two members) and 300 (eighteen full batches and a short one, and
 * a bitmap of whole characters). Each test names the limit of the code it crosses: the batches of sixteen when members are
 * reserved and flipped, the eight members the validator saves at a time, the four members a character of a bitmap holds, the
 * validator's time budget, and the order the chain writes a deep chain of dependencies in.
 */

const SIZES = [170, 300];
const SLOW = 180_000;
const names = (n: number) => Array.from({ length: n }, (_, i) => `p${String(i).padStart(3, '0')}`);
const upTo = (n: number) => Array.from({ length: n }, (_, i) => i);
/** The bitmap with members 0..n-1 set: four members to a hex character, the last character holding what is left. */
const allSet = (n: number) => 'f'.repeat(Math.floor(n / 4)) + ['', '1', '3', '7'][n % 4]!;
/** The counts a bitmap passes through when `k` members are added at a time, `n` members in all. */
const stepsOf = (n: number, k: number) => Array.from({ length: Math.ceil(n / k) }, (_, j) => Math.min(k * (j + 1), n));
const count = (bitmap: string) => bitmapIndexes(bitmap).length;
const later = () => new Promise<void>((r) => setImmediate(r));

describe.each(RIGS)('large groups: %s', (_label, make) => {
  let rig: Rig;
  let env: GroupEnv;
  beforeEach(() => {
    rig = make();
    env = new GroupEnv(rig);
  });

  describe.each(SIZES)('%i members', (n) => {
    const ns = names(n);

    describe('create', () => {
      test(
        'reserves the members sixteen at a time, with a checkpoint after each batch and never more than sixteen rows in flight, and answers every member',
        async () => {
          const me = await env.account(1, 'octocat', ns);
          let inflight = 0;
          let peak = 0;
          let adopted = 0;
          const adopt = rig.store.adoptVersion.bind(rig.store);
          rig.store.adoptVersion = async (r, a, free) => {
            adopted++;
            inflight++;
            peak = Math.max(peak, inflight);
            try {
              await later(); // every member of the batch is in flight before any is done
              return await adopt(r, a, free);
            } finally {
              inflight--;
            }
          };
          const checkpoints: number[] = [];
          const update = rig.store.updateGroup.bind(rig.store);
          rig.store.updateGroup = async (gid, fn, a) => {
            const after = await update(gid, fn, a);
            if (after && count(after.reserved) !== (checkpoints.at(-1) ?? 0)) checkpoints.push(count(after.reserved));
            return after;
          };

          const r = await env.create(
            me,
            ns.map((x) => env.member(x)),
          );
          expect(r.statusCode).toBe(201);
          const body = json(r);
          expect(body.reserving).toBeUndefined();
          expect(body.members.map((m: { name: string }) => m.name)).toEqual(ns);
          expect(body.members.every((m: { action: string; files: Array<{ put_url: string }> }) => m.action === 'new' && m.files.length === 1 && m.files[0]!.put_url.length > 0)).toBe(true);
          expect(adopted).toBe(n);
          expect(peak).toBe(16);
          expect(checkpoints).toEqual(stepsOf(n, 16));

          const h = (await rig.store.getGroup(body.group_id))!;
          expect(h).toMatchObject({ status: 'open', member_count: n, reserved: allSet(n) });
          expect(h.reserved).toHaveLength(Math.ceil(n / 4));
          expect((await rig.store.getGroupMembers(body.group_id))!.members.map((m) => m.name)).toEqual(ns);
          for (const x of ns) expect(await rig.store.raw.rawGet(x, '1.0.0')).toMatchObject({ state: 'pending', group_id: body.group_id, rev: 0 });
          // One charge for the whole group, on the token's counter and the account's.
          expect([...env.publishes.counters.values()]).toEqual([n, n]);

          // The identical request is the same group and reserves nothing again.
          const again = await env.create(
            me,
            ns.map((x) => env.member(x)),
          );
          expect(again.statusCode).toBe(200);
          expect(json(again).group_id).toBe(body.group_id);
          expect(json(again).members.every((m: { action: string }) => m.action === 'join')).toBe(true);
          expect(adopted).toBe(n);
          expect(checkpoints).toEqual(stepsOf(n, 16));
          expect([...env.publishes.counters.values()]).toEqual([n, n]);
        },
        SLOW,
      );

      test(
        'a create that runs out of time answers the members it reached, and the identical request goes on from the checkpoint until every member is reserved once',
        async () => {
          env = new GroupEnv(rig, { groupCreateBudgetMs: 5000 });
          const me = await env.account(1, 'octocat', ns);
          const members = ns.map((x) => env.member(x));
          const gid = groupIdFor('u:1', env.groups.parse({ members }));
          let adopted = 0;
          const adopt = rig.store.adoptVersion.bind(rig.store);
          rig.store.adoptVersion = async (r, a, free) => {
            adopted++;
            env.mono += 100; // each reservation takes 100 ms: a batch of sixteen takes 1.6 s, and a call stops after the batch that reaches 5 s
            return adopt(r, a, free);
          };

          const reached: number[] = [];
          let calls = 0;
          for (;;) {
            const r = await env.create(me, members);
            expect(r.statusCode).toBe(calls === 0 ? 201 : 200);
            calls++;
            const reserving = json(r).reserving as { done: number; total: number } | undefined;
            if (!reserving) {
              expect(json(r).members.map((m: { name: string }) => m.name)).toEqual(ns);
              break;
            }
            reached.push(reserving.done);
            expect(reserving.total).toBe(n);
            expect(json(r).members).toHaveLength(reserving.done);
            expect(bitmapIndexes((await rig.store.getGroup(gid))!.reserved)).toEqual(upTo(reserving.done));
            expect(calls).toBeLessThan(20);
          }
          // Four batches of sixteen in a call.
          expect(reached).toEqual(Array.from({ length: Math.ceil(n / 64) - 1 }, (_, j) => 64 * (j + 1)));
          expect(adopted).toBe(n);
          expect((await rig.store.getGroup(gid))!.reserved).toBe(allSet(n));
          expect([...env.publishes.counters.values()]).toEqual([n, n]);
          for (const x of ns) expect(await rig.store.raw.rawGet(x, '1.0.0')).toMatchObject({ group_id: gid, rev: 0 });
        },
        SLOW,
      );

      test(
        'the status of a half-reserved group tells the reserved members from the pending ones',
        async () => {
          env = new GroupEnv(rig, { groupCreateBudgetMs: 5000 });
          const me = await env.account(1, 'octocat', ns);
          const orig = rig.store.adoptVersion.bind(rig.store);
          rig.store.adoptVersion = async (r, a, free) => {
            env.mono += 100;
            return orig(r, a, free);
          };
          const first = await env.create(
            me,
            ns.map((x) => env.member(x)),
          );
          expect(json(first).reserving).toEqual({ done: 64, total: n });
          const status = json(await env.get(me, json(first).group_id));
          expect(status.members.map((m: { state: string }) => m.state)).toEqual([...Array(64).fill('reserved'), ...Array(n - 64).fill('pending')]);
        },
        SLOW,
      );
    });

    describe('the validator', () => {
      test(
        'validates, stages and copies the members, saving eight at a time into bitmaps of four members to a character, and commits',
        async () => {
          const s = await new Scenario(
            env,
            ns.map((name) => ({ name })),
          ).start();
          const validated: number[] = [];
          const copied: number[] = [];
          const update = rig.store.updateGroup.bind(rig.store);
          rig.store.updateGroup = async (gid, fn, a) => {
            const after = await update(gid, fn, a);
            if (after) {
              if (count(after.validated) !== (validated.at(-1) ?? 0)) validated.push(count(after.validated));
              if (count(after.copied) !== (copied.at(-1) ?? 0)) copied.push(count(after.copied));
            }
            return after;
          };

          expect(await s.runAll()).toEqual(['committed']);
          expect(validated).toEqual(stepsOf(n, 8));
          expect(copied).toEqual(stepsOf(n, 8));
          const h = (await s.header())!;
          expect(h).toMatchObject({ status: 'committed', phase: 3, validated: allSet(n), staged: allSet(n), copied: allSet(n), write_order: upTo(n) });
          expect(h.validated).toHaveLength(Math.ceil(n / 4));
          expect(env.objects.log.filter((l) => l.startsWith('put ') && !l.startsWith('put quarantine/'))).toHaveLength(n);
          expect(s.channelFiles()).toHaveLength(n);
          expect(env.objects.keys('quarantine/')).toEqual([]);
          for (const x of ns) expect(await s.row(x)).toMatchObject({ state: 'pending', group_id: s.gid, staged_attempt: 1 });
        },
        SLOW,
      );

      test(
        'a job that runs out of time saves what it did and queues the rest, across both phases, and the group finishes with every member done once',
        async () => {
          const slow = new GroupEnv(make(), { groupBudgetMs: 1000 });
          const s = await new Scenario(
            slow,
            ns.map((name) => ({ name })),
          ).start();
          const sent: Array<{ dedupId: string; body: string }> = [];
          const send = slow.groupQueue.send.bind(slow.groupQueue);
          slow.groupQueue.send = async (m) => {
            sent.push({ dedupId: m.dedupId, body: m.body });
            return send(m);
          };
          // The clock moves 100 ms each time it is read, so a job starts ten members before its second is spent.
          let t = 0;
          const over = { clock: () => (t += 100) };

          const jobs = (2 * n) / 10;
          for (let j = 1; j <= jobs; j++) {
            const outcome = await slow.runGroupJob(over);
            const h = (await s.header())!;
            const started = 10 * j;
            expect(outcome).toBe(j < jobs ? 'requeued' : 'committed');
            expect(count(h.validated)).toBe(Math.min(started, n));
            expect(count(h.copied)).toBe(Math.max(0, started - n));
            // Nothing is in the channel that the header does not say is copied.
            expect(s.channelFiles()).toHaveLength(count(h.copied));
          }
          expect(slow.groupQueue.sent).toHaveLength(0);
          expect(sent).toHaveLength(jobs - 1);
          expect(new Set(sent.map((m) => m.dedupId)).size).toBe(jobs - 1);
          expect(sent.map((m) => JSON.parse(m.body).n)).toEqual(Array.from({ length: jobs - 1 }, (_, j) => j + 1));
          const h = (await s.header())!;
          expect(h).toMatchObject({ status: 'committed', validated: allSet(n), staged: allSet(n), copied: allSet(n), write_order: upTo(n) });
        },
        SLOW,
      );
    });

    describe('the chain', () => {
      /** Each package depends on the next one by name: the write order is the names backwards, n packages deep. */
      const specs = ns.map((name, i) => (i < n - 1 ? { name, index: { depends: ['mojo-compiler ==1.0.0', `mojo-${ns[i + 1]!}`] }, mopm: { deps: [{ name: ns[i + 1]! }] } } : { name }));

      async function committed(): Promise<Scenario> {
        const s = await new Scenario(env, specs).start();
        expect(await s.runAll()).toEqual(['committed']);
        expect((await s.header())!.write_order).toEqual(upTo(n).reverse());
        return s;
      }

      test(
        'writes the index files from the deepest dependency up, then flips the members sixteen at a time, the group staying committed until the last batch is saved',
        async () => {
          const s = await committed();
          const chain = new Chain(env);
          const flips: number[] = [];
          const update = rig.store.updateGroup.bind(rig.store);
          rig.store.updateGroup = async (gid, fn, a) => {
            const after = await update(gid, fn, a);
            if (after && count(after.flipped) !== (flips.at(-1) ?? 0)) {
              flips.push(count(after.flipped));
              if (count(after.flipped) < n) {
                expect(after.status).toBe('committed');
                expect(after.sweep_pk).toBe('active');
                let published = 0;
                for (const x of ns) if ((await rig.store.raw.rawGet(x, '1.0.0'))!.state === 'published') published++;
                expect(published).toBe(count(after.flipped));
              }
            }
            return after;
          };

          const ran = await chain.drain((r) => {
            const l = label(r);
            if (!l.startsWith('index ')) return;
            // The packages with a file are exactly the one just written and everything it depends on.
            const at = ns.indexOf(l.slice('index '.length));
            expect(ns.filter((x) => env.objects.objects.has(indexKey(x)))).toEqual(ns.slice(at));
          }, n + 10);
          expect(ran.map(label)).toEqual(['repodata noarch', ...[...ns].reverse().map((x) => `index ${x}`), 'flip']);
          expect(flips).toEqual(stepsOf(n, 16));

          const h = (await s.header())!;
          expect(h).toMatchObject({ status: 'visible', flipped: allSet(n), repodata_released: ['noarch'], index_released: upTo(n) });
          expect(h.sweep_pk).toBeUndefined();
          for (const x of ns) {
            expect((await rig.store.raw.rawGet(x, '1.0.0'))!.state).toBe('published');
            expect((await rig.store.listAudit(x)).filter((a) => a.action === 'group_flip')).toHaveLength(1);
          }
          expect((await rig.store.listAudit(`grp#${s.gid}`)).filter((a) => a.action === 'group_visible')).toHaveLength(1);
        },
        SLOW,
      );

      test(
        'a flip that died in its third batch goes on from the two batches it saved: the other members are flipped once and the group becomes visible',
        async () => {
          const s = await committed();
          const chain = new Chain(env);
          while (env.indexQueue.sent.length > 0) await chain.step();
          const flip = env.groupQueue.take()!;

          let events = 0;
          let failAt = 40;
          const apply = rig.store.applyGroupEvent.bind(rig.store);
          rig.store.applyGroupEvent = async (name, version, ev, a) => {
            if (ev.type === 'group_publish') {
              events++;
              if (events === failAt) throw new Error('the flip died');
            }
            return apply(name, version, ev, a);
          };
          await expect(chain.runFlip(flip)).rejects.toThrow('the flip died');
          await later();
          const stopped = (await s.header())!;
          expect(stopped.status).toBe('committed');
          expect(bitmapIndexes(stopped.flipped)).toEqual(upTo(32));

          events = 0;
          failAt = 0;
          expect(await chain.runFlip(flip)).toMatchObject({ outcome: 'visible' });
          expect(events).toBe(n - 32); // the thirty-two saved members are not touched again
          const h = (await s.header())!;
          expect(h).toMatchObject({ status: 'visible', flipped: allSet(n) });
          for (const x of ns) {
            expect((await rig.store.raw.rawGet(x, '1.0.0'))!.state).toBe('published');
            expect((await rig.store.listAudit(x)).filter((a) => a.action === 'group_flip')).toHaveLength(1);
          }
        },
        SLOW,
      );
    });
  });
});
