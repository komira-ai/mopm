import type { View } from '../../src/group';
import { MemoryStore } from '../../src/memory-store';
import type { QueueMessage } from '../../src/publish/ports';
import { validatePublish } from '../../src/publish/validator';
import { Harness, pkg } from './harness';

/**
 * A registry whose next read of package rows by the index builder (versionsOf, which `allRecords` calls) stops after
 * reading, until released: the interleaving of two index jobs, made deterministic.
 */
class GatedStore extends MemoryStore {
  private gate?: Promise<void>;
  private open?: () => void;
  private entered?: () => void;
  reachedGate?: Promise<void>;
  arm() {
    this.gate = new Promise<void>((r) => (this.open = r));
    this.reachedGate = new Promise<void>((r) => (this.entered = r));
  }
  release() {
    this.open?.();
  }
  async versionsOf(names: readonly string[], view: View) {
    const out = await super.versionsOf(names, view);
    const g = this.gate;
    if (g) {
      this.gate = undefined;
      this.entered?.();
      await g;
    }
    return out;
  }
}

/**
 * How SQS FIFO delivers: with `serialize`, messages of one group run one after another, in order; groups run side by
 * side. Without it every message runs at once (the mutant: a queue with no group lock, or a standard queue).
 */
class Consumer {
  private tails = new Map<string, Promise<unknown>>();
  constructor(
    private serialize: boolean,
    private handle: (m: QueueMessage) => Promise<void>,
  ) {}
  deliver(m: QueueMessage): Promise<void> {
    if (!this.serialize) return this.handle(m);
    const prev = this.tails.get(m.groupId) ?? Promise.resolve();
    const next = prev.then(() => this.handle(m));
    this.tails.set(m.groupId, next.catch(() => undefined));
    return next;
  }
}

const turn = () => new Promise<void>((r) => setImmediate(r));

/** Publish p1, start its index job and stop it after it read the records; publish p2 meanwhile; finish both. */
async function twoPackagesOneSubdir(serialize: boolean) {
  const registry = new GatedStore();
  const h = new Harness({}, registry);
  const me = await h.account(1, 'a', ['pa', 'pb']);
  const p1 = pkg({ name: 'pa', version: '1.0.0', subdir: 'noarch' });
  const p2 = pkg({ name: 'pb', version: '1.0.0', subdir: 'noarch' });
  const consumer = new Consumer(serialize, (m) => h.handleIndex(m));

  await h.publish(me.token, p1);
  await h.runValidator();
  const m1 = h.indexQueue.take()!;
  registry.arm();
  const jobA = consumer.deliver(m1);
  await registry.reachedGate; // job A has read the records: it knows pa only

  await h.publish(me.token, p2);
  await h.runValidator();
  const m2 = h.indexQueue.take()!;
  const jobB = consumer.deliver(m2); // serialized: waits for A. unserialized: runs now, to the end.
  await turn();
  await turn();
  registry.release();
  await Promise.all([jobA, jobB]);
  await h.runIndexer(); // the package index jobs the last repodata jobs queued
  return { h, files: Object.keys(h.repodata('noarch')['packages.conda']).sort(), p1, p2 };
}

describe('two packages published into one subdir at the same time', () => {
  test('with the subdir as the FIFO group, repodata lists both and both publishes are published', async () => {
    const { h, files, p1, p2 } = await twoPackagesOneSubdir(true);
    expect(files).toEqual([p1.filename, p2.filename].sort());
    for (const rec of h.publishes.publishes.values()) expect(rec.status).toBe('published');
  });

  // The can-fail proof for the test above: take the group lock away and the very same scenario loses a package.
  // Job B (which sees both) finishes first, then the stale job A overwrites it with a file that lacks pb.
  test('MUTANT: with no group lock the same interleaving loses a package, so the test above can fail', async () => {
    const { files, p1, p2 } = await twoPackagesOneSubdir(false);
    expect(files).toEqual([p1.filename]);
    expect(files).not.toContain(p2.filename);
  });

  test('many packages, validated all at once and indexed side by side per subdir: every one is in the final repodata', async () => {
    const h = new Harness();
    const names = Array.from({ length: 8 }, (_, i) => `pkg_${i}`);
    const me = await h.account(1, 'a', names);
    const packs = names.map((name, i) => pkg({ name, version: '1.0.0', subdir: i % 2 === 0 ? 'noarch' : 'linux-64' }));
    for (const p of packs) await h.publish(me.token, p);
    const validate = new Consumer(true, async (m) => {
      await validatePublish(h.validatorDeps, JSON.parse(m.body).publish_id);
    });
    const queued = [...h.validateQueue.sent];
    h.validateQueue.sent.length = 0;
    await Promise.all(queued.map((m) => validate.deliver(m)));

    const index = new Consumer(true, (m) => h.handleIndex(m));
    const messages = [...h.indexQueue.sent];
    h.indexQueue.sent.length = 0;
    await Promise.all(messages.map((m) => index.deliver(m)));
    await h.runIndexer(); // the package index jobs the last repodata jobs queued

    for (const sub of ['noarch', 'linux-64']) {
      const want = packs
        .filter((p) => p.subdir === sub)
        .map((p) => p.filename)
        .sort();
      expect(Object.keys(h.repodata(sub)['packages.conda']).sort()).toEqual(want);
    }
    for (const rec of h.publishes.publishes.values()) expect(rec.status).toBe('published');
  });
});

describe('redelivery: SQS delivers at least once, and a Lambda can die between any two steps', () => {
  test('validating the same message twice publishes once', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const id = await h.publish(me.token, pkg({ name: 'demo', version: '1.0.0' }));
    expect(await validatePublish(h.validatorDeps, id)).toBe('processed');
    const rev = (await h.registry.getVersion('demo', '1.0.0'))!.rev;
    expect(await validatePublish(h.validatorDeps, id)).toBe('processed'); // indexing: only re-sends the index messages
    expect((await h.registry.getVersion('demo', '1.0.0'))!.rev).toBe(rev);
    await h.runIndexer();
    expect(await validatePublish(h.validatorDeps, id)).toBe('skipped');
    expect((await h.registry.listAudit('demo')).filter((a) => a.action === 'publish')).toHaveLength(1);
  });

  test('a crash after the files were copied but before the version was published: the retry finishes the job', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const p = pkg({ name: 'demo', version: '1.0.0' });
    const id = await h.publish(me.token, p);
    // The first attempt dies in updateVersion, after the copy.
    const real = h.registry.updateVersion.bind(h.registry);
    let calls = 0;
    h.registry.updateVersion = async (...a: Parameters<typeof real>) => {
      if (calls++ === 0) throw new Error('lambda died');
      return real(...a);
    };
    await expect(validatePublish(h.validatorDeps, id)).rejects.toThrow('lambda died');
    expect(h.objects.keys('noarch/')).toEqual([`noarch/${p.filename}`]);
    expect((await h.registry.getVersion('demo', '1.0.0'))!.state).toBe('pending');
    // The quarantine object is still there for the retry.
    expect(h.objects.keys('quarantine/')).toHaveLength(1);

    expect(await validatePublish(h.validatorDeps, id)).toBe('processed');
    await h.runIndexer();
    expect((await h.status(me.token, id)).body.status).toBe('published');
    expect(Object.keys(h.repodata('noarch')['packages.conda'])).toEqual([p.filename]);
  });

  test('a crash after the verdict was written to the version but before the publish was marked: the retry reports the same verdict', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const junk = Buffer.from('junk');
    const begin = await h.call('POST', '/api/v1/packages/demo/1.0.0/files', me.token, {
      subdir: 'noarch',
      filename: 'mojo-demo-1.0.0-mojo1.0.0_0.conda',
      sha256: 'a'.repeat(64),
      size: junk.length,
    });
    const uploadId = JSON.parse(begin.body).upload_id as string;
    await h.objects.put((await h.publishes.getUpload(uploadId))!.key, junk, { contentType: 'application/octet-stream' });
    const c = await h.commit(me.token, 'demo', '1.0.0', [uploadId], 'b'.repeat(64));
    const id = JSON.parse(c.body).publish_id as string;

    const real = h.publishes.updatePublish.bind(h.publishes);
    let armed = false;
    h.publishes.updatePublish = async (...a: Parameters<typeof real>) => {
      // The first write after the status became 'validating' is the rejection mark: it dies.
      const cur = await h.publishes.getPublish(id);
      if (cur?.status === 'validating' && !armed) {
        armed = true;
        throw new Error('lambda died');
      }
      return real(...a);
    };
    await expect(validatePublish(h.validatorDeps, id)).rejects.toThrow('lambda died');
    expect((await h.registry.getVersion('demo', '1.0.0'))!.state).toBe('tombstoned');
    expect((await h.status(me.token, id)).body.status).toBe('validating');

    await validatePublish(h.validatorDeps, id);
    expect((await h.status(me.token, id)).body).toMatchObject({ status: 'rejected', rejection_code: 'sha256_mismatch' });
  });

  test('an index job run twice (duplicate delivery) leaves the same bytes and the publish published', async () => {
    const h = new Harness();
    const me = await h.account(1, 'a', ['demo']);
    const id = await h.publish(me.token, pkg({ name: 'demo', version: '1.0.0' }));
    await h.runValidator();
    const m = h.indexQueue.take()!;
    await h.handleIndex(m);
    const once = h.objects.objects.get('noarch/repodata.json')!.body.toString();
    await h.handleIndex(m);
    expect(h.objects.objects.get('noarch/repodata.json')!.body.toString()).toBe(once);
    // Repodata is done; the publish waits for its package index file, which the last repodata job queued once.
    expect((await h.status(me.token, id)).body.status).toBe('indexing');
    expect(h.indexQueue.sent.map((x) => JSON.parse(x.body).type)).toEqual(['index_pkg']);
    await h.runIndexer();
    expect((await h.status(me.token, id)).body.status).toBe('published');
  });
});
