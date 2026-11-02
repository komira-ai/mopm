import type { HttpResponse } from '../../src/http/router';
import { quarantineKeyFor } from '../../src/publish/group-keys';
import { RIGS, type Rig } from '../group-rig';
import { Chain } from './group-chain-env';
import { errorCode, GroupEnv, json } from './group-env';
import { Scenario } from './group-scenario';
import { sha256 } from './harness';

/**
 * GET /groups/{group_id} shows each member's files (spec/api/openapi.yaml: `Group.members[].files`), on both registry adapters: the
 * facts the caller declared, and `uploaded` while the group is open. Each test says what it proves.
 */

type FileBody = { subdir: string; filename: string; sha256: string; size: number; uploaded?: boolean };
type CreatedBody = { group_id: string; members: Array<{ name: string; files: Array<{ subdir: string; filename: string; upload_id: string }> }> };
const declared = (name: string, uploaded?: boolean): FileBody => ({
  subdir: 'linux-64',
  filename: `mojo-${name}-1.0.0-mojo1.0.0_0.conda`,
  sha256: sha256(`${name}-1.0.0`),
  size: 1000,
  ...(uploaded === undefined ? {} : { uploaded }),
});

describe.each(RIGS)('the files of a group member on GET /groups/{id}: %s', (_label, make) => {
  let rig: Rig;
  let env: GroupEnv;
  beforeEach(() => {
    rig = make();
    env = new GroupEnv(rig);
  });
  const filesOf = (r: HttpResponse) => (json(r).members as Array<{ name: string; files: FileBody[] }>).map((m) => [m.name, m.files] as const);
  /** The keys of the storage stats made from now on. */
  const heads = () => {
    const seen: string[] = [];
    const orig = env.objects.head.bind(env.objects);
    env.objects.head = async (key: string) => {
      seen.push(key);
      return orig(key);
    };
    return seen;
  };
  const keyOf = (created: CreatedBody, name: string) => {
    const f = created.members.find((m) => m.name === name)!.files[0]!;
    return quarantineKeyFor(f.upload_id, f.filename);
  };

  describe('an open group', () => {
    test('shows the declared files of each member in subdir and file name order, and uploaded: false for those not in storage', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      const two = env.member('beta', '1.0.0', {
        files: [
          { subdir: 'osx-arm64', filename: 'mojo-beta-1.0.0-mojo1.0.0_0.conda', sha256: sha256('beta-osx'), size: 2000 },
          { subdir: 'linux-64', filename: 'mojo-beta-1.0.0-mojo1.0.0_0.conda', sha256: sha256('beta-linux'), size: 3000 },
        ],
      });
      const gid = json(await env.create(me, [env.member('alpha'), two])).group_id as string;
      const r = await env.get(me, gid);
      expect(r.statusCode).toBe(200);
      expect(filesOf(r)).toEqual([
        ['alpha', [declared('alpha', false)]],
        [
          'beta',
          [
            { subdir: 'linux-64', filename: 'mojo-beta-1.0.0-mojo1.0.0_0.conda', sha256: sha256('beta-linux'), size: 3000, uploaded: false },
            { subdir: 'osx-arm64', filename: 'mojo-beta-1.0.0-mojo1.0.0_0.conda', sha256: sha256('beta-osx'), size: 2000, uploaded: false },
          ],
        ],
      ]);
      // Nothing but the declared facts and the flag: no upload id, no URL.
      for (const [, fs] of filesOf(r)) for (const f of fs) expect(Object.keys(f).sort()).toEqual(['filename', 'sha256', 'size', 'subdir', 'uploaded']);
    });

    test('uploaded is true only for a file in storage at its declared size; a file of another size is not uploaded', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta', 'gamma']);
      const created = json(await env.create(me, [env.member('alpha'), env.member('beta'), env.member('gamma')])) as CreatedBody;
      await env.objects.put(keyOf(created, 'alpha'), Buffer.alloc(1000), { contentType: 'application/octet-stream' });
      await env.objects.put(keyOf(created, 'beta'), Buffer.alloc(999), { contentType: 'application/octet-stream' });
      expect(filesOf(await env.get(me, created.group_id)).map(([n, fs]) => [n, fs.map((f) => f.uploaded)])).toEqual([
        ['alpha', [true]],
        ['beta', [false]],
        ['gamma', [false]],
      ]);
    });

    test('is a read: one stat for each declared file, no write to the group or its rows', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      const gid = json(await env.create(me, [env.member('alpha'), env.member('beta')])).group_id as string;
      const before = await rig.store.getGroup(gid);
      const rev = (await rig.store.raw.rawGet('alpha', '1.0.0'))!.rev;
      const seen = heads();
      await env.get(me, gid);
      expect(seen).toHaveLength(2);
      expect(await rig.store.getGroup(gid)).toEqual(before);
      expect((await rig.store.raw.rawGet('alpha', '1.0.0'))!.rev).toBe(rev);
    });

    test('members not reserved yet list no files, and the others do', async () => {
      env = new GroupEnv(rig, { groupCreateBudgetMs: 1000 });
      const names = Array.from({ length: 40 }, (_, i) => `p${String(i).padStart(2, '0')}`);
      const me = await env.account(1, 'octocat', names);
      const orig = rig.store.adoptVersion.bind(rig.store);
      rig.store.adoptVersion = async (r, a, free) => {
        env.mono += 100; // each reservation takes 100 ms
        return orig(r, a, free);
      };
      const one = await env.create(
        me,
        names.map((n) => env.member(n)),
      );
      expect(json(one).reserving).toEqual({ done: 16, total: 40 });
      const got = filesOf(await env.get(me, json(one).group_id));
      expect(got.map(([, fs]) => fs.length)).toEqual([...Array(16).fill(1), ...Array(24).fill(0)]);
    });

    test('a member past the member cap lists no files, and no more stats are made than the cap allows', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      const gid = json(await env.create(me, [env.member('alpha'), env.member('beta')])).group_id as string;
      // The cap is lower than when the group was created.
      env.config.groupMaxMembers = 1;
      const seen = heads();
      expect(filesOf(await env.get(me, gid)).map(([n, fs]) => [n, fs.length])).toEqual([
        ['alpha', 1],
        ['beta', 0],
      ]);
      expect(seen).toHaveLength(1);
    });
  });

  describe('a group that is not open', () => {
    test('an aborted group shows the declared facts and no uploaded, and makes no storage stat', async () => {
      const me = await env.account(1, 'octocat', ['alpha']);
      const gid = json(await env.create(me, [env.member('alpha')])).group_id as string;
      expect((await env.abort(me, gid)).statusCode).toBe(200);
      const seen = heads();
      const r = await env.get(me, gid);
      expect(filesOf(r)).toEqual([['alpha', [declared('alpha')]]]);
      expect(seen).toEqual([]);
    });

    test('a group that is validating, committed or visible shows the facts of its files and no uploaded', async () => {
      const s = await new Scenario(env, [{ name: 'alpha' }, { name: 'beta' }]).start();
      const facts = () => s.pkgs.map((p) => [p.name, [{ subdir: p.subdir, filename: p.filename, sha256: p.sha256, size: p.bytes.length }]] as const);
      const seen = heads();
      /** The group as GET shows it; the read made no storage stat. */
      const read = async () => {
        const before = seen.length;
        const r = await env.get(s.token, s.gid);
        expect(seen.length).toBe(before);
        return r;
      };
      expect(json(await read()).status).toBe('validating');
      expect(filesOf(await read())).toEqual(facts());
      expect(await s.runAll()).toEqual(['committed']);
      expect(json(await read()).status).toBe('committed');
      expect(filesOf(await read())).toEqual(facts());
      await new Chain(env).drain();
      expect(json(await read()).status).toBe('visible');
      expect(filesOf(await read())).toEqual(facts());
    });

    test('a member whose number another group took after this one ended lists no files; the others still do', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      const first = json(await env.create(me, [env.member('alpha'), env.member('beta')])).group_id as string;
      expect((await env.abort(me, first)).statusCode).toBe(200);
      // Another set takes alpha's number from the ended group (the row is the new group's now); beta's row is still the first's.
      const second = json(await env.create(me, [env.member('alpha')]));
      expect(second.status).toBe('open');
      expect(filesOf(await env.get(me, first))).toEqual([
        ['alpha', []],
        ['beta', [declared('beta')]],
      ]);
      expect(filesOf(await env.get(me, second.group_id))).toEqual([['alpha', [declared('alpha', false)]]]);
    });
  });

  describe('who may read', () => {
    test('an owner of every package sees what the creator sees; a stranger and an owner of only some get group_not_found, never 403, and no fact', async () => {
      const me = await env.account(1, 'octocat', ['alpha', 'beta']);
      await env.own(2, 'both', ['alpha', 'beta']);
      await env.own(3, 'half', ['alpha']);
      const both = await env.token(2, ['alpha', 'beta']);
      const half = await env.token(3, ['alpha']);
      const stranger = await env.token(4, []);
      const gid = json(await env.create(me, [env.member('alpha'), env.member('beta')])).group_id as string;
      const mine = await env.get(me, gid);
      expect(json(await env.get(both, gid))).toEqual(json(mine));
      for (const t of [half, stranger]) {
        const r = await env.get(t, gid);
        expect(r.statusCode).toBe(404);
        expect(errorCode(r)).toBe('group_not_found');
        expect(r.body).not.toContain(sha256('alpha-1.0.0'));
        expect(r.body).not.toContain('files');
      }
    });
  });
});
