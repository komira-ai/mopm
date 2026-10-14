import { DynamoPublishStore } from '../../src/publish/dynamo-publish-store';
import { AnyFlag, DynamoFlags, StaticFlags } from '../../src/publish/flags';
import { MemoryPublishStore } from '../../src/publish/memory';
import type { PublishStore } from '../../src/publish/ports';
import type { PublishRecord, UploadRecord } from '../../src/publish/types';
import { FakeDoc } from './fake-doc';

const upload = (id: string, over: Partial<UploadRecord> = {}): UploadRecord => ({
  upload_id: id,
  name: 'demo',
  version: '1.0.0',
  canonical: '1',
  subdir: 'noarch',
  filename: 'mojo-demo-1.0.0-mojo1.0.0_0.conda',
  sha256: 'a'.repeat(64),
  size: 10,
  key: `quarantine/${id}/f`,
  actor: 'u:1',
  created_at: '2026-10-14T12:00:00Z',
  url_expires_at: '2026-10-14T12:05:00Z',
  expires_at: 1_792_000_000,
  ...over,
});
const publish = (id: string, over: Partial<PublishRecord> = {}): PublishRecord => ({
  publish_id: id,
  name: 'demo',
  version: '1.0.0',
  canonical: '1',
  actor: 'u:1',
  published_by: 'octo',
  status: 'pending',
  manifest_sha256: 'b'.repeat(64),
  files: [],
  remaining_subdirs: [],
  created_at: '2026-10-14T12:00:00Z',
  updated_at: '2026-10-14T12:00:00Z',
  rev: 0,
  ...over,
});

const docFor = () => new FakeDoc({ 't-uploads': 'upload_id', 't-publishes': 'publish_id', 't-config': 'key', 't-tokens': 'token_hash' });

// The same contract runs against the memory store and the DynamoDB adapter, so the memory store (used by every other
// test) is held to what the real one does.
describe.each<[string, () => PublishStore]>([
  ['memory', () => new MemoryPublishStore()],
  ['dynamodb', () => new DynamoPublishStore(docFor(), { uploads: 't-uploads', publishes: 't-publishes' })],
])('PublishStore contract: %s', (_name, make) => {
  test('uploads: stored and read back, taken once by one publish', async () => {
    const s = make();
    await s.putUpload(upload('u1'));
    expect(await s.getUpload('u1')).toEqual(upload('u1'));
    expect(await s.getUpload('nope')).toBeUndefined();
    expect(await s.useUpload('u1', 'pub_a')).toBe(true);
    expect(await s.useUpload('u1', 'pub_a')).toBe(true); // the same publish again (a resume)
    expect(await s.useUpload('u1', 'pub_b')).toBe(false);
    expect((await s.getUpload('u1'))?.used_by).toBe('pub_a');
    expect(await s.useUpload('nope', 'pub_a')).toBe(false);
  });

  test('uploads: many publishes racing for one upload, exactly one gets it', async () => {
    const s = make();
    await s.putUpload(upload('u1'));
    const results = await Promise.all(Array.from({ length: 8 }, (_, i) => s.useUpload('u1', `pub_${i}`)));
    expect(results.filter(Boolean)).toHaveLength(1);
  });

  test('the version lock: the first claim wins, every other claimant is told who holds it', async () => {
    const s = make();
    expect(await s.versionHolder('demo', '1')).toBeUndefined();
    const winners = await Promise.all(Array.from({ length: 8 }, (_, i) => s.claimVersion('demo', '1', `pub_${i}`)));
    expect(new Set(winners).size).toBe(1);
    expect(await s.versionHolder('demo', '1')).toBe(winners[0]);
    expect(await s.claimVersion('demo', '1', 'pub_late')).toBe(winners[0]);
    // another version of the same package, and the same version of another package, are other locks
    expect(await s.claimVersion('demo', '2', 'pub_x')).toBe('pub_x');
    expect(await s.claimVersion('other', '1', 'pub_y')).toBe('pub_y');
  });

  test('publish records: create-once, and updates are compare-and-swap with retry', async () => {
    const s = make();
    const created = await s.createPublish(publish('pub_1'));
    expect(created.status).toBe('pending');
    const again = await s.createPublish(publish('pub_1', { status: 'rejected' }));
    expect(again.status).toBe('pending'); // the existing record, not the argument
    expect(await s.getPublish('pub_1')).toMatchObject({ publish_id: 'pub_1', rev: 0 });
    expect(await s.getPublish('nope')).toBeUndefined();
    expect(await s.updatePublish('nope', (c) => c)).toBeUndefined();

    // fn returns undefined: nothing is written
    expect(await s.updatePublish('pub_1', () => undefined)).toMatchObject({ rev: 0 });
    // five concurrent updates, each adding its own subdir: none is lost, rev counts them
    await Promise.all(
      ['a', 'b', 'c', 'd', 'e'].map((x) => s.updatePublish('pub_1', (c) => ({ ...c, remaining_subdirs: [...c.remaining_subdirs, x] }))),
    );
    const end = (await s.getPublish('pub_1'))!;
    expect([...end.remaining_subdirs].sort()).toEqual(['a', 'b', 'c', 'd', 'e']);
    expect(end.rev).toBe(5);
  });

  test('records with optional members unset are accepted (the document client refuses undefined)', async () => {
    const s = make();
    await s.createPublish(publish('pub_2', { rejection_code: undefined, message: undefined }));
    await s.putUpload(upload('u2', { used_by: undefined }));
    await s.updatePublish('pub_2', (c) => ({ ...c, status: 'rejected', rejection_code: 'archive_invalid', message: undefined }));
    expect((await s.getPublish('pub_2'))?.rejection_code).toBe('archive_invalid');
  });

  test('counters: the limit holds under concurrency, and keys are independent', async () => {
    const s = make();
    const results = await Promise.all(Array.from({ length: 12 }, () => s.hit('rl#u#1#2026-10-14', 5, 1_792_000_000)));
    expect(results.filter((r) => r.ok)).toHaveLength(5);
    expect(results.filter((r) => !r.ok).every((r) => r.count === 5)).toBe(true);
    expect((await s.hit('rl#u#2#2026-10-14', 5, 1_792_000_000)).ok).toBe(true);
    expect((await s.hit('rl#u#1#2026-10-15', 5, 1_792_000_000)).ok).toBe(true);
  });
});

describe('DynamoPublishStore rows', () => {
  test('uploads and publishes live in their tables; locks and counters share the publishes table under prefixed keys', async () => {
    const doc = docFor();
    const s = new DynamoPublishStore(doc, { uploads: 't-uploads', publishes: 't-publishes' });
    await s.putUpload(upload('u1'));
    await s.createPublish(publish('pub_1'));
    await s.claimVersion('demo', '1', 'pub_1');
    await s.hit('rl#t#tok#2026-10-14', 5, 1_792_000_000);
    expect([...doc.table('t-uploads').keys()]).toEqual(['u1']);
    expect([...doc.table('t-publishes').keys()].sort()).toEqual(['pub_1', 'rl#t#tok#2026-10-14', 'ver#demo#1']);
    // The TTL attribute of a counter is a number (epoch seconds), as the table's TTL requires.
    expect(doc.table('t-publishes').get('rl#t#tok#2026-10-14')!.expires_at).toBe(1_792_000_000);
    expect(doc.table('t-uploads').get('u1')!.expires_at).toBe(1_792_000_000);
  });

  test('only GetItem and PutItem are used: no update, delete or scan, which is what the role is granted', async () => {
    const doc = docFor();
    const s = new DynamoPublishStore(doc, { uploads: 't-uploads', publishes: 't-publishes' });
    await s.putUpload(upload('u1'));
    await s.useUpload('u1', 'p');
    await s.claimVersion('demo', '1', 'p');
    await s.createPublish(publish('p'));
    await s.updatePublish('p', (c) => ({ ...c, status: 'validating' }));
    await s.hit('k', 3, 1);
    expect(new Set(doc.sent)).toEqual(new Set(['GetCommand', 'PutCommand']));
  });
});

describe('the read-only switch', () => {
  test('DynamoFlags reads the config item, caches it briefly and fails closed when the read fails', async () => {
    const doc = docFor();
    let t = 1000;
    const flags = new DynamoFlags(doc, 't-config', 5000, () => t);
    expect(await flags.readOnly()).toBe(false); // no item
    doc.table('t-config').set('read_only', { key: 'read_only', value: true });
    t += 4000;
    expect(await flags.readOnly()).toBe(false); // cached
    t += 2000;
    expect(await flags.readOnly()).toBe(true); // refreshed: no deployment needed
    doc.table('t-config').set('read_only', { key: 'read_only', value: false });
    t += 6000;
    expect(await flags.readOnly()).toBe(false);
    expect(doc.sent.every((s) => s === 'GetCommand')).toBe(true);

    const broken = new DynamoFlags({ send: async () => { throw new Error('AccessDenied'); } }, 't', 5000, () => t);
    await expect(broken.readOnly()).rejects.toThrow('AccessDenied');
  });

  test('only a literal true switches it on', async () => {
    const doc = docFor();
    for (const value of ['true', 1, 'yes', null]) {
      doc.table('t-config').set('read_only', { key: 'read_only', value });
      expect(await new DynamoFlags(doc, 't-config', 0).readOnly()).toBe(false);
    }
  });

  test('AnyFlag: either switch is enough; StaticFlags is fixed', async () => {
    expect(await new AnyFlag([new StaticFlags(false), new StaticFlags(false)]).readOnly()).toBe(false);
    expect(await new AnyFlag([new StaticFlags(false), new StaticFlags(true)]).readOnly()).toBe(true);
  });
});
