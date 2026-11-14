import { bitmapIndexes } from '../../src/group-store';
import { indexKey } from '../../src/index-files';
import { touchedDirs, nextStep, releaseRepodata, sendStep } from '../../src/publish/group-chain';
import type { GroupRecord } from '../../src/group-store';
import type { GroupMembers } from '../../src/group';
import { RIGS, type Rig } from '../group-rig';
import type { Spec } from '../validate/builder';
import { Chain, label } from './group-chain-env';
import { GroupEnv } from './group-env';
import { Scenario } from './group-scenario';

/**
 * A group whose members live in namespaces (src/publish/group-chain.ts, group-yank.ts): the chain has one repodata hop per
 * repodata directory (`<namespace>/<subdir>`; the root's plain `<subdir>` for flat names), every channel lists only its own
 * members once released, and a group yank rewrites exactly the directories of the yanked members.
 *
 * The group: `ns-one/alpha` (noarch), `ns-one/cargo` (linux-64) and `ns-two/beta` (noarch), all owned by one account. `ns-two/beta` depends on
 * `ns-one/alpha`, so the write order puts a first. Members are listed in name order (ns-one/alpha 0, ns-one/cargo 1, ns-two/beta 2). The chain is
 *   repodata ns-one/linux-64, repodata ns-one/noarch, repodata ns-two/noarch, index alpha, index cargo, index beta, flip.
 */

const SPECS: Array<Partial<Spec>> = [
  { name: 'ns-one/alpha', subdir: 'noarch' },
  { name: 'ns-one/cargo', subdir: 'linux-64' },
  { name: 'ns-two/beta', subdir: 'noarch', index: { depends: ['mojo-compiler ==1.0.0', 'mojo-ns-one.alpha'] }, mopm: { deps: [{ name: 'ns-one/alpha' }] } },
];
const NAMES = ['ns-one/alpha', 'ns-one/cargo', 'ns-two/beta'];
const DIRS = ['ns-one/linux-64', 'ns-one/noarch', 'ns-two/noarch'];

describe.each(RIGS)('a group in namespaces: %s', (_label, make) => {
  let rig: Rig;
  let env: GroupEnv;
  let chain: Chain;
  beforeEach(async () => {
    rig = make();
    env = new GroupEnv(rig, {}, true);
    chain = new Chain(env);
    await env.ownNamespaces(1, 'octocat', ['ns-one', 'ns-two']);
  });

  async function committed(): Promise<Scenario> {
    const s = await new Scenario(env, SPECS, 1, 'v2').start();
    expect(await s.runAll()).toEqual(['committed']);
    return s;
  }
  const header = async (s: Scenario) => (await s.header())!;
  /** The conda names (without `mojo-`) a directory's repodata lists, and those it lists as removed. */
  const doc = (dir: string) => {
    const o = env.objects.objects.get(`${dir}/repodata.json`);
    if (!o) return undefined;
    return JSON.parse(o.body.toString('utf8')) as { 'packages.conda': Record<string, { name: string }>; removed: string[] };
  };
  const listed = (dir: string): string[] => Object.values(doc(dir)?.['packages.conda'] ?? {}).map((p) => p.name).sort();
  const yankPut = (s: Scenario, body: unknown) => env.call('PUT', `/api/v2/groups/${s.gid}/yank`, s.token, body);
  const repodataBytes = (dir: string) => env.objects.objects.get(`${dir}/repodata.json`)?.body.toString('utf8');
  const repodataKeys = () => env.objects.keys().filter((k) => k.endsWith('/repodata.json')).sort();

  test('the chain has one repodata hop per directory, then the index hops, then the flip, and ends visible', async () => {
    const s = await committed();
    const members = (await rig.store.getGroupMembers(s.gid))!;
    expect(touchedDirs(members)).toEqual(DIRS);
    const ran = await chain.drain();
    expect(ran.map(label)).toEqual(['repodata ns-one/linux-64', 'repodata ns-one/noarch', 'repodata ns-two/noarch', 'index ns-one/alpha', 'index ns-one/cargo', 'index ns-two/beta', 'flip']);
    expect((await header(s)).status).toBe('visible');
    expect((await header(s)).repodata_released).toEqual(DIRS);
    expect(nextStep(await header(s), members)).toBeUndefined();
  });

  test('the repodata hop is queued in the FIFO group of its directory', async () => {
    const s = await committed();
    const sent = env.indexQueue.sent.at(-1)!;
    expect(sent.groupId).toBe('ns-one/linux-64');
    const q = { indexQueue: env.indexQueue, groupQueue: env.groupQueue };
    await sendStep(q, s.gid, 1, 0, { kind: 'repodata', subdir: 'ns-two/noarch' });
    const last = env.indexQueue.sent.at(-1)!;
    expect(last.groupId).toBe('ns-two/noarch');
    expect(JSON.parse(last.body)).toMatchObject({ type: 'index', subdir: 'ns-two/noarch' });
  });

  test('each namespace repodata lists only its members, the root lists none, and the index files are at index/v2 keys', async () => {
    await committed();
    await chain.drain();
    expect(listed('ns-one/noarch')).toEqual(['mojo-ns-one.alpha']);
    expect(listed('ns-one/linux-64')).toEqual(['mojo-ns-one.cargo']);
    expect(listed('ns-two/noarch')).toEqual(['mojo-ns-two.beta']);
    expect(listed('noarch')).toEqual([]);
    expect(listed('linux-64')).toEqual([]);
    for (const n of NAMES) {
      expect(indexKey(n)).toMatch(/^index\/v2\//);
      expect(env.objects.objects.has(indexKey(n))).toBe(true);
    }
    // Only the two namespace channels are written: the group put nothing into the root.
    expect(repodataKeys().filter((k) => !k.startsWith('ns-one/') && !k.startsWith('ns-two/'))).toEqual([]);
  });

  test('a build between two hops lists the members of its channel released so far and no others', async () => {
    const s = await committed();
    // The first hop releases ns-one/linux-64 only: ns-one/noarch holds a, but it is not released, so a stray build lists nothing of it.
    await chain.step();
    expect((await header(s)).repodata_released).toEqual(['ns-one/linux-64']);
    await chain.runIndex({ body: JSON.stringify({ type: 'index', subdir: 'ns-one/noarch' }), groupId: 'stray', dedupId: 'stray' });
    expect(listed('ns-one/noarch')).toEqual([]);
    await chain.drain();
    expect(listed('ns-one/noarch')).toEqual(['mojo-ns-one.alpha']);
  });

  test('a repodata hop for a directory the group has no file in is stale: no gate is set and nothing is built', async () => {
    const s = await committed();
    await chain.drain();
    const before = JSON.stringify(await header(s));
    const keys = env.objects.keys().length;
    for (const dir of ['ns-two/linux-64', 'noarch', 'other/noarch']) {
      await chain.runIndex({ body: JSON.stringify({ type: 'index', subdir: dir, then: { group: { group_id: s.gid, attempt: 1, resend: 0 } } }), groupId: dir, dedupId: `x-${dir}` });
    }
    expect(JSON.stringify(await header(s))).toBe(before);
    expect(env.objects.keys().length).toBe(keys);
    expect(repodataKeys()).not.toContain('other/noarch/repodata.json');
  });

  test('a group yank rewrites exactly the namespace directories of the yanked members, and an unyank restores them', async () => {
    const s = await committed();
    await chain.drain();
    expect((await yankPut(s, { yanked: true, reason: 'broken' })).statusCode).toBe(202);
    const ran = (await chain.drain()).map(label);
    expect(ran).toEqual(['rows yank', ...DIRS.map((d) => `repodata ${d}`), 'index ns-one/alpha', 'index ns-one/cargo', 'index ns-two/beta']);
    for (const d of DIRS) expect(listed(d)).toEqual([]);
    expect(doc('ns-one/noarch')!.removed).toHaveLength(1);
    expect(bitmapIndexes((await header(s) as { yank: { yanked_set: string } }).yank.yanked_set)).toEqual([0, 1, 2]);
    expect((await yankPut(s, { yanked: false })).statusCode).toBe(202);
    await chain.drain();
    expect(listed('ns-one/noarch')).toEqual(['mojo-ns-one.alpha']);
    expect(listed('ns-one/linux-64')).toEqual(['mojo-ns-one.cargo']);
    expect(listed('ns-two/noarch')).toEqual(['mojo-ns-two.beta']);
  });

  test('a group yank leaves a member yanked by hand alone and rewrites only the directories of the members it yanked', async () => {
    const s = await committed();
    await chain.drain();
    await rig.store.updateVersion('ns-two/beta', '1.0.0', { type: 'yank', reason: 'by hand' }, { name: 'ns-two/beta', ts: '2026-10-01T00:00:00Z', id: 'by_hand', actor: 'u:1', action: 'yank', version: '1.0.0' });
    const untouched = repodataBytes('ns-two/noarch');
    expect((await yankPut(s, { yanked: true, reason: 'broken' })).statusCode).toBe(202);
    const ran = (await chain.drain()).map(label);
    expect(ran).toEqual(['rows yank', 'repodata ns-one/linux-64', 'repodata ns-one/noarch', 'index ns-one/alpha', 'index ns-one/cargo']);
    expect(repodataBytes('ns-two/noarch')).toBe(untouched);
    expect(listed('ns-one/noarch')).toEqual([]);
  });
});

describe('the repodata directories of a member list', () => {
  const members = (list: Array<[string, string[]]>): GroupMembers => ({ members: list.map(([name, subdirs]) => ({ name, version: '1.0.0', canonical: '1.0.0', subdirs })) });

  test('a flat member holds its plain subdir and a full name its namespace directory, deduplicated and in code-unit order', () => {
    expect(
      touchedDirs(members([['zed', ['noarch']], ['komira-ai/aa', ['noarch', 'linux-64']], ['alice/bb', ['noarch']], ['komira-ai/cc', ['noarch']], ['flat', ['linux-64', 'noarch']]])),
    ).toEqual(['alice/noarch', 'komira-ai/linux-64', 'komira-ai/noarch', 'linux-64', 'noarch']);
  });

  const header = (over: Partial<GroupRecord>): GroupRecord => ({ group_id: 'g', attempt: 1, status: 'committed', committed_at: 't', write_order: [0, 1], ...over }) as GroupRecord;

  test('a header written before namespaces, holding plain subdirs, still releases the flat members it names; the namespace directory is the next hop', () => {
    const m = members([['flat', ['noarch']], ['komira-ai/aa', ['noarch']]]);
    expect(nextStep(header({ repodata_released: ['noarch'] }), m)).toEqual({ kind: 'repodata', subdir: 'komira-ai/noarch' });
    expect(nextStep(header({ repodata_released: ['noarch', 'komira-ai/noarch'] }), m)).toMatchObject({ kind: 'index' });
  });

  test('a hop for the plain subdir of a group with only namespace members is stale', async () => {
    const m = members([['komira-ai/aa', ['noarch']]]);
    const logs: Array<Record<string, unknown>> = [];
    const updated: unknown[] = [];
    const groups = { getGroupMembers: async () => m, updateGroup: async (...a: unknown[]) => void updated.push(a) } as never;
    const d = { groups, now: () => new Date(0), log: (l: Record<string, unknown>) => logs.push(l) };
    expect(await releaseRepodata(d, { group_id: 'g', attempt: 1, resend: 0 }, 'noarch')).toBeUndefined();
    expect(updated).toEqual([]);
    expect(logs).toHaveLength(1);
  });
});
