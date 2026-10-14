import { buildRepodata } from '../repodata';
import type { Store } from '../store';
import { SUBDIRS_V1 } from '../types';
import type { VersionRecord } from '../types';
import type { Invalidator, ObjectStore, PublishStore } from './ports';
import type { IndexMessage } from './types';

export interface IndexerDeps {
  registry: Store;
  publishes: PublishStore;
  objects: ObjectStore;
  invalidator: Invalidator;
  now?: () => Date;
  log?: (line: Record<string, unknown>) => void;
  /** Subdirs whose empty index this container already made sure of. */
  ensured?: Set<string>;
}

/** The two files of a subdir's index, and the CloudFront paths to refresh when they change. */
export const repodataKeys = (subdir: string) => ({ json: `${subdir}/repodata.json`, zst: `${subdir}/repodata.json.zst` });

const REPODATA_CACHE = 'public, max-age=60';
const CONCURRENCY = 8;

/**
 * Process one `index` message: rebuild the subdir's repodata from the registry's records, write it, refresh the
 * CDN, and tell the publish that this subdir lists it.
 *
 * Why this is correct under concurrency: the messages of one subdir share a FIFO group, so at most one job per
 * subdir runs at a time and in order, and a job rebuilds from every committed record rather than patching the
 * file it finds. A version is committed (published) before its message is sent, so the job that handles that
 * message, and every later one, reads it. Two packages published at once into one subdir therefore both end up in
 * the final file; they cannot overwrite each other, because the two writes never overlap and the second one
 * includes the first one's package. (test/publish/indexer.test.ts plants the unserialized writer and shows the
 * loss.) The alternative, a DynamoDB lease, needs expiry and fencing to survive a dead holder; the queue's
 * group lock is already managed, ordered and visible.
 *
 * Also lazily creates the empty index of the other subdirs (create-only), so a channel that has seen one publish
 * has all four, and a stage that was wiped is repaired by the next publish. `{type:'index', subdir}` with no
 * publish id is a plain rebuild (what an operator or a later yank sends).
 */
export async function indexSubdir(d: IndexerDeps, msg: IndexMessage): Promise<void> {
  const log = d.log ?? ((l: Record<string, unknown>) => console.log(JSON.stringify(l)));
  if (!SUBDIRS_V1.includes(msg.subdir)) {
    log({ level: 'error', msg: 'index message for an unknown subdir', subdir: msg.subdir });
    return;
  }
  await ensureEmptyIndexes(d, msg.subdir);

  const records = await allRecords(d.registry);
  const files = buildRepodata(msg.subdir, records);
  const keys = repodataKeys(msg.subdir);
  // The .json first: a reader that finds the .zst new finds the .json new too.
  await d.objects.put(keys.json, files.json, { contentType: 'application/json', cacheControl: REPODATA_CACHE });
  await d.objects.put(keys.zst, files.zst, { contentType: 'application/zstd', cacheControl: REPODATA_CACHE });
  await d.invalidator.invalidate([`/${keys.json}`, `/${keys.zst}`], `index-${msg.subdir}-${msg.publish_id ?? 'rebuild'}-${(d.now ?? (() => new Date()))().getTime()}`);

  if (msg.publish_id === undefined) return;
  await d.publishes.updatePublish(msg.publish_id, (c) => {
    if (c.status !== 'indexing') return undefined;
    const remaining = c.remaining_subdirs.filter((s) => s !== msg.subdir);
    return {
      ...c,
      remaining_subdirs: remaining,
      status: remaining.length === 0 ? 'published' : 'indexing',
      updated_at: (d.now ?? (() => new Date()))().toISOString(),
    };
  });
}

/** Every version of every package: the truth the index is derived from. */
export async function allRecords(registry: Store): Promise<VersionRecord[]> {
  const names = await registry.listPackageNames();
  const out: VersionRecord[] = [];
  for (let i = 0; i < names.length; i += CONCURRENCY) {
    const batch = await Promise.all(names.slice(i, i + CONCURRENCY).map((n) => registry.listVersions(n)));
    for (const vs of batch) out.push(...vs);
  }
  return out;
}

/** The empty index of a subdir, as the writer produces it (also what a fresh channel serves before any publish). */
export const emptyIndex = (subdir: string) => buildRepodata(subdir, []);

async function ensureEmptyIndexes(d: IndexerDeps, except: string): Promise<void> {
  const ensured = d.ensured ?? new Set<string>();
  for (const subdir of SUBDIRS_V1) {
    if (subdir === except || ensured.has(subdir)) continue;
    const empty = emptyIndex(subdir);
    const keys = repodataKeys(subdir);
    await d.objects.put(keys.json, empty.json, { contentType: 'application/json', cacheControl: REPODATA_CACHE, createOnly: true });
    await d.objects.put(keys.zst, empty.zst, { contentType: 'application/zstd', cacheControl: REPODATA_CACHE, createOnly: true });
    ensured.add(subdir);
  }
}
