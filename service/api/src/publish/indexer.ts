import { buildPackageIndex, buildTakedowns, indexKey, packageRev, TAKEDOWNS_KEY } from '../index-files';
import { INDEX_VIEW, repodataView, TAKEDOWNS_VIEW, type View } from '../group';
import { buildRepodata } from '../repodata';
import type { Store } from '../store';
import { SUBDIRS_V1 } from '../types';
import type { VersionRecord } from '../types';
import type { Invalidator, ObjectStore, PublishStore, Queue } from './ports';
import type { IndexMessage, IndexPkgMessage, IndexQueueMessage } from './types';

export interface IndexerDeps {
  registry: Store;
  publishes: PublishStore;
  objects: ObjectStore;
  invalidator: Invalidator;
  /** The index queue itself: the last repodata job asks for the package's sparse-index file. */
  indexQueue: Queue;
  now?: () => Date;
  log?: (line: Record<string, unknown>) => void;
  /** Subdirs whose empty index this container already made sure of. */
  ensured?: Set<string>;
}

/** The two files of a subdir's index, and the CloudFront paths to refresh when they change. */
export const repodataKeys = (subdir: string) => ({ json: `${subdir}/repodata.json`, zst: `${subdir}/repodata.json.zst` });

const REPODATA_CACHE = 'public, max-age=60';
const INDEX_CACHE = 'public, max-age=60';

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

  const records = await allRecords(d.registry, repodataView(msg.subdir));
  const files = buildRepodata(msg.subdir, records);
  const keys = repodataKeys(msg.subdir);
  // The .json first: a reader that finds the .zst new finds the .json new too.
  await d.objects.put(keys.json, files.json, { contentType: 'application/json', cacheControl: REPODATA_CACHE });
  await d.objects.put(keys.zst, files.zst, { contentType: 'application/zstd', cacheControl: REPODATA_CACHE });
  await d.invalidator.invalidate([`/${keys.json}`, `/${keys.zst}`], `index-${msg.subdir}-${msg.publish_id ?? 'rebuild'}-${now(d).getTime()}`);

  if (msg.publish_id !== undefined) {
    const cur = await d.publishes.updatePublish(msg.publish_id, (c) => {
      if (c.status !== 'indexing') return undefined;
      const remaining = c.remaining_subdirs.filter((s) => s !== msg.subdir);
      // The last subdir does not publish: the package's index file must be written first (the CLI fails closed
      // when its index runs ahead of repodata, never the other way round).
      return {
        ...c,
        remaining_subdirs: remaining,
        ...(remaining.length === 0 ? { index_pending: true } : {}),
        updated_at: now(d).toISOString(),
      };
    });
    if (cur && cur.status === 'indexing' && cur.remaining_subdirs.length === 0 && cur.index_pending) {
      await sendIndexPkg(d, { name: cur.name, publishId: cur.publish_id });
    }
  }
  if (msg.then) {
    const { name, rev, next } = msg.then;
    if (next.length > 0) {
      const follow: IndexMessage = { type: 'index', subdir: next[0]!, then: { name, rev, next: next.slice(1) } };
      await d.indexQueue.send({ body: JSON.stringify(follow), groupId: next[0]!, dedupId: `rebuild:${name}:${rev}:${next[0]}` });
    } else {
      await sendIndexPkg(d, { name, rev });
    }
  }
}

const now = (d: IndexerDeps) => (d.now ?? (() => new Date()))();

/**
 * Ask for a package's sparse-index file. The revision is read from the registry unless the sender already knows
 * it. FIFO group `pkg:<name>` serializes the writers of one package; the dedup id is `name:rev`, so a second
 * change inside the queue's five-minute window is a different message. A message that moves a publish on also
 * carries the publish id in its dedup id: two publishes of one package can finish at the same revision, and
 * neither may be dropped.
 */
export async function sendIndexPkg(d: Pick<IndexerDeps, 'registry' | 'indexQueue'>, o: { name: string; rev?: number; publishId?: string }): Promise<void> {
  const rev = o.rev ?? packageRev(await d.registry.listVersions(o.name));
  const msg: IndexPkgMessage = { type: 'index_pkg', name: o.name, rev, ...(o.publishId === undefined ? {} : { publish_id: o.publishId }) };
  const dedupId = o.publishId === undefined ? `${o.name}:${rev}` : `${o.name}:${rev}:${o.publishId}`;
  await d.indexQueue.send({ body: JSON.stringify(msg), groupId: `pkg:${o.name}`, dedupId });
}

/**
 * Process one `index_pkg` message: re-read the package's rows, and write `index/<aa>/<bb>/<name>` from them. The
 * message says only which package; what is written is the rows as they are now, so a message that arrives late
 * (a redelivery, a job behind a newer one) writes the newest state and cannot bring an older one back. Jobs of
 * one package run one at a time (the FIFO group). A package with no visible version has no file: nothing is
 * written (a rejected publish is that case).
 */
export async function indexPackage(d: IndexerDeps, msg: IndexPkgMessage): Promise<void> {
  const log = d.log ?? ((l: Record<string, unknown>) => console.log(JSON.stringify(l)));
  const rows = (await d.registry.versionsOf([msg.name], INDEX_VIEW)).get(msg.name)!;
  const body = buildPackageIndex(msg.name, rows);
  if (body === undefined) {
    log({ level: 'info', msg: 'index_pkg: the package has no visible version, no file written', name: msg.name });
  } else {
    if (msg.rev < packageRev(rows)) log({ level: 'info', msg: 'index_pkg: the message is older than the registry, writing the current state', name: msg.name, rev: msg.rev });
    await d.objects.put(indexKey(msg.name), Buffer.from(body, 'utf8'), { contentType: 'application/x-ndjson', cacheControl: INDEX_CACHE });
  }
  if (msg.publish_id === undefined) return;
  await d.publishes.updatePublish(msg.publish_id, (c) => {
    if (c.status !== 'indexing' || c.remaining_subdirs.length > 0) return undefined;
    return { ...c, status: 'published', index_pending: false, updated_at: now(d).toISOString() };
  });
}

/** Process one `index_takedowns` message: rebuild `index/takedowns.json` from every row of the registry (an empty log when none). */
export async function indexTakedowns(d: IndexerDeps): Promise<void> {
  const body = buildTakedowns(await allRecords(d.registry, TAKEDOWNS_VIEW));
  await d.objects.put(TAKEDOWNS_KEY, Buffer.from(body, 'utf8'), { contentType: 'application/json', cacheControl: INDEX_CACHE });
}

const PKG_NAME = /^[a-z][a-z0-9_]{1,63}$/;
const isRev = (v: unknown): v is number => typeof v === 'number' && Number.isSafeInteger(v) && v >= 0;

/**
 * An index-queue message body as a typed message, or undefined when it is none of the three kinds (the caller
 * drops and logs it: a message that cannot be understood would only fail again until the dead-letter queue).
 */
export function parseIndexMessage(raw: unknown): IndexQueueMessage | undefined {
  if (typeof raw !== 'object' || raw === null) return undefined;
  const m = raw as Record<string, unknown>;
  const publishId = typeof m.publish_id === 'string' ? { publish_id: m.publish_id } : {};
  switch (m.type) {
    case 'index': {
      if (typeof m.subdir !== 'string') return undefined;
      const t = m.then as Record<string, unknown> | undefined;
      if (t === undefined) return { type: 'index', subdir: m.subdir, ...publishId };
      if (typeof t.name !== 'string' || !PKG_NAME.test(t.name) || !isRev(t.rev) || !Array.isArray(t.next) || !t.next.every((x) => typeof x === 'string')) return undefined;
      return { type: 'index', subdir: m.subdir, ...publishId, then: { name: t.name, rev: t.rev, next: t.next as string[] } };
    }
    case 'index_pkg':
      if (typeof m.name !== 'string' || !PKG_NAME.test(m.name) || !isRev(m.rev)) return undefined;
      return { type: 'index_pkg', name: m.name, rev: m.rev, ...publishId };
    case 'index_takedowns':
      return { type: 'index_takedowns' };
    default:
      return undefined;
  }
}

/** Run one parsed message of the index queue. */
export async function processIndexMessage(d: IndexerDeps, msg: IndexQueueMessage): Promise<void> {
  if (msg.type === 'index') return indexSubdir(d, msg);
  if (msg.type === 'index_pkg') return indexPackage(d, msg);
  return indexTakedowns(d);
}

/**
 * Every version of every package, as `view` shows them: the truth the channel's files are derived from. The read
 * is one `versionsOf`, which also brings in the package of every member of a committed group that was claimed
 * after the package list was read, so a group's members are all in or all out of one build.
 */
export async function allRecords(registry: Store, view: View): Promise<VersionRecord[]> {
  const names = await registry.listPackageNames();
  return [...(await registry.versionsOf(names, view)).values()].flat();
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
