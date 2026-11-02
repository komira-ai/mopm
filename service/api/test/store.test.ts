import { GetCommand, PutCommand, QueryCommand } from '@aws-sdk/lib-dynamodb';
import { DynamoStore, SEARCH_INDEX, tablesFor } from '../src/dynamo-store';
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

  test('create then get by version; a spelling that is not MAJOR.MINOR.PATCH is invalid_version', async () => {
    await s.createVersion(rec({ name: 'p', version: '1.0.0' }), audit('p', 'publish', '1.0.0'));
    const got = await s.getVersion('p', '1.0.0');
    expect(got?.version).toBe('1.0.0');
    expect(got?.canonical).toBe('1.0.0');
    for (const v of ['1', '1.0', '1.0.0.0', '1.0.0rc1']) {
      await expect(s.getVersion('p', v)).rejects.toMatchObject({ code: 'invalid_version' });
    }
    await expect(s.createVersion(rec({ name: 'p', version: '1.0' }), audit('p', 'publish', '1.0'))).rejects.toMatchObject({ code: 'invalid_version' });
    expect(await s.getVersion('p', '1.0.1')).toBeUndefined();
    expect(await s.getVersion('q', '1.0.0')).toBeUndefined();
  });

  test('the same version is refused with version_exists, naming the sha256', async () => {
    await s.createVersion(rec({ name: 'p', version: '1.0.0' }), audit('p', 'publish'));
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
    await s.createVersion(rec({ name: 'p', version: '1.0.0' }), audit('p', 'publish'));
    await s.createVersion(rec({ name: 'q', version: '1.0.0' }), audit('q', 'publish'));
    expect((await s.listVersions('q')).length).toBe(1);
  });

  test('invalid versions are refused before anything is written', async () => {
    await expect(s.createVersion(rec({ name: 'p', version: 'v1' }), audit('p', 'publish'))).rejects.toMatchObject({ code: 'invalid_version' });
    expect(await s.listVersions('p')).toEqual([]);
    expect(await s.listAudit('p')).toEqual([]);
  });

  test('a tombstoned number is never reusable, not even with different bytes', async () => {
    await s.createVersion(rec({ name: 'p', version: '2.0.0' }), audit('p', 'publish'));
    await s.updateVersion('p', '2.0.0', { type: 'tombstone', reason_code: 'malware', date: '2026-10-12' }, audit('p', 'takedown'));
    const other = { subdir: 'linux-64', filename: 'mojo-p-2.0.0-mojo1.0.0_0.conda', sha256: 'e'.repeat(64), size: 5 };
    await expect(s.createVersion(rec({ name: 'p', version: '2.0.0', files: [other] }), audit('p', 'publish'))).rejects.toMatchObject({
      code: 'version_exists',
    });
  });

  test('lifecycle: pending -> published -> yanked -> published, one audit row per change', async () => {
    await s.createVersion(rec({ name: 'p', version: '1.0.0', state: 'pending' }), audit('p', 'upload'));
    expect((await s.updateVersion('p', '1.0.0', { type: 'publish' }, audit('p', 'publish'))).state).toBe('published');
    const y = await s.updateVersion('p', '1.0.0', { type: 'yank', reason: 'broken' }, audit('p', 'yank'));
    expect([y.state, y.yank_reason, y.rev]).toEqual(['yanked', 'broken', 2]);
    // Idempotent: no change, so no audit row.
    await s.updateVersion('p', '1.0.0', { type: 'yank', reason: 'other' }, audit('p', 'yank-again'));
    const u = await s.updateVersion('p', '1.0.0', { type: 'unyank' }, audit('p', 'unyank'));
    expect(u.state).toBe('published');
    expect(u).not.toHaveProperty('yank_reason');
    expect((await s.listAudit('p')).map((a) => a.action)).toEqual(['upload', 'publish', 'yank', 'unyank']);
  });

  test('a missing version raises version_not_found, a refused transition invalid_transition, and neither changes anything', async () => {
    await expect(s.updateVersion('p', '1.0.0', { type: 'publish' }, audit('p', 'x'))).rejects.toMatchObject({ code: 'version_not_found' });
    await s.createVersion(rec({ name: 'p', version: '1.0.0', state: 'pending' }), audit('p', 'upload'));
    await expect(s.updateVersion('p', '1.0.0', { type: 'yank', reason: 'r' }, audit('p', 'yank'))).rejects.toMatchObject({ code: 'invalid_transition', status: 409 });
    expect((await s.getVersion('p', '1.0.0'))?.state).toBe('pending');
    expect(await s.listAudit('p')).toHaveLength(1);
  });

  test('listVersions is ordered by conda ordering, not by text', async () => {
    for (const v of ['1.10.0', '1.9.0', '1.0.1', '1.0.0', '1.2.0']) await s.createVersion(rec({ name: 'p', version: v }), audit('p', 'publish', v));
    expect((await s.listVersions('p')).map((r) => r.version)).toEqual(['1.0.0', '1.0.1', '1.2.0', '1.9.0', '1.10.0']);
  });

  test('packages are create-once; names are listed across pages', async () => {
    const now = '2026-10-13T12:00:00Z';
    for (const n of ['c', 'a', 'b', 'e', 'd']) await s.createPackage({ name: n, state: 'active', created_at: now });
    await expect(s.createPackage({ name: 'a', state: 'active', created_at: now })).rejects.toMatchObject({ code: 'name_taken' });
    expect(await s.listPackageNames()).toEqual(['a', 'b', 'c', 'd', 'e']);
    expect((await s.getPackage('a'))?.name).toBe('a');
    expect(await s.getPackage('zz')).toBeUndefined();
  });

  test('searchPackages: prefix, name order, strictly after a name, at most limit, summary fields only', async () => {
    const at = '2026-10-13T12:00:00Z';
    const names = ['http_d', 'httpx', 'zlib', 'http_a', 'http_c', 'http_b', 'ht'];
    for (const n of names) {
      await s.createPackage({ name: n, state: 'active', created_at: at, description: `d ${n}`, repository: 'https://github.com/example/r', license: 'MIT' });
    }
    const found = (prefix: string, after?: string, limit = 100) => s.searchPackages(prefix, after, limit).then((r) => r.map((p) => p.name));
    expect(await found('http_')).toEqual(['http_a', 'http_b', 'http_c', 'http_d']);
    expect(await found('')).toEqual(['ht', 'http_a', 'http_b', 'http_c', 'http_d', 'httpx', 'zlib']);
    expect(await found('http_', 'http_b')).toEqual(['http_c', 'http_d']); // strictly after
    expect(await found('http_', 'http_d')).toEqual([]);
    expect(await found('http_', undefined, 3)).toEqual(['http_a', 'http_b', 'http_c']);
    expect(await found('nomatch')).toEqual([]);
    // The result carries what a summary shows and nothing else (the index projects no more).
    expect((await s.searchPackages('zlib', undefined, 1))[0]).toEqual({ name: 'zlib', state: 'active', created_at: at, description: 'd zlib' });
  });

  test('searchPackages: a package without a description has no description key', async () => {
    await s.createPackage({ name: 'bare', state: 'claimed', created_at: '2026-10-13T12:00:00Z' });
    expect((await s.searchPackages('', undefined, 5))[0]).toEqual({ name: 'bare', state: 'claimed', created_at: '2026-10-13T12:00:00Z' });
  });

  test('owners', async () => {
    const o = (id: number) => ({ name: 'p', github_id: id, handle: `u${id}`, added_at: '2026-10-13T12:00:00Z' });
    for (const id of [30, 4, 200, 11]) await s.addOwner(o(id));
    await expect(s.addOwner(o(4))).rejects.toMatchObject({ code: 'already_owner' });
    await s.removeOwner('p', 200);
    await expect(s.removeOwner('p', 200)).rejects.toMatchObject({ code: 'owner_not_found' });
    expect((await s.listOwners('p')).map((x) => x.github_id)).toEqual([4, 11, 30]);
  });

  describe('activatePackage', () => {
    const at = '2026-10-13T12:00:00Z';
    const claimed = { name: 'p', state: 'claimed' as const, created_at: at, claim_expires_at: '2026-11-12T12:00:00Z' };

    test('a claimed package becomes active and loses its expiry, once; the search index shows the new state; other fields stay', async () => {
      await s.createPackage({ ...claimed, description: 'd' });
      expect(await s.activatePackage('p')).toBe(true);
      expect(await s.getPackage('p')).toEqual({ name: 'p', state: 'active', created_at: at, description: 'd' });
      expect((await s.searchPackages('p', undefined, 5)).map((x) => [x.name, x.state])).toEqual([['p', 'active']]);
      expect(await s.activatePackage('p')).toBe(false);
    });

    test('a missing package is not created by it', async () => {
      expect(await s.activatePackage('ghost')).toBe(false);
      expect(await s.getPackage('ghost')).toBeUndefined();
    });

    test('publishing a version activates its package; a version that is not published yet does not', async () => {
      await s.createPackage(claimed);
      await s.createVersion(rec({ name: 'p', version: '1.0.0' }), audit('p', 'publish'));
      expect((await s.getPackage('p'))?.state).toBe('claimed');
      await s.updateVersion('p', '1.0.0', { type: 'publish' }, audit('p', 'publish'));
      expect(await s.getPackage('p')).toEqual({ name: 'p', state: 'active', created_at: at });
    });

    test('a repeated publish event (it changes the row no further) still leaves the package active', async () => {
      await s.createPackage({ ...claimed, name: 'q' });
      await s.createVersion(rec({ name: 'q', version: '1.0.0' }), audit('q', 'publish'));
      await s.updateVersion('q', '1.0.0', { type: 'publish' }, audit('q', 'publish'));
      await s.updateVersion('q', '1.0.0', { type: 'publish' }, audit('q', 'publish'));
      expect((await s.getPackage('q'))?.state).toBe('active');
    });
  });

  describe('claimPackage', () => {
    const at = '2026-10-13T12:00:00Z';
    const pkg = (name: string) => ({ name, state: 'claimed' as const, created_at: at, claim_expires_at: '2026-11-12T12:00:00Z' });
    const owner = (name: string, id: number) => ({ name, github_id: id, handle: `u${id}`, added_at: at });

    test('writes the package, its owner and its audit entry together', async () => {
      await s.claimPackage(pkg('p'), owner('p', 7), audit('p', 'claim'));
      expect(await s.getPackage('p')).toEqual(pkg('p'));
      expect(await s.listOwners('p')).toEqual([owner('p', 7)]);
      expect((await s.listAudit('p')).map((e) => e.action)).toEqual(['claim']);
      expect((await s.searchPackages('p', undefined, 5)).map((x) => [x.name, x.state])).toEqual([['p', 'claimed']]);
    });

    test('a name that is taken is name_taken, and the loser writes nothing: no owner, no audit entry, the package as it was', async () => {
      await s.claimPackage(pkg('p'), owner('p', 7), audit('p', 'claim'));
      await expect(s.claimPackage({ ...pkg('p'), created_at: '2026-10-14T00:00:00Z' }, owner('p', 8), audit('p', 'claim'))).rejects.toMatchObject({ code: 'name_taken', status: 409 });
      expect(await s.getPackage('p')).toEqual(pkg('p'));
      expect((await s.listOwners('p')).map((x) => x.github_id)).toEqual([7]);
      expect(await s.listAudit('p')).toHaveLength(1);
    });

    test('a package made another way is taken too', async () => {
      await s.createPackage({ name: 'p', state: 'active', created_at: at });
      await expect(s.claimPackage(pkg('p'), owner('p', 7), audit('p', 'claim'))).rejects.toMatchObject({ code: 'name_taken' });
      expect(await s.listOwners('p')).toEqual([]);
      expect(await s.listAudit('p')).toEqual([]);
    });

    test('an owner row with no package makes the name taken as well, and writes no package', async () => {
      await s.addOwner(owner('p', 7));
      await expect(s.claimPackage(pkg('p'), owner('p', 7), audit('p', 'claim'))).rejects.toMatchObject({ code: 'name_taken' });
      expect(await s.getPackage('p')).toBeUndefined();
      expect(await s.listAudit('p')).toEqual([]);
    });

    test('of claims racing for one name exactly one wins', async () => {
      const results = await Promise.allSettled([1, 2, 3, 4].map((id) => s.claimPackage(pkg('p'), owner('p', id), audit('p', 'claim'))));
      expect(results.filter((r) => r.status === 'fulfilled')).toHaveLength(1);
      for (const r of results) if (r.status === 'rejected') expect(r.reason).toMatchObject({ code: 'name_taken' });
      expect(await s.listOwners('p')).toHaveLength(1);
      expect(await s.listAudit('p')).toHaveLength(1);
    });
  });
});

describe('create-once under concurrency', () => {
  test.each(factories)('%s: exactly one of two concurrent creates wins', async (_l, make) => {
    const s = make();
    // Different spellings: only an equivalence-aware key makes them collide.
    const results = await Promise.allSettled([
      s.createVersion(rec({ name: 'p', version: '1.0.0' }), audit('p', 'publish')),
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
    const spellings = ['3', '3.0.0', '3.0.0', '3.0.0.0', '3.0.0.0.0', '3.0.0.0.0.0'];
    const results = await Promise.allSettled(spellings.map((v) => s.createVersion(rec({ name: 'p', version: v }), audit('p', 'publish', v))));
    expect(results.filter((r) => r.status === 'fulfilled')).toHaveLength(1);
    expect(await s.listVersions('p')).toHaveLength(1);
  });

  test.each(factories)('%s: two concurrent yanks end yanked, one change recorded', async (_l, make) => {
    const s = make();
    await s.createVersion(rec({ name: 'p', version: '1.0.0' }), audit('p', 'publish'));
    await Promise.all([
      s.updateVersion('p', '1.0.0', { type: 'yank', reason: 'one' }, audit('p', 'yank')),
      s.updateVersion('p', '1.0.0', { type: 'yank', reason: 'two' }, audit('p', 'yank')),
    ]);
    const v = await s.getVersion('p', '1.0.0');
    expect(v?.state).toBe('yanked');
    expect(['one', 'two']).toContain(v?.yank_reason);
    expect(v?.rev).toBe(1);
    expect(await s.listAudit('p')).toHaveLength(2); // publish + one yank
  });

  test.each(factories)('%s: a yank racing a takedown ends tombstoned', async (_l, make) => {
    const s = make();
    await s.createVersion(rec({ name: 'p', version: '1.0.0' }), audit('p', 'publish'));
    await Promise.allSettled([
      s.updateVersion('p', '1.0.0', { type: 'yank', reason: 'x' }, audit('p', 'yank')),
      s.updateVersion('p', '1.0.0', { type: 'tombstone', reason_code: 'abuse', date: '2026-10-12' }, audit('p', 'takedown')),
    ]);
    expect((await s.getVersion('p', '1.0.0'))?.state).toBe('tombstoned');
  });

  // Can-fail proof: the same race against a read-then-write create produces two winners, so the
  // "exactly one wins" assertions above can go red.
  test('defect: a read-then-write create lets both racers win', async () => {
    const naive = new NaiveCreate(new FakeDocClient());
    const results = await Promise.all([naive.createVersion(rec({ name: 'p', version: '1.0.0' })), naive.createVersion(rec({ name: 'p', version: '1.0.0' }))]);
    expect(results).toEqual(['created', 'created']);
  });
});

describe('DynamoDB search index', () => {
  const at = '2026-10-13T12:00:00Z';
  const INDEX = 'by_search_bucket';
  async function seeded(pageSize = 2) {
    const doc = new FakeDocClient(pageSize);
    const s = new DynamoStore(doc, tablesFor('t'));
    for (const n of ['http_a', 'http_b', 'http_c', 'httpx', 'zlib']) await s.createPackage({ name: n, state: 'active', created_at: at, description: n, license: 'MIT' });
    doc.inputs.length = 0;
    doc.calls.length = 0;
    return { doc, s };
  }

  test('the adapter constants are the index the stack defines (data.test.ts pins the stack side)', () => {
    expect(SEARCH_INDEX).toEqual({ name: INDEX, bucketAttribute: 'search_bucket', bucket: 'all', projected: ['description', 'state', 'created_at'] });
  });

  test('a prefix search is one Query on the index with begins_with on name, resumed with ExclusiveStartKey and a shrinking Limit', async () => {
    const { doc, s } = await seeded(2); // the fake returns at most two items a page
    const got = await s.searchPackages('http_', 'http_a', 3);
    expect(got.map((p) => p.name)).toEqual(['http_b', 'http_c']);
    const base = {
      TableName: 'mopm-t-packages',
      IndexName: INDEX,
      KeyConditionExpression: '#b = :b AND begins_with(#n, :p)',
      ExpressionAttributeNames: { '#b': 'search_bucket', '#n': 'name' },
      ExpressionAttributeValues: { ':b': 'all', ':p': 'http_' },
    };
    // First page: starts after 'http_a'. Only 'http_b' and 'http_c' match after it, so the fake ends there.
    expect(doc.inputs).toEqual([{ ...base, Limit: 3, ExclusiveStartKey: { search_bucket: 'all', name: 'http_a' } }]);
    expect(doc.calls).toEqual(['QueryCommand']);
  });

  test('a search that spans index pages continues from LastEvaluatedKey until the limit is met', async () => {
    const { doc, s } = await seeded(1); // one item a page
    const got = await s.searchPackages('http', undefined, 3);
    expect(got.map((p) => p.name)).toEqual(['http_a', 'http_b', 'http_c']);
    const base = {
      TableName: 'mopm-t-packages',
      IndexName: INDEX,
      KeyConditionExpression: '#b = :b AND begins_with(#n, :p)',
      ExpressionAttributeNames: { '#b': 'search_bucket', '#n': 'name' },
      ExpressionAttributeValues: { ':b': 'all', ':p': 'http' },
    };
    expect(doc.inputs).toEqual([
      { ...base, Limit: 3 },
      { ...base, Limit: 2, ExclusiveStartKey: { search_bucket: 'all', name: 'http_a' } },
      { ...base, Limit: 1, ExclusiveStartKey: { search_bucket: 'all', name: 'http_b' } },
    ]);
  });

  test('no prefix: the key condition is the bucket alone (DynamoDB refuses an empty begins_with operand)', async () => {
    const { doc, s } = await seeded(10);
    expect((await s.searchPackages('', undefined, 10)).map((p) => p.name)).toEqual(['http_a', 'http_b', 'http_c', 'httpx', 'zlib']);
    expect(doc.inputs).toEqual([
      {
        TableName: 'mopm-t-packages',
        IndexName: INDEX,
        KeyConditionExpression: '#b = :b',
        ExpressionAttributeNames: { '#b': 'search_bucket' },
        ExpressionAttributeValues: { ':b': 'all' },
        Limit: 10,
      },
    ]);
  });

  test('search never scans and asks for no more than it needs', async () => {
    const { doc, s } = await seeded(10);
    await s.searchPackages('http', undefined, 2);
    expect(doc.calls).toEqual(['QueryCommand']);
    expect(doc.inputs[0].Limit).toBe(2);
    expect(await s.searchPackages('http', undefined, 0)).toEqual([]);
    expect(doc.calls).toHaveLength(1); // a zero limit asks nothing
  });

  test('createPackage writes the index attribute; reads do not show it', async () => {
    const doc = new FakeDocClient();
    const s = new DynamoStore(doc, tablesFor('t'));
    await s.createPackage({ name: 'pkg', state: 'claimed', created_at: at });
    const row = (await doc.send(new GetCommand({ TableName: 'mopm-t-packages', Key: { name: 'pkg' } }))).Item;
    expect(row).toEqual({ name: 'pkg', state: 'claimed', created_at: at, search_bucket: 'all' });
    expect(await s.getPackage('pkg')).toEqual({ name: 'pkg', state: 'claimed', created_at: at });
  });

  test('the index is sparse: a row written without the attribute is gettable but not searchable', async () => {
    const doc = new FakeDocClient();
    const s = new DynamoStore(doc, tablesFor('t'));
    await doc.send(new PutCommand({ TableName: 'mopm-t-packages', Item: { name: 'legacy', state: 'claimed', created_at: at } }));
    expect((await s.getPackage('legacy'))?.name).toBe('legacy');
    expect(await s.searchPackages('', undefined, 10)).toEqual([]);
  });

  // Can-fail proofs for the assertions above: each variant is a hand-built Query and must not match the adapter's.
  test('defect: a Query without begins_with returns names outside the prefix', async () => {
    const { doc } = await seeded(10);
    const r = await doc.send(
      new QueryCommand({ TableName: 'mopm-t-packages', IndexName: INDEX, KeyConditionExpression: '#b = :b', ExpressionAttributeNames: { '#b': 'search_bucket' }, ExpressionAttributeValues: { ':b': 'all' }, Limit: 10 }),
    );
    expect(r.Items.map((i: any) => i.name)).toContain('zlib');
  });
  test('defect: begins_with with an empty prefix, a key on the wrong attribute, a starting key outside the range, all refused by the fake', async () => {
    const { doc } = await seeded(10);
    const q = (over: object) =>
      doc.send(
        new QueryCommand({
          TableName: 'mopm-t-packages', IndexName: INDEX, KeyConditionExpression: '#b = :b AND begins_with(#n, :p)',
          ExpressionAttributeNames: { '#b': 'search_bucket', '#n': 'name' }, ExpressionAttributeValues: { ':b': 'all', ':p': 'http' }, Limit: 5, ...over,
        }),
      );
    await expect(q({})).resolves.toBeDefined();
    await expect(q({ ExpressionAttributeValues: { ':b': 'all', ':p': '' } })).rejects.toThrow(/empty/);
    await expect(q({ ExpressionAttributeNames: { '#b': 'name', '#n': 'name' } })).rejects.toThrow(/partition key/);
    await expect(q({ ExclusiveStartKey: { search_bucket: 'all', name: 'a' } })).rejects.toThrow(/outside the query/);
  });
  test('defect: the projection is honoured (repository and license are not in an index item)', async () => {
    const { doc } = await seeded(10);
    const r = await doc.send(
      new QueryCommand({ TableName: 'mopm-t-packages', IndexName: INDEX, KeyConditionExpression: '#b = :b', ExpressionAttributeNames: { '#b': 'search_bucket' }, ExpressionAttributeValues: { ':b': 'all' }, Limit: 1 }),
    );
    expect(Object.keys(r.Items[0]).sort()).toEqual(['created_at', 'description', 'name', 'search_bucket', 'state']);
  });
});

describe('DynamoDB adapter specifics', () => {
  test('a version is one row keyed by the version', async () => {
    const doc = new FakeDocClient();
    const s = new DynamoStore(doc, tablesFor('t'));
    await s.createVersion(rec({ name: 'p', version: '1.0.0' }), audit('p', 'publish'));
    const row = (await doc.send(new GetCommand({ TableName: 'mopm-t-versions', Key: { name: 'p', version: '1.0.0' } }))).Item;
    expect(row).toMatchObject({ name: 'p', version: '1.0.0', version_spelling: '1.0.0', state: 'published' });
    expect(row).not.toHaveProperty('canonical');
  });

  test('creating never reads first: the condition is the only guard', async () => {
    const doc = new FakeDocClient();
    await new DynamoStore(doc, tablesFor('t')).createVersion(rec({ name: 'p', version: '1.0.0' }), audit('p', 'publish'));
    expect(doc.calls).toEqual(['TransactWriteCommand']);
  });

  test('a claim is one transaction of three conditional puts (package, owner, audit), in three tables, with no read first', async () => {
    const doc = new FakeDocClient();
    const at = '2026-10-13T12:00:00Z';
    await new DynamoStore(doc, tablesFor('t')).claimPackage(
      { name: 'p', state: 'claimed', created_at: at, claim_expires_at: at },
      { name: 'p', github_id: 7, handle: 'u7', added_at: at },
      audit('p', 'claim'),
    );
    expect(doc.calls).toEqual(['TransactWriteCommand']);
    const items = doc.inputs[0].TransactItems.map((i: any) => [i.Put.TableName, i.Put.ConditionExpression]);
    expect(items).toEqual([
      ['mopm-t-packages', 'attribute_not_exists(#n)'],
      ['mopm-t-owners', 'attribute_not_exists(#n)'],
      ['mopm-t-audit', 'attribute_not_exists(#n)'],
    ]);
  });

  test('a claim that fails for a reason other than a lost condition is not reported as name_taken', async () => {
    const doc = Object.assign(new FakeDocClient(), {
      send: async () => {
        throw new Error('throttled');
      },
    });
    const at = '2026-10-13T12:00:00Z';
    await expect(
      new DynamoStore(doc, tablesFor('t')).claimPackage({ name: 'p', state: 'claimed', created_at: at }, { name: 'p', github_id: 7, handle: 'u7', added_at: at }, audit('p', 'claim')),
    ).rejects.toThrow('throttled');
  });

  test('table names follow the data stack', () => {
    expect(tablesFor('beta')).toEqual({
      packages: 'mopm-beta-packages',
      versions: 'mopm-beta-versions',
      owners: 'mopm-beta-owners',
      audit: 'mopm-beta-audit',
      publishes: 'mopm-beta-publishes',
    });
  });
});
