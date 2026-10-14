import { GetCommand } from '@aws-sdk/lib-dynamodb';
import { DynamoStore, tablesFor } from '../src/dynamo-store';
import { MemoryStore } from '../src/memory-store';
import type { Store } from '../src/store';
import { FakeDocClient, NaiveCreate, audit, rec } from './helpers';

const factories: [string, () => Store][] = [
  ['memory', () => new MemoryStore()],
  ['dynamodb (fake client)', () => new DynamoStore(new FakeDocClient(), tablesFor('t'))],
];

describe.each(factories)('Store contract: %s', (_label, make) => {
  let s: Store;
  beforeEach(() => {
    s = make();
  });

  test('create then get by any equivalent spelling', async () => {
    await s.createVersion(rec({ name: 'p', version: '1.0' }), audit('p', 'publish', '1.0'));
    for (const v of ['1.0', '1.0.0', '1']) {
      const got = await s.getVersion('p', v);
      expect(got?.version).toBe('1.0'); // the spelling that was published
      expect(got?.canonical).toBe('1');
    }
    expect(await s.getVersion('p', '1.0.1')).toBeUndefined();
    expect(await s.getVersion('q', '1.0')).toBeUndefined();
  });

  test('an equivalent version is refused with version_exists, naming the sha256', async () => {
    await s.createVersion(rec({ name: 'p', version: '1.0' }), audit('p', 'publish'));
    await expect(s.createVersion(rec({ name: 'p', version: '1.0.0' }), audit('p', 'publish'))).rejects.toMatchObject({
      code: 'version_exists',
      status: 409,
      detail: { name: 'p', version: '1.0.0', sha256: 'a'.repeat(64) },
    });
    // The failed create left no audit row behind (the write is all or nothing).
    expect(await s.listAudit('p')).toHaveLength(1);
    expect(await s.listVersions('p')).toHaveLength(1);
  });

  test('the same version of another package is independent', async () => {
    await s.createVersion(rec({ name: 'p', version: '1.0' }), audit('p', 'publish'));
    await s.createVersion(rec({ name: 'q', version: '1.0' }), audit('q', 'publish'));
    expect((await s.listVersions('q')).length).toBe(1);
  });

  test('invalid versions are refused before anything is written', async () => {
    await expect(s.createVersion(rec({ name: 'p', version: 'v1' }), audit('p', 'publish'))).rejects.toMatchObject({ code: 'invalid_version' });
    expect(await s.listVersions('p')).toEqual([]);
    expect(await s.listAudit('p')).toEqual([]);
  });

  test('a tombstoned number is never reusable, not even with different bytes', async () => {
    await s.createVersion(rec({ name: 'p', version: '2.0' }), audit('p', 'publish'));
    await s.updateVersion('p', '2.0', { type: 'tombstone', reason_code: 'malware', date: '2026-10-12' }, audit('p', 'takedown'));
    const other = { subdir: 'linux-64', filename: 'mojo-p-2.0.0-mojo1.0.0_0.conda', sha256: 'e'.repeat(64), size: 5 };
    await expect(s.createVersion(rec({ name: 'p', version: '2.0.0', files: [other] }), audit('p', 'publish'))).rejects.toMatchObject({
      code: 'version_exists',
    });
  });

  test('lifecycle: pending -> published -> yanked -> published, one audit row per change', async () => {
    await s.createVersion(rec({ name: 'p', version: '1.0', state: 'pending' }), audit('p', 'upload'));
    expect((await s.updateVersion('p', '1.0.0', { type: 'publish' }, audit('p', 'publish'))).state).toBe('published');
    const y = await s.updateVersion('p', '1', { type: 'yank', reason: 'broken' }, audit('p', 'yank'));
    expect([y.state, y.yank_reason, y.rev]).toEqual(['yanked', 'broken', 2]);
    // Idempotent: no change, so no audit row.
    await s.updateVersion('p', '1.0', { type: 'yank', reason: 'other' }, audit('p', 'yank-again'));
    const u = await s.updateVersion('p', '1.0', { type: 'unyank' }, audit('p', 'unyank'));
    expect(u.state).toBe('published');
    expect(u).not.toHaveProperty('yank_reason');
    expect((await s.listAudit('p')).map((a) => a.action)).toEqual(['upload', 'publish', 'yank', 'unyank']);
  });

  test('refused transitions and missing versions raise version_not_found and change nothing', async () => {
    await expect(s.updateVersion('p', '1.0', { type: 'publish' }, audit('p', 'x'))).rejects.toMatchObject({ code: 'version_not_found' });
    await s.createVersion(rec({ name: 'p', version: '1.0', state: 'pending' }), audit('p', 'upload'));
    await expect(s.updateVersion('p', '1.0', { type: 'yank', reason: 'r' }, audit('p', 'yank'))).rejects.toMatchObject({ code: 'version_not_found' });
    expect((await s.getVersion('p', '1.0'))?.state).toBe('pending');
    expect(await s.listAudit('p')).toHaveLength(1);
  });

  test('listVersions is ordered by conda ordering, not by text', async () => {
    for (const v of ['1.10', '1.9', '1.0rc1', '1.0', '1.2']) await s.createVersion(rec({ name: 'p', version: v }), audit('p', 'publish', v));
    expect((await s.listVersions('p')).map((r) => r.version)).toEqual(['1.0rc1', '1.0', '1.2', '1.9', '1.10']);
  });

  test('packages are create-once; names are listed across pages', async () => {
    const now = '2026-10-13T12:00:00Z';
    for (const n of ['c', 'a', 'b', 'e', 'd']) await s.createPackage({ name: n, state: 'active', created_at: now });
    await expect(s.createPackage({ name: 'a', state: 'active', created_at: now })).rejects.toMatchObject({ code: 'name_taken' });
    expect(await s.listPackageNames()).toEqual(['a', 'b', 'c', 'd', 'e']);
    expect((await s.getPackage('a'))?.name).toBe('a');
    expect(await s.getPackage('zz')).toBeUndefined();
  });

  test('owners', async () => {
    const o = (id: number) => ({ name: 'p', github_id: id, handle: `u${id}`, added_at: '2026-10-13T12:00:00Z' });
    for (const id of [30, 4, 200, 11]) await s.addOwner(o(id));
    await expect(s.addOwner(o(4))).rejects.toMatchObject({ code: 'already_owner' });
    await s.removeOwner('p', 200);
    await expect(s.removeOwner('p', 200)).rejects.toMatchObject({ code: 'owner_not_found' });
    expect((await s.listOwners('p')).map((x) => x.github_id)).toEqual([4, 11, 30]);
  });
});

describe('create-once under concurrency', () => {
  test.each(factories)('%s: exactly one of two concurrent creates wins', async (_l, make) => {
    const s = make();
    // Different spellings: only an equivalence-aware key makes them collide.
    const results = await Promise.allSettled([
      s.createVersion(rec({ name: 'p', version: '1.0' }), audit('p', 'publish')),
      s.createVersion(rec({ name: 'p', version: '1.0.0' }), audit('p', 'publish')),
    ]);
    expect(results.map((r) => r.status).sort()).toEqual(['fulfilled', 'rejected']);
    const loser = results.find((r) => r.status === 'rejected') as PromiseRejectedResult;
    expect(loser.reason).toMatchObject({ code: 'version_exists' });
    expect(await s.listVersions('p')).toHaveLength(1);
    expect(await s.listAudit('p')).toHaveLength(1);
  });

  test.each(factories)('%s: six concurrent creates of one version, one winner', async (_l, make) => {
    const s = make();
    const spellings = ['3', '3.0', '3.0.0', '3.0.0.0', '3.0.0.0.0', '3.0.0.0.0.0'];
    const results = await Promise.allSettled(spellings.map((v) => s.createVersion(rec({ name: 'p', version: v }), audit('p', 'publish', v))));
    expect(results.filter((r) => r.status === 'fulfilled')).toHaveLength(1);
    expect(await s.listVersions('p')).toHaveLength(1);
  });

  test.each(factories)('%s: two concurrent yanks end yanked, one change recorded', async (_l, make) => {
    const s = make();
    await s.createVersion(rec({ name: 'p', version: '1.0' }), audit('p', 'publish'));
    await Promise.all([
      s.updateVersion('p', '1.0', { type: 'yank', reason: 'one' }, audit('p', 'yank')),
      s.updateVersion('p', '1.0', { type: 'yank', reason: 'two' }, audit('p', 'yank')),
    ]);
    const v = await s.getVersion('p', '1.0');
    expect(v?.state).toBe('yanked');
    expect(['one', 'two']).toContain(v?.yank_reason);
    expect(v?.rev).toBe(1);
    expect(await s.listAudit('p')).toHaveLength(2); // publish + one yank
  });

  test.each(factories)('%s: a yank racing a takedown ends tombstoned', async (_l, make) => {
    const s = make();
    await s.createVersion(rec({ name: 'p', version: '1.0' }), audit('p', 'publish'));
    await Promise.allSettled([
      s.updateVersion('p', '1.0', { type: 'yank', reason: 'x' }, audit('p', 'yank')),
      s.updateVersion('p', '1.0', { type: 'tombstone', reason_code: 'abuse', date: '2026-10-12' }, audit('p', 'takedown')),
    ]);
    expect((await s.getVersion('p', '1.0'))?.state).toBe('tombstoned');
  });

  // Can-fail proof: the same race against a read-then-write create produces two winners, so the
  // "exactly one wins" assertions above can go red.
  test('mutant: a read-then-write create lets both racers win', async () => {
    const naive = new NaiveCreate(new FakeDocClient());
    const results = await Promise.all([naive.createVersion(rec({ name: 'p', version: '1.0' })), naive.createVersion(rec({ name: 'p', version: '1.0.0' }))]);
    expect(results).toEqual(['created', 'created']);
  });
});

describe('DynamoDB adapter specifics', () => {
  test('equivalent spellings share one row keyed by the canonical version', async () => {
    const doc = new FakeDocClient();
    const s = new DynamoStore(doc, tablesFor('t'));
    await s.createVersion(rec({ name: 'p', version: '1.0.0' }), audit('p', 'publish'));
    const row = (await doc.send(new GetCommand({ TableName: 'mopm-t-versions', Key: { name: 'p', version: '1' } }))).Item;
    expect(row).toMatchObject({ name: 'p', version: '1', version_spelling: '1.0.0', state: 'published' });
    expect(row).not.toHaveProperty('canonical');
  });

  test('creating never reads first: the condition is the only guard', async () => {
    const doc = new FakeDocClient();
    await new DynamoStore(doc, tablesFor('t')).createVersion(rec({ name: 'p', version: '1.0' }), audit('p', 'publish'));
    expect(doc.calls).toEqual(['TransactWriteCommand']);
  });

  test('table names follow the data stack', () => {
    expect(tablesFor('beta')).toEqual({
      packages: 'mopm-beta-packages',
      versions: 'mopm-beta-versions',
      owners: 'mopm-beta-owners',
      audit: 'mopm-beta-audit',
    });
  });
});
