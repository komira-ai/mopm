import { bitmapIndexes } from '../../src/group-store';
import { quarantineKeyFor } from '../../src/publish/group-keys';
import { groupIdFor } from '../../src/publish/group-service';
import { README_MAX_BYTES } from '../../src/types';
import { RIGS } from '../group-rig';
import { GroupEnv, json } from './group-env';
import { refOf, sha } from './group-readme-scenario';
import { CALL_MS, charged, VirtualTime } from './virtual-time';

/**
 * The largest group (`groupMaxMembers`, 500) with a readme of the largest size (64 KiB) for every member, over a registry whose
 * store and storage calls are charged against the injected clock of the create budget. Nothing here asserts wall-clock time.
 */

const N = 500;
const BUDGET_MS = 1500;
/** One batch after the budget has been looked at: a reservation and the checkpoint, with room for a call the store makes twice. */
const MEMBER_MS = 4 * CALL_MS;
/** What the last call adds: for each batch of sixteen members, the files (a getUpload, a putUpload and a head each) and the head of each readme. */
const ANSWER_MS = Math.ceil(N / 16) * 4 * CALL_MS;
/** What the registry's function takes of a request, less 64 KiB. */
const COMMIT_LIMIT = 6 * 1024 * 1024 - 64 * 1024;

const names = Array.from({ length: N }, (_, i) => `p${String(i).padStart(3, '0')}`);
const readmeOf = (name: string) => Buffer.from(`# ${name}\n`.padEnd(README_MAX_BYTES - 1, 'x') + '\n', 'utf8');

describe.each(RIGS)('the maximum group with maximum readmes: %s', (_label, make) => {
  test(
    'every create call ends within the budget plus one batch; only the last carries the upload descriptors of all 500 readmes; the commit that names them is small and is taken',
    async () => {
      const rig = make();
      const env = new GroupEnv(rig, { groupCreateBudgetMs: BUDGET_MS });
      expect(env.config.groupMaxMembers).toBe(N);
      const me = await env.account(1, 'octocat', names);
      const readmes = new Map(names.map((n) => [n, readmeOf(n)]));
      for (const b of readmes.values()) expect(b.length).toBe(README_MAX_BYTES);
      const members = names.map((n) => ({ ...env.member(n), readme: refOf(readmes.get(n)!) }));
      const gid = groupIdFor('u:1', env.groups.parse({ members }));
      const time = new VirtualTime((now) => (env.mono = now));
      const calls = new Map<string, number>();
      charged(rig.store, ['getPackage', 'listOwners', 'versionsOf', 'getGroup', 'getGroupMembers', 'createGroup', 'updateGroup', 'adoptVersion'], time, calls);
      charged(env.publishes, ['getActorGroups', 'putActorGroups', 'hit', 'versionHolder', 'getUpload', 'putUpload'], time, calls);
      charged(env.objects, ['head'], time, calls);

      let last: { reserving?: { done: number; total: number }; members: Array<{ name: string; files: unknown[]; readme?: Record<string, unknown> }> } | undefined;
      let rounds = 0;
      for (;;) {
        expect(++rounds).toBeLessThan(40);
        const from = time.now;
        const r = await env.create(me, members);
        expect([200, 201]).toContain(r.statusCode);
        const took = time.now - from;
        last = json(r);
        if (last!.reserving === undefined) {
          expect(took).toBeLessThanOrEqual(BUDGET_MS + MEMBER_MS + ANSWER_MS);
          break;
        }
        expect(took).toBeLessThanOrEqual(BUDGET_MS + MEMBER_MS);
        // An answer that is still reserving looks at no object and describes no upload.
        expect(last!.members.every((m) => m.readme === undefined && m.files.length === 0)).toBe(true);
        expect(calls.get('head') ?? 0).toBe(0);
      }
      expect(rounds).toBeGreaterThanOrEqual(2); // the budget did split the group over several calls
      expect(bitmapIndexes((await rig.store.getGroup(gid))!.reserved)).toHaveLength(N);

      // The last answer has every member's readme descriptor, pinned to the declared digest and size.
      expect(last!.members).toHaveLength(N);
      for (const m of last!.members) {
        const ref = refOf(readmes.get(m.name)!);
        expect(m.readme).toMatchObject({ ...ref, uploaded: false });
        expect(m.readme!.put_headers).toEqual({ 'content-length': String(README_MAX_BYTES), 'x-amz-checksum-sha256': Buffer.from(ref.sha256, 'hex').toString('base64') });
      }
      expect(new Set(last!.members.map((m) => m.readme!.upload_id)).size).toBe(N);
      // Each member's file and readme were looked at once, in the last call only.
      expect(calls.get('head')).toBe(2 * N);

      // Upload the files and the readmes where the answer says, and commit with references: 32 MiB of readmes in a body of references.
      for (const m of last!.members) {
        const file = m.files[0] as { upload_id: string; filename: string };
        await env.objects.put(quarantineKeyFor(file.upload_id, file.filename), Buffer.alloc(1000), { contentType: 'application/octet-stream' });
      }
      for (const m of last!.members) await env.objects.put(quarantineKeyFor(m.readme!.upload_id as string, 'README.md'), readmes.get(m.name)!, { contentType: 'application/octet-stream' });
      const body = JSON.stringify({ members: names.map((n) => ({ name: n, manifest_sha256: sha(`manifest ${n}`), readme: refOf(readmes.get(n)!) })) });
      const total = [...readmes.values()].reduce((a, b) => a + b.length, 0);
      expect(total).toBeGreaterThan(30 * 1024 * 1024);
      expect(Buffer.byteLength(body)).toBeLessThan(COMMIT_LIMIT / 10);
      const r = await env.call('POST', `/api/v1/groups/${gid}/commit`, me, body);
      expect(r.statusCode).toBe(202);
      expect(await rig.store.getCommitInput(gid, (await rig.store.getGroup(gid))!.commit_hash!, N - 1)).toMatchObject({ name: names[N - 1], display: { readme: readmes.get(names[N - 1]!)!.toString('utf8') } });
    },
    240_000,
  );
});
