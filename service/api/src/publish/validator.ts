import { createHash, randomBytes } from 'node:crypto';
import type { PublishFill } from '../state';
import type { Store } from '../store';
import type { AuditEntry, Dep, FileRef, NativeRef } from '../types';
import { validatePackage } from '../validate';
import type { PackageFacts, RejectionCode, ValidatorOptions } from '../validate';
import type { NativeMirror } from '../validate/native-mirror';
import type { PublishConfig } from './config';
import type { DisplayMeta } from './display';
import type { ObjectStore, PublishStore, Queue } from './ports';
import { sendIndexPkg } from './indexer';
import { liveBytes } from './service';
import type { IndexMessage, PublishFile, PublishRecord } from './types';

export interface ValidatorDeps {
  registry: Store;
  publishes: PublishStore;
  objects: ObjectStore;
  indexQueue: Queue;
  config: PublishConfig;
  /** https://conda.<stage>.mopm.dev: the channel's public base, for the file URLs of published versions. */
  channelUrl: string;
  validatorOptions?: ValidatorOptions;
  nativeMirror?: () => Promise<NativeMirror | undefined>;
  now?: () => Date;
  log?: (line: Record<string, unknown>) => void;
}

const sha256Hex = (b: Uint8Array) => createHash('sha256').update(b).digest('hex');
const MAX_MESSAGE = 500;

/** A pass over one publish ended in a verdict that is final. */
export class Rejected extends Error {
  constructor(
    readonly code: RejectionCode,
    message: string,
  ) {
    super(message);
  }
}

/**
 * Process one `validate` message. Idempotent: SQS delivers at least once, and a Lambda can die between any two
 * steps, so every step either checks what already happened or is safe to repeat. Order of effects:
 *
 *  1. every file is validated on its own pass (bytes dropped after each, so memory stays at one archive);
 *  2. the files are copied into the channel from a second read, checked against the declared sha256 again, with
 *     create-only writes (what is validated is what is published, even if a quarantine object were replaced);
 *  3. the version goes pending -> published (conditional on its revision) carrying what the archives said;
 *  4. the publish moves to `indexing` with the subdirs to rewrite, and one index message per subdir is sent;
 *  5. the quarantine objects are deleted (also done on rejection). A failure here is only logged: the bucket's
 *     lifecycle rule expires quarantine/ after a day.
 *
 * A defect in our own code (anything that is not a verdict) is thrown, so the message is retried and, after the
 * queue's receive limit, lands in the dead-letter queue, which has an alarm. It is never blamed on the archive.
 */
export async function validatePublish(d: ValidatorDeps, publishId: string): Promise<'processed' | 'skipped'> {
  const log = d.log ?? ((l: Record<string, unknown>) => console.log(JSON.stringify(l)));
  let rec = await d.publishes.getPublish(publishId);
  if (!rec) {
    log({ level: 'error', msg: 'validate message for an unknown publish', publish_id: publishId });
    return 'skipped';
  }
  if (rec.status === 'published' || rec.status === 'rejected') return 'skipped';
  if (rec.status === 'indexing') {
    await sendIndex(d, rec); // a retry after the state change: only the messages may be missing
    return 'processed';
  }
  rec = (await d.publishes.updatePublish(publishId, (c) => (c.status === 'pending' ? touch(d, { ...c, status: 'validating' }) : undefined)))!;

  const version = await d.registry.getVersion(rec.name, rec.version);
  if (version?.group_id !== undefined) {
    // Not a verdict on the archives and not ours to settle: the number belongs to a group, and only the group's own
    // job fills, publishes or burns its rows. Thrown so the message is retried and then dead-lettered with its alarm.
    throw new Error(`publish ${rec.publish_id}: ${rec.name} ${rec.version} belongs to group ${version.group_id}; the single validator does not touch it`);
  }
  if (version?.state === 'tombstoned') {
    // A previous attempt burned the number and died before recording the verdict.
    await markRejected(d, rec, (version.tombstone?.reason_code as RejectionCode | undefined) ?? 'archive_invalid', 'the publish was rejected');
    return 'processed';
  }
  if (version?.state === 'published' || version?.state === 'yanked') {
    // An earlier attempt published the row; the store activates the package with that event, so this finishes what a crash between the two left.
    await d.registry.activatePackage(rec.name);
    await moveToIndexing(d, rec);
    return 'processed';
  }

  try {
    const facts = await validateAll(d, rec);
    await recordWarnings(d, rec, warningsOf(facts));
    await checkTotal(d, rec);
    await copyToChannel(d, rec);
    const fill = buildFill(d, rec, facts);
    await d.registry.updateVersion(rec.name, rec.version, { type: 'publish', fill }, audit(d, rec, 'publish', { files: String(rec.files.length) }));
    await moveToIndexing(d, rec);
    return 'processed';
  } catch (err) {
    if (!(err instanceof Rejected)) throw err;
    const msg = err.message.slice(0, MAX_MESSAGE);
    await d.registry.updateVersion(
      rec.name,
      rec.version,
      { type: 'tombstone', reason_code: err.code, date: today(d), unpublished: true },
      audit(d, rec, 'reject', { rejection_code: err.code }),
    );
    await markRejected(d, rec, err.code, msg);
    return 'processed';
  }
}

async function validateAll(d: ValidatorDeps, rec: PublishRecord): Promise<PackageFacts[]> {
  return validateArchives(d.objects, await optionsFor(d), rec, rec.files);
}

/**
 * The validator's options with the conda-forge name mirror the deployment could read. A mirror that cannot be read is not an error:
 * the checks that need it warn (src/validate/metadata.ts), so this never throws.
 */
export async function optionsFor(d: Pick<ValidatorDeps, 'validatorOptions' | 'nativeMirror' | 'now' | 'log'>): Promise<ValidatorOptions> {
  let nativeMirror: NativeMirror | undefined;
  try {
    nativeMirror = await d.nativeMirror?.();
  } catch (err) {
    (d.log ?? ((l) => console.log(JSON.stringify(l))))({ level: 'warn', msg: 'the conda-forge name mirror could not be read', error: String(err) });
  }
  return { ...d.validatorOptions, ...(nativeMirror ? { nativeMirror } : {}), ...(d.now ? { now: d.now } : {}) };
}

/** What the archives said that did not stop the publish, once each, in the order the files were validated. */
export const warningsOf = (facts: readonly PackageFacts[]): string[] => [...new Set(facts.flatMap((f) => f.warnings ?? []))];

/** Keep the warnings on the publish record, where the status route reads them; nothing is written when there are none. */
async function recordWarnings(d: ValidatorDeps, rec: PublishRecord, warnings: string[]): Promise<void> {
  if (warnings.length === 0) return;
  await d.publishes.updatePublish(rec.publish_id, (c) => (c.status === 'validating' ? touch(d, { ...c, warnings }) : undefined));
}

/**
 * Validate every archive of one version, each on its own pass (the bytes are dropped after each, so memory stays at one
 * archive), and check that they agree on build, dependencies and native libraries. The single publish and the group's
 * validator both run exactly this. Throws `Rejected` for a verdict on the archives.
 */
export async function validateArchives(
  objects: Pick<ObjectStore, 'get'>,
  options: ValidatorOptions | undefined,
  version: { name: string; version: string; manifest_sha256?: string },
  files: ReadonlyArray<Pick<PublishFile, 'key' | 'subdir' | 'filename' | 'sha256'>>,
): Promise<PackageFacts[]> {
  const out: PackageFacts[] = [];
  for (const f of files) {
    const bytes = await objects.get(f.key);
    if (!bytes) throw new Rejected('archive_invalid', `the upload of ${f.filename} is missing from quarantine`);
    const verdict = validatePackage(
      bytes,
      { name: version.name, version: version.version, subdir: f.subdir, filename: f.filename, sha256: f.sha256, ...(version.manifest_sha256 !== undefined ? { manifestSha256: version.manifest_sha256 } : {}) },
      options,
    );
    if (!verdict.ok) throw new Rejected(verdict.rejection_code, `${f.filename}: ${verdict.message}`);
    out.push(verdict.facts);
  }
  // One version, one build and one set of dependencies, whatever the platform.
  const first = out[0]!;
  for (const [i, facts] of out.entries()) {
    const same = facts.build === first.build && JSON.stringify(depsOf(facts)) === JSON.stringify(depsOf(first)) && JSON.stringify(nativeOf(facts)) === JSON.stringify(nativeOf(first)) && JSON.stringify(facts.nativeDepends) === JSON.stringify(first.nativeDepends) && facts.manifestSha256 === first.manifestSha256;
    if (!same) throw new Rejected('manifest_invalid', `${files[i]!.filename} disagrees with ${files[0]!.filename} on build, dependencies, native libraries or manifest`);
  }
  return out;
}

async function checkTotal(d: ValidatorDeps, rec: PublishRecord): Promise<void> {
  // The group (one per package) makes this exact: nothing else of this package is being published meanwhile.
  const used = liveBytes(await d.registry.listVersions(rec.name));
  const add = rec.files.reduce((n, f) => n + f.size, 0);
  if (used + add > d.config.projectQuotaBytes) {
    throw new Rejected('limit_exceeded', `the project would hold ${used + add} bytes; the limit is ${d.config.projectQuotaBytes}`);
  }
}

async function copyToChannel(d: ValidatorDeps, rec: PublishRecord): Promise<void> {
  for (const f of rec.files) {
    const bytes = await d.objects.get(f.key);
    if (!bytes) throw new Error(`quarantine object ${f.key} vanished after validation`);
    if (sha256Hex(bytes) !== f.sha256) throw new Rejected('sha256_mismatch', `${f.filename}: the upload changed after it was validated`);
    // 'exists' is a repeat of this very step (the key belongs to this version alone), so it is fine.
    await d.objects.put(`${f.subdir}/${f.filename}`, bytes, {
      contentType: 'application/octet-stream',
      cacheControl: 'public, max-age=31536000, immutable',
      createOnly: true,
    });
  }
}

const depsOf = (f: PackageFacts): Dep[] => f.metadata.deps.map((x) => (x.range === undefined ? { name: x.name } : { name: x.name, range: x.range }));
const nativeOf = (f: PackageFacts): NativeRef[] => f.metadata.native.map((n) => ({ id: n.id, soname: n.soname }));

function buildFill(d: ValidatorDeps, rec: PublishRecord, facts: PackageFacts[]): PublishFill {
  return fillFrom(d.channelUrl, (d.now ?? (() => new Date()))(), rec, rec.files, facts);
}

/**
 * What a version row holds once its archives are validated: the facts the archives stated, the files with their public
 * URLs, the display fields of the request and who published it. Pure. The single publish and the group's staging write this.
 */
export function fillFrom(
  channelUrl: string,
  now: Date,
  version: { version: string; display?: DisplayMeta; source_commit?: string; published_by: string },
  declared: ReadonlyArray<Pick<PublishFile, 'subdir' | 'filename' | 'sha256' | 'size'>>,
  facts: PackageFacts[],
): PublishFill {
  const first = facts[0]!;
  const files: FileRef[] = declared.map((f) => ({
    subdir: f.subdir,
    filename: f.filename,
    sha256: f.sha256,
    size: f.size,
    url: `${channelUrl.replace(/\/+$/, '')}/${f.subdir}/${f.filename}`,
  }));
  return {
    version: version.version,
    build: first.build,
    requires_mojo: `==${first.compiler}`,
    deps: depsOf(first),
    native: nativeOf(first),
    native_depends: first.nativeDepends,
    files,
    manifest_sha256: first.manifestSha256,
    ...(version.display ?? {}),
    ...(version.source_commit !== undefined ? { source_commit: version.source_commit } : {}),
    published_at: now.toISOString(),
    published_by: version.published_by,
  };
}

/** The version is published: record which subdirs still have to list it, and ask for each to be rewritten. */
async function moveToIndexing(d: ValidatorDeps, rec: PublishRecord): Promise<void> {
  const subdirs = [...new Set(rec.files.map((f) => f.subdir))].sort();
  const cur = await d.publishes.updatePublish(rec.publish_id, (c) =>
    c.status === 'validating' ? touch(d, { ...c, status: 'indexing', remaining_subdirs: subdirs }) : undefined,
  );
  await sendIndex(d, cur ?? rec);
  await deleteQuarantine(d, rec.files);
}

async function sendIndex(d: ValidatorDeps, rec: PublishRecord): Promise<void> {
  if (rec.remaining_subdirs.length === 0 && rec.index_pending) {
    // A retry after the last repodata job: only the package's index file is left to ask for.
    await sendIndexPkg({ registry: d.registry, indexQueue: d.indexQueue }, { name: rec.name, publishId: rec.publish_id });
    return;
  }
  for (const subdir of rec.remaining_subdirs) {
    const msg: IndexMessage = { type: 'index', subdir, publish_id: rec.publish_id };
    // One group per subdir: its repodata is rewritten by one job at a time.
    await d.indexQueue.send({ body: JSON.stringify(msg), groupId: subdir, dedupId: `${rec.publish_id}:${subdir}` });
  }
}

async function markRejected(d: ValidatorDeps, rec: PublishRecord, code: RejectionCode, message: string): Promise<void> {
  await d.publishes.updatePublish(rec.publish_id, (c) =>
    c.status === 'validating' || c.status === 'pending' ? touch(d, { ...c, status: 'rejected', rejection_code: code, message }) : undefined,
  );
  await deleteQuarantine(d, rec.files);
}

async function deleteQuarantine(d: ValidatorDeps, files: readonly PublishFile[]): Promise<void> {
  const log = d.log ?? ((l: Record<string, unknown>) => console.log(JSON.stringify(l)));
  for (const f of files) {
    try {
      await d.objects.delete(f.key);
    } catch (err) {
      log({ level: 'warn', msg: 'could not delete a quarantine object; the lifecycle rule will', key: f.key, error: String(err) });
    }
  }
}

const touch = (d: ValidatorDeps, rec: PublishRecord): PublishRecord => ({ ...rec, updated_at: (d.now ?? (() => new Date()))().toISOString() });
const today = (d: ValidatorDeps) => (d.now ?? (() => new Date()))().toISOString().slice(0, 10);
function audit(d: ValidatorDeps, rec: PublishRecord, action: string, detail: Record<string, string>): AuditEntry {
  return {
    name: rec.name,
    ts: (d.now ?? (() => new Date()))().toISOString(),
    id: `a_${randomBytes(8).toString('hex')}`,
    actor: rec.actor,
    action,
    version: rec.version,
    detail: { publish_id: rec.publish_id, ...detail, ...(rec.via === undefined ? {} : { via: rec.via }) },
  };
}
