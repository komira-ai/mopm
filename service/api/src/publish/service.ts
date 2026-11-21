import { createHash, randomBytes } from 'node:crypto';
import type { Principal } from '../auth';
import { NAME_PATTERN, NamespaceError, type NamespaceAccess } from '../auth';
import { AuthError } from '../auth/errors';
import { buildOfFile, buildRowKey, buildsOf, isBuildRow, splitRowKey } from '../builds';
import { condaNameOf, splitFullName } from '../names';
import { ciActorOf } from '../auth/ci-publishers';
import { RegistryError, versionExists } from '../errors';
import type { GroupStore } from '../group-store';
import type { Store } from '../store';
import type { AuditEntry, VersionRecord } from '../types';
import { SUBDIRS_V1 } from '../types';
import { canonicalVersion } from '../version';
import type { PublishConfig } from './config';
import { parseDisplay } from './display';
import { parseSourceCommit } from './source-commit';
import type { DisplayMeta } from './display';
import { invalidRequest, PublishError, uploadInvalid } from './errors';
import { expireIfDue, isDead, orphanFree } from './group-lifecycle';
import type { ObjectStore, Presigner, PublishStore, Queue } from './ports';
import { repodataDirsOf } from '../channel-paths';
import { packageRev } from '../index-files';
import { sendIndexPkg } from './indexer';
import type { Actor, IndexMessage, PublishRecord, UploadRecord, ValidateMessage } from './types';

export interface PublishServiceDeps {
  registry: Store;
  /** Who may write in a namespace: the owner check of a full name (`/api/v2`). Absent, a write to a full name answers `unavailable`. */
  namespaces?: NamespaceAccess;
  /** The registry's group side (the same adapter object). With it, a single publish can take over the number of a dead group; without it, it never does. */
  groups?: GroupStore;
  publishes: PublishStore;
  /** Only `head` is used here: commit checks that the bytes arrived. */
  objects: Pick<ObjectStore, 'head'>;
  presigner: Presigner;
  validateQueue: Queue;
  /** The index writer's queue (one FIFO group per repodata directory). Yank and unyank send to it; absent, they answer `unavailable`. */
  indexQueue?: Queue;
  config: PublishConfig;
  now?: () => Date;
  newId?: () => string;
}

export interface BeginResult {
  upload_id: string;
  put_url: string;
  put_headers: Record<string, string>;
  expires_at: string;
}
export interface CommitResult {
  publish_id: string;
  status_url: string;
}
export interface YankResult {
  version: string;
  state: VersionRecord['state'];
  published_at: string;
  yank_reason?: string;
}
export interface PublishStatusBody {
  publish_id: string;
  name: string;
  version: string;
  status: PublishRecord['status'];
  rejection_code?: string;
  message?: string;
  /** What did not stop the publish (a native dependency name conda-forge does not list). Present only when there is something to say. */
  warnings?: string[];
}

const SHA256 = /^[0-9a-f]{64}$/;
const BUILD = /^mojo[0-9]+(?:\.[0-9]+)*_0$/;
const SAFE_FILENAME = /^[A-Za-z0-9][A-Za-z0-9._+-]{0,254}$/;
const dayOf = (d: Date) => d.toISOString().slice(0, 10);
const isObject = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);

/**
 * `u:<github id>` for an account's token; `ci:gh-repo:<repository id>` for the token of a configured CI publisher (one stable actor
 * for the identity, whichever token it holds); `ci:<token id>` for any other CI token (a package's registered trusted publisher).
 */
export const actorOf = (p: Principal): Actor =>
  p.github_id !== undefined ? `u:${p.github_id}` : p.kind === 'oidc' && p.ci_owner !== undefined ? ciActorOf(p.ci_owner) : `ci:${p.token_id}`;

/**
 * The CI identity a request came through, `ci:gh-repo:<repository id>`, for a token of a CI publisher that acts for an account
 * (the actor is then the account's `u:<id>`); undefined for a human's own token and for every other token. Recorded on the
 * records and audit entries of what the token does, so a publish by CI is distinguishable from the account's own.
 */
export const viaOf = (p: Principal): string | undefined => (p.acts_via !== undefined ? ciActorOf(p.acts_via) : undefined);
/** `{via}` for a record of a request that came through a CI identity, else nothing. */
export const viaField = (p: Principal): { via?: string } => {
  const via = viaOf(p);
  return via === undefined ? {} : { via };
};
/** An audit entry's detail with `via` added when the request came through a CI identity; undefined when there is neither. */
export const detailVia = (p: Principal, detail?: Record<string, string>): Record<string, string> | undefined => {
  const via = viaOf(p);
  return via === undefined ? detail : { ...detail, via };
};

/**
 * Deterministic: committing the same upload ids again is the same publish, which is what makes a retry safe. `canonical` is the
 * key of the row the publish fills: the version's, or `<version>+<build>` for a build added to a published version.
 */
export const publishIdFor = (name: string, canonical: string, uploadIds: readonly string[]) =>
  `pub_${createHash('sha256')
    .update([name, canonical, ...[...uploadIds].sort()].join('\0'))
    .digest('hex')
    .slice(0, 32)}`;

/**
 * begin-upload, commit and status of a publish (spec/api/openapi.yaml: beginUpload, commitPublish,
 * getPublishStatus). Authentication and the scope check happen in the route; everything the registry decides
 * happens here, on ports, so the same code runs in memory in the tests and on AWS.
 */
export class PublishService {
  private readonly now: () => Date;
  private readonly newId: () => string;
  constructor(private readonly d: PublishServiceDeps) {
    this.now = d.now ?? (() => new Date());
    this.newId = d.newId ?? (() => randomBytes(16).toString('hex'));
  }

  // --- begin ----------------------------------------------------------------------------------------------

  async begin(p: Principal, name: string, version: string, body: unknown): Promise<BeginResult> {
    const canonical = this.checkTarget(name, version);
    const req = this.parseBegin(name, version, body);
    const owner = await this.requireOwner(p, name);
    await this.rateLimit(p);
    const versions = await this.d.registry.listVersions(name);
    this.checkQuota(name, req.size, versions);
    // The row this upload fills: the version's, or the row of one more build when the version is already published.
    const rowKey = this.rowKeyFor(name, version, canonical, req, versions);
    await this.reserve(p, owner, name, version, rowKey, req.sha256);

    const now = this.now();
    const uploadId = `upl_${this.newId()}`;
    const key = `quarantine/${uploadId}/${req.filename}`;
    const urlExpires = new Date(now.getTime() + this.d.config.uploadUrlTtlSeconds * 1000);
    const rec: UploadRecord = {
      upload_id: uploadId,
      name,
      version,
      canonical: rowKey,
      subdir: req.subdir,
      filename: req.filename,
      sha256: req.sha256,
      size: req.size,
      key,
      actor: actorOf(p),
      ...viaField(p),
      created_at: now.toISOString(),
      url_expires_at: urlExpires.toISOString(),
      expires_at: Math.floor(now.getTime() / 1000) + this.d.config.uploadRecordTtlSeconds,
    };
    await this.d.publishes.putUpload(rec);
    const signed = this.d.presigner.presignPut(key, {
      size: req.size,
      sha256: req.sha256,
      expiresInSeconds: this.d.config.uploadUrlTtlSeconds,
      now,
    });
    return { upload_id: uploadId, put_url: signed.url, put_headers: signed.headers, expires_at: urlExpires.toISOString() };
  }

  private checkTarget(name: string, version: string): string {
    if (!NAME_PATTERN.test(name) && splitFullName(name) === undefined) throw new RegistryError('invalid_name', `'${name}' is not a valid package name.`, { name });
    return canonicalVersion(version); // throws invalid_version
  }

  private parseBegin(name: string, version: string, body: unknown) {
    return parseFileFacts(this.d.config, name, version, body);
  }

  private requireOwner(p: Principal, name: string): Promise<string> {
    return requireOwner(this.d.registry, p, name, this.d.namespaces);
  }

  private async rateLimit(p: Principal): Promise<void> {
    const now = this.now();
    const day = dayOf(now);
    const midnight = Date.parse(`${day}T00:00:00Z`) + 86_400_000;
    const retryAfter = Math.max(1, Math.ceil((midnight - now.getTime()) / 1000));
    const expiresAt = Math.floor(midnight / 1000) + 86_400;
    const hits: Array<[string, number]> = [[`rl#t#${p.token_id}#${day}`, this.d.config.ratePerTokenPerDay]];
    if (p.github_id !== undefined) hits.unshift([`rl#u#${p.github_id}#${day}`, this.d.config.ratePerAccountPerDay]);
    for (const [key, limit] of hits) {
      if (!(await this.d.publishes.hit(key, limit, expiresAt)).ok) {
        throw new PublishError('rate_limited', 'Too many requests.', { retry_after: String(retryAfter) }, retryAfter);
      }
    }
  }

  /**
   * Bytes of the package's live files plus this one must fit the project total. Tombstoned bytes are gone and do
   * not count; nothing is ever deleted to make room (the CEO's rule), so a full project simply refuses new
   * publishes. The error is `limit_exceeded` (403): the project is full, whatever the size of this file, which is
   * not what `payload_too_large` (the per-file cap) says.
   */
  private checkQuota(name: string, size: number, versions: readonly VersionRecord[]): void {
    const used = liveBytes(versions);
    const quota = this.d.config.projectQuotaBytes;
    if (used + size > quota) {
      const remaining = String(Math.max(0, quota - used));
      throw new PublishError(
        'limit_exceeded',
        `Adding this file would put '${name}' over its storage limit of ${quota} bytes; ${remaining} bytes are left.`,
        { name, limit: String(quota), remaining },
      );
    }
  }

  /**
   * The key of the row an upload fills. A version that is not published (no row, a pending one, a yanked or taken-down
   * one) is filled as a whole, under its own key: `reserve` creates or joins the row, or refuses a number that is taken.
   * A version that is published (as a reader sees it, builds folded in) and was published by a single takes one more build, never a replaced one: the
   * file's build must be one the version does not have, and the upload then fills the row of that build,
   * `<version>+<build>`.
   */
  private rowKeyFor(name: string, version: string, canonical: string, file: { subdir: string; filename: string }, versions: readonly VersionRecord[]): string {
    const base = versions.find((v) => v.canonical === canonical);
    // A version a group holds is the group's, whatever it reads: `reserve` refuses it like any other number a single does not take.
    if (base?.state !== 'published' || base.group_id !== undefined) return canonical;
    const build = buildOfFile(name, version, file.filename)!; // parseFileFacts checked the name
    const have = buildsOf(base).find((b) => b.build === build);
    if (have !== undefined) throw versionExists(name, version, have.files[0]!.sha256);
    return buildRowKey(canonical, build);
  }

  /** Create the pending row (a reserved number, or a reserved build of a published version), or join one that nobody has committed yet. */
  private async reserve(p: Principal, handle: string, name: string, version: string, canonical: string, sha256: string) {
    const now = this.now().toISOString();
    const rec: VersionRecord = {
      name,
      version,
      canonical,
      build: '',
      state: 'pending',
      published_at: now,
      published_by: handle,
      requires_mojo: '',
      deps: [],
      native: [],
      files: [],
      // Until commit, the sha256 of the first declared file: it is what version_exists reports for this number.
      manifest_sha256: sha256,
      rev: 0,
    };
    const { build } = splitRowKey(canonical);
    const detail = build === undefined ? detailVia(p) : { ...detailVia(p), build };
    const audit = { name, ts: now, id: `a_${this.newId()}`, actor: actorOf(p), action: 'publish_begin', version, ...(detail ? { detail } : {}) };
    try {
      await this.d.registry.createVersion(rec, audit);
      return;
    } catch (err) {
      if (!(err instanceof RegistryError) || err.code !== 'version_exists') throw err;
    }
    // The number exists. A pending one that no commit has taken is still only a reservation: join it.
    const current = await this.d.registry.getVersion(name, canonical);
    if (!current) throw versionExists(name, version, sha256);
    // A number held by a group is the group's: whether it has committed (the row reads `published`) or not (it reads
    // `pending`), a single publish does not join it. The one exception is a group that is dead: its number is free, and
    // the single takes it over (a compare-and-set on the row, so a group or another single that got there first wins).
    if (current.group_id !== undefined) {
      if (current.state === 'pending' && (await this.adoptFromDeadGroup(current, rec, audit))) return;
      throw versionExists(name, version, current.files[0]?.sha256 ?? current.manifest_sha256);
    }
    if (current.state !== 'pending' || (await this.d.publishes.versionHolder(name, canonical)) !== undefined) {
      throw versionExists(name, version, current.files[0]?.sha256 ?? current.manifest_sha256);
    }
  }

  /**
   * Take the number a dead group's row holds for this single publish. False (nothing written) when there is no group
   * store, the row has no header (hidden, and not adoptable), the group is not dead, or the row changed first.
   */
  private async adoptFromDeadGroup(current: VersionRecord, rec: VersionRecord, audit: AuditEntry): Promise<boolean> {
    const groups = this.d.groups;
    if (!groups || current.group_id === undefined) return false;
    const gid = current.group_id;
    const header = await groups.getGroup(gid);
    // A row with no header is free only when its own free_after has passed (a dead group's header was removed by the table's TTL).
    const now = this.now();
    if (!header) {
      if (!orphanFree(current, now)) return false;
      const out = await groups.adoptSingle(rec, { ...audit, action: 'publish_adopt', detail: { group_id: gid } }, (cur) => cur.group_id === gid && orphanFree(cur, this.now()));
      return out.outcome === 'created' || out.outcome === 'adopted';
    }
    if (!isDead((await expireIfDue(groups, header, now)).status)) return false;
    const out = await groups.adoptSingle(rec, { ...audit, action: 'publish_adopt', detail: { group_id: gid } }, (cur) => cur.group_id === gid);
    return out.outcome === 'created' || out.outcome === 'adopted';
  }

  // --- commit ---------------------------------------------------------------------------------------------

  async commit(p: Principal, name: string, version: string, body: unknown): Promise<CommitResult> {
    const canonical = this.checkTarget(name, version);
    const req = parseCommit(body);
    const handle = await this.requireOwner(p, name);
    const actor = actorOf(p);
    // The row the uploads fill (begin chose it): the version's, or `<version>+<build>` for a build added to a published
    // version. It is read off the first upload; an unknown or foreign one leaves the version's own key, and the checks below refuse it.
    const first = await this.d.publishes.getUpload(req.upload_ids[0]!);
    const rowKey = first !== undefined && first.name === name && first.version === version ? first.canonical : canonical;
    const publishId = publishIdFor(name, rowKey, req.upload_ids);
    const accepted = { publish_id: publishId, status_url: `/api/${splitFullName(name) ? 'v2' : 'v1'}/publishes/${publishId}` };

    // The same upload ids again resume the publish already made (and send the message again if it never left).
    const existing = await this.d.publishes.getPublish(publishId);
    if (existing && existing.actor === actor) {
      // The value is written once with the version: a repeat that states another one is not the same request.
      if (existing.source_commit !== req.source_commit) throw versionExists(name, version, existing.files[0]?.sha256 ?? existing.manifest_sha256 ?? '');
      if (existing.status === 'pending') await this.enqueue(existing);
      return accepted;
    }

    const uploads: UploadRecord[] = [];
    for (const id of req.upload_ids) {
      const u = await this.d.publishes.getUpload(id);
      if (!u || u.actor !== actor || u.name !== name || u.version !== version) {
        throw uploadInvalid('an upload belongs to another caller, package or version, or is unknown');
      }
      if (u.used_by !== undefined && u.used_by !== publishId) {
        throw new PublishError('upload_used', `The upload '${id}' was already used.`, { upload_id: id });
      }
      // A publish fills one row: files of two builds of a published version were begun for two build rows.
      if (u.canonical !== rowKey) throw invalidRequest('the uploads are not for one version row: a build added to a published version is one build per publish');
      const stat = await this.d.objects.head(u.key);
      if (!stat || stat.size !== u.size) throw uploadInvalid('a file was not uploaded');
      uploads.push(u);
    }
    const seen = new Set<string>();
    for (const u of uploads) {
      const k = `${u.subdir}/${u.filename}`;
      if (seen.has(k)) throw invalidRequest('two uploads name the same file');
      seen.add(k);
    }

    const v = await this.d.registry.getVersion(name, rowKey);
    if (!v) throw new RegistryError('version_not_found', `'${name}' has no version '${version}'.`, { name, version });
    // A group's number is the group's: a single commit does not take it, whatever state it reads.
    if (v.state !== 'pending' || v.group_id !== undefined) throw versionExists(name, version, v.files[0]?.sha256 ?? v.manifest_sha256);
    if (isBuildRow({ canonical: rowKey })) await this.checkAdd(name, version, canonical, req.manifest_sha256, uploads[0]!.sha256);
    const holder = await this.d.publishes.claimVersion(name, rowKey, publishId);
    if (holder !== publishId) {
      const other = await this.d.publishes.getPublish(holder);
      throw versionExists(name, version, other?.files[0]?.sha256 ?? uploads[0]!.sha256);
    }
    for (const u of uploads) {
      if (!(await this.d.publishes.useUpload(u.upload_id, publishId))) {
        throw new PublishError('upload_used', `The upload '${u.upload_id}' was already used.`, { upload_id: u.upload_id });
      }
    }

    const now = this.now().toISOString();
    const rec = await this.d.publishes.createPublish({
      publish_id: publishId,
      name,
      version,
      canonical: rowKey,
      actor,
      ...viaField(p),
      published_by: handle,
      status: 'pending',
      ...(req.manifest_sha256 !== undefined ? { manifest_sha256: req.manifest_sha256 } : {}),
      ...(Object.keys(req.display).length > 0 ? { display: req.display } : {}),
      ...(req.source_commit !== undefined ? { source_commit: req.source_commit } : {}),
      files: uploads.map((u) => ({ upload_id: u.upload_id, subdir: u.subdir, filename: u.filename, sha256: u.sha256, size: u.size, key: u.key })),
      remaining_subdirs: [],
      created_at: now,
      updated_at: now,
      rev: 0,
    });
    await this.enqueue(rec);
    return accepted;
  }

  /**
   * A build added to a version is claimed only for a version that is still published (a yanked or taken-down one takes no
   * more files), and, when the commit declares the manifest, only if it is the version's: a commit for another source is
   * refused here, before the build is claimed, so that the build stays free for the right one.
   */
  private async checkAdd(name: string, version: string, canonical: string, declared: string | undefined, uploadSha: string): Promise<void> {
    const base = (await this.d.registry.listVersions(name)).find((v) => v.canonical === canonical);
    if (base?.state !== 'published') throw versionExists(name, version, base?.manifest_sha256 ?? uploadSha);
    if (declared !== undefined && declared !== base.manifest_sha256) throw versionExists(name, version, base.manifest_sha256);
  }

  private async enqueue(rec: PublishRecord): Promise<void> {
    const msg: ValidateMessage = { type: 'validate', publish_id: rec.publish_id };
    // One group per package: its publishes are validated one at a time, in order, so the project total is exact.
    await this.d.validateQueue.send({ body: JSON.stringify(msg), groupId: rec.name, dedupId: rec.publish_id });
  }

  // --- yank -----------------------------------------------------------------------------------------------

  /**
   * setYanked: yank (with a reason) or unyank a version, then ask the index writer to rewrite every repodata directory
   * (src/channel-paths.ts) the version has files in, so repodata `packages.conda` and `removed` follow the state, and the package's
   * sparse-index file (a yank queues it at once; an unyank chains it after the last subdir, see IndexMessage.then). The state change comes first
   * (it is the truth); the messages come after it, and they are sent again on a repeat of the same request, so a
   * crash between the two leaves a state that the next identical request repairs. A repeat of a change already made
   * is a no-op for the record and still queues the rebuild (the FIFO dedup id is the record's revision, so a quick
   * double send is one rebuild, and a later one is a harmless second).
   */
  async setYanked(p: Principal, name: string, version: string, body: unknown): Promise<YankResult> {
    this.checkTarget(name, version);
    const req = parseYank(body);
    const queue = this.d.indexQueue;
    if (!queue) throw new PublishError('unavailable', 'The registry is temporarily unavailable.');
    const handle = await this.requireOwner(p, name);
    const existing = await this.d.registry.getVersion(name, version);
    if (!existing) throw new RegistryError('version_not_found', `'${name}' has no version '${version}'.`, { name, version });
    const now = this.now().toISOString();
    const audit = {
      name,
      ts: now,
      id: `a_${this.newId()}`,
      actor: actorOf(p),
      action: req.yanked ? 'yank' : 'unyank',
      version,
      detail: detailVia(p, { by: handle, ...(req.yanked ? { reason: req.reason } : {}) }),
    };
    const after = await this.d.registry.updateVersion(name, version, req.yanked ? { type: 'yank', reason: req.reason } : { type: 'unyank' }, audit);
    // The version as a reader sees it: the files of every build, the ones added later included.
    const versions = await this.d.registry.listVersions(name);
    const subdirs = repodataDirsOf(name, versions.find((v) => v.canonical === after.canonical)!.files.map((f) => f.subdir));
    const rev = packageRev(versions);
    if (!req.yanked && subdirs.length > 0) {
      // Unyank: the sparse index must not say `published` before repodata lists the file (the CLI fails closed on
      // that). One chain, one subdir at a time; the last repodata job sends the `index_pkg`.
      const first: IndexMessage = { type: 'index', subdir: subdirs[0]!, then: { name, rev, next: subdirs.slice(1) } };
      await queue.send({ body: JSON.stringify(first), groupId: subdirs[0]!, dedupId: `rebuild:${after.canonical}:${name}:${after.rev}:${subdirs[0]}` });
      return this.yankResult(after);
    }
    for (const subdir of subdirs) {
      const msg: IndexMessage = { type: 'index', subdir };
      await queue.send({ body: JSON.stringify(msg), groupId: subdir, dedupId: `rebuild:${after.canonical}:${name}:${after.rev}:${subdir}` });
    }
    // Yank is the safe direction (an index that says `yanked` while repodata still lists the file is not picked by
    // the CLI), so the index file is asked for at once.
    await sendIndexPkg({ registry: this.d.registry, indexQueue: queue }, { name, rev });
    return this.yankResult(after);
  }

  private yankResult(after: VersionRecord): YankResult {
    return {
      version: after.version,
      state: after.state,
      published_at: after.published_at,
      ...(after.state === 'yanked' && after.yank_reason !== undefined ? { yank_reason: after.yank_reason } : {}),
    };
  }

  // --- status ---------------------------------------------------------------------------------------------

  async status(p: Principal, publishId: string): Promise<PublishStatusBody> {
    // The table also holds the commit locks, the rate counters and the groups' items under other prefixes: only a
    // publish record is a publish, so nothing else is ever read or returned through this route.
    const rec = publishId.startsWith('pub_') ? await this.d.publishes.getPublish(publishId) : undefined;
    if (!rec || rec.actor !== actorOf(p)) throw new PublishError('publish_not_found', 'There is no such publish.');
    return {
      publish_id: rec.publish_id,
      name: rec.name,
      version: rec.version,
      status: rec.status,
      ...(rec.status === 'rejected' ? { rejection_code: rec.rejection_code, message: rec.message } : {}),
      ...(rec.warnings && rec.warnings.length > 0 ? { warnings: rec.warnings } : {}),
    };
  }
}

/** The facts one file of a version declares (begin-upload's body, and a member's file in a group): checked against the limits and the file name rule. */
export function parseFileFacts(config: PublishConfig, name: string, version: string, body: unknown) {
  if (!isObject(body)) throw invalidRequest('the body is not a JSON object');
  const { subdir, filename, sha256, size } = body;
  if (typeof subdir !== 'string' || !SUBDIRS_V1.includes(subdir)) throw invalidRequest("'subdir' is not a known subdir");
  if (typeof filename !== 'string' || !SAFE_FILENAME.test(filename)) throw invalidRequest("'filename' must be a plain file name");
  if (typeof sha256 !== 'string' || !SHA256.test(sha256)) throw invalidRequest("'sha256' is 64 lowercase hex digits");
  if (typeof size !== 'number' || !Number.isSafeInteger(size) || size < 1) throw invalidRequest("'size' must be a positive integer");
  if (size > config.maxArchiveBytes) {
    throw new PublishError('payload_too_large', 'The file is larger than the limit.', { limit: String(config.maxArchiveBytes) });
  }
  const prefix = `${condaNameOf(name)}-${version}-`;
  const build = filename.startsWith(prefix) && filename.endsWith('.conda') ? filename.slice(prefix.length, -'.conda'.length) : undefined;
  if (build === undefined || !BUILD.test(build)) {
    throw uploadInvalid(`the file name must be ${prefix}<build>.conda`);
  }
  return { subdir, filename, sha256, size };
}

/**
 * The package must exist (claimed). An account token must belong to a current owner (a token outlives an ownership change).
 * A CI token must name the package's `ci_owner` (a CI-owned package has no account owners).
 *
 * A full name (`<namespace>/<name>`, `/api/v2`) has no owners: its namespace is the owner. An account's token (a session, an
 * API token, or a CI token that acts for an account) must be allowed to write there now (`access.require`, a live check every
 * time); a CI token minted for a namespace's publisher (`ci_namespace`) must name this namespace. The package must exist.
 * Answers the handle recorded as `published_by`: the account's handle, or `ci`.
 */
export async function requireOwner(registry: Store, p: Principal, name: string, access?: NamespaceAccess): Promise<string> {
  const full = splitFullName(name);
  if (full) return requireWriter(registry, p, name, full.namespace, access);
  const pkg = await registry.getPackage(name);
  if (!pkg) throw new PublishError('package_not_found', `There is no package '${name}'.`, { name });
  if (p.github_id !== undefined) {
    const owner = (await registry.listOwners(name)).find((o) => o.github_id === p.github_id);
    if (!owner) throw new PublishError('not_owner', `You are not an owner of '${name}'.`, { name });
    return owner.handle;
  }
  const notOwner = () => new PublishError('not_owner', `You are not an owner of '${name}'.`, { name });
  if (p.kind !== 'oidc' || p.ci_namespace !== undefined) throw notOwner();
  if (p.ci_owner !== undefined) {
    // A configured CI publisher's token acts as one identity and owns only the packages that name it.
    if (pkg.ci_owner !== p.ci_owner) throw notOwner();
    return p.ci_owner;
  }
  // A token minted for a package's registered trusted publisher: it belongs to accounts, never to a CI identity's package.
  if (pkg.ci_owner !== undefined) throw notOwner();
  return 'ci';
}

async function requireWriter(registry: Store, p: Principal, name: string, namespace: string, access: NamespaceAccess | undefined): Promise<string> {
  const unavailable = () => new AuthError('unavailable', 'The registry is temporarily unavailable.');
  let handle = 'ci';
  if (p.github_id !== undefined) {
    if (!access) throw unavailable();
    await access.require(namespace, p.github_id);
    handle = await access.handleOf(p.github_id);
  } else if (p.kind === 'oidc' && p.ci_namespace !== undefined) {
    if (p.ci_namespace !== namespace) throw new NamespaceError('not_namespace_member', `You cannot write in '${namespace}'.`, { namespace });
    if (!access) throw unavailable();
    await access.requireCi(namespace);
  } else {
    throw new PublishError('not_owner', `You are not an owner of '${name}'.`, { name });
  }
  if (!(await registry.getPackage(name))) throw new PublishError('package_not_found', `There is no package '${name}'.`, { name });
  return handle;
}

/** Bytes of the files that are still on the channel: published and yanked versions (a tombstone's bytes are gone). */
export function liveBytes(versions: readonly VersionRecord[]): number {
  let n = 0;
  for (const v of versions) if (v.state === 'published' || v.state === 'yanked') for (const f of v.files) n += f.size;
  return n;
}

export function parseYank(body: unknown): { yanked: true; reason: string } | { yanked: false } {
  if (!isObject(body)) throw invalidRequest('the body is not a JSON object');
  const { yanked, reason } = body;
  if (typeof yanked !== 'boolean') throw invalidRequest("'yanked' must be a boolean");
  if (reason !== undefined && (typeof reason !== 'string' || reason.length > 280)) throw invalidRequest("'reason' is a string of at most 280 characters");
  if (!yanked) return { yanked: false };
  if (typeof reason !== 'string' || reason.length === 0) throw invalidRequest("yanking needs a 'reason'");
  return { yanked: true, reason };
}

function parseCommit(body: unknown): { upload_ids: string[]; manifest_sha256?: string; display: DisplayMeta; source_commit?: string } {
  if (!isObject(body)) throw invalidRequest('the body is not a JSON object');
  const { upload_ids, manifest_sha256 } = body;
  if (!Array.isArray(upload_ids) || upload_ids.length < 1 || upload_ids.length > 20) throw invalidRequest("'upload_ids' holds 1 to 20 ids");
  if (!upload_ids.every((x) => typeof x === 'string' && x.length >= 1 && x.length <= 128)) throw invalidRequest('each upload id must be a string');
  if (new Set(upload_ids).size !== upload_ids.length) throw invalidRequest("'upload_ids' repeats an id");
  // Optional: given, it is checked against the archive's manifest; absent, the registry uses the hash it computes itself.
  if (manifest_sha256 !== undefined && (typeof manifest_sha256 !== 'string' || !SHA256.test(manifest_sha256))) throw invalidRequest("'manifest_sha256' is 64 lowercase hex digits");
  const source = parseSourceCommit(body);
  return { upload_ids: upload_ids as string[], ...(manifest_sha256 !== undefined ? { manifest_sha256 } : {}), display: parseDisplay(body), ...(source !== undefined ? { source_commit: source } : {}) };
}
