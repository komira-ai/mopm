import { createHash } from 'node:crypto';
import { emptyIndex, indexSubdir } from '../../src/publish/indexer';
import { SUBDIRS_V1 } from '../../src/types';
import { Harness } from './harness';

const sha = (b: Buffer) => createHash('sha256').update(b).digest('hex');

// THE SEED-HASH PIN, MOVED.
//
// Until this change service/infra/stacks/test/empty-channel.test.ts pinned the sha256 of the empty repodata files that the
// channel stack seeded at deploy time (a BucketDeployment), with the warning "the index writer must own repodata
// before any change here". The runbook ("Before the first real publish") said the seeding goes, with that pin, when
// the index writer lands. This is that change, made on purpose: the seed is removed from the channel stack, and the
// empty index is now the writer's output, created lazily by the index Lambda. These are the bytes it creates; if the
// writer's format ever changes, this fails, and a reviewer decides whether live empty indexes are worth rewriting.
const PINNED: Record<string, { json: string; zst: string }> = {
  noarch: { json: 'de89c35a1f2e650a031b134f20101f1f5b75cc4e75b6de3ec7dc0cfe66cbd5c5', zst: '15b9dade4c44b064e0b567498934b730ca6c480ade7df1d166a2ed8d454e91a4' },
  'linux-64': { json: '77f566cca6c3b46354d0d0bfdc86a85c3279210929642feb7f6e125c66a357a1', zst: '30e605bc0fdda3da0614ba94459da61bdd42ed1a9f94d7a1eb7221a83f82c395' },
  'linux-aarch64': { json: '38ea12f3bcee509b9b33519107f796c01c739466c9d901ff49f360c16339d032', zst: '0874b9bd4de6e32c716b53fbdcfa44f844939129f964175fd27a485b88f93e9c' },
  'osx-arm64': { json: 'eb9fe038fc9d3c379d709cee650f6b746dc4590b71d28722701fc9d71695fc7e', zst: '0a3b9b3aea51645b70d3002e708a571d6b5da8903f2860f4b28f3c9964c20fd2' },
};

describe('the empty index the writer creates', () => {
  test('is a valid conda repodata of exactly its subdir, with no packages', () => {
    for (const s of SUBDIRS_V1) {
      const r = JSON.parse(emptyIndex(s).json.toString('utf8'));
      expect(r).toEqual({ info: { subdir: s }, packages: {}, 'packages.conda': {}, removed: [] });
    }
  });

  test('the pinned sha256 of every file', () => {
    expect(Object.keys(PINNED).sort()).toEqual([...SUBDIRS_V1].sort());
    for (const s of SUBDIRS_V1) {
      const e = emptyIndex(s);
      expect({ subdir: s, json: sha(e.json), zst: sha(e.zst) }).toEqual({ subdir: s, ...PINNED[s] });
    }
  });

  test('the .zst is a zstd frame of the same bytes (magic, then raw blocks)', () => {
    for (const s of SUBDIRS_V1) {
      const e = emptyIndex(s);
      expect([...e.zst.subarray(0, 4)]).toEqual([0x28, 0xb5, 0x2f, 0xfd]);
      expect(e.zst.subarray(e.zst.length - e.json.length).equals(e.json)).toBe(true);
    }
  });

  test('a fresh channel gets all four on the first index run (create-only), nothing else', async () => {
    const h = new Harness();
    expect(h.objects.keys()).toEqual([]);
    await indexSubdir(h.indexerDeps, { type: 'index', subdir: 'noarch' });
    expect(h.objects.keys()).toEqual(SUBDIRS_V1.flatMap((s) => [`${s}/repodata.json`, `${s}/repodata.json.zst`]).sort());
    for (const s of SUBDIRS_V1) expect(sha(h.objects.objects.get(`${s}/repodata.json`)!.body)).toBe(PINNED[s]!.json);
    // The only CDN paths touched are the rebuilt subdir's.
    expect(h.invalidator.batches.map((b) => b.paths)).toEqual([['/noarch/repodata.json', '/noarch/repodata.json.zst']]);
  });

  test('an unknown subdir in a message is dropped and logged, never written', async () => {
    const h = new Harness();
    await indexSubdir(h.indexerDeps, { type: 'index', subdir: '../evil' });
    expect(h.objects.keys()).toEqual([]);
    expect(h.logs).toHaveLength(1);
  });

  test('repodata is served with a one-minute cache and the right content types', async () => {
    const h = new Harness();
    await indexSubdir(h.indexerDeps, { type: 'index', subdir: 'osx-arm64' });
    const json = h.objects.objects.get('osx-arm64/repodata.json')!;
    const zst = h.objects.objects.get('osx-arm64/repodata.json.zst')!;
    expect([json.cacheControl, json.contentType]).toEqual(['public, max-age=60', 'application/json']);
    expect([zst.cacheControl, zst.contentType]).toEqual(['public, max-age=60', 'application/zstd']);
  });
});
