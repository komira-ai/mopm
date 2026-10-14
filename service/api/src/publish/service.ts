import { createHash, randomBytes } from 'node:crypto';
import type { Principal } from '../auth';
import { NAME_PATTERN } from '../auth';
import { RegistryError, versionExists } from '../errors';
import type { Store } from '../store';
import type { VersionRecord } from '../types';
import { SUBDIRS_V1 } from '../types';
import { canonicalVersion } from '../version';
import type { PublishConfig } from './config';
import { invalidRequest, PublishError, uploadInvalid } from './errors';
import type { ObjectStore, Presigner, PublishStore, Queue } from './ports';
import type { Actor, PublishRecord, UploadRecord, ValidateMessage } from './types';

export interface PublishServiceDeps {
  registry: Store;
  publishes: PublishStore;
  /** Only `head` is used here: commit checks that the bytes arrived. */
  objects: Pick<ObjectStore, 'head'>;
  presigner: Presigner;
  validateQueue: Queue;
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
export interface PublishStatusBody {
  publish_id: string;
  name: string;
  version: string;
  status: PublishRecord['status'];
  rejection_code?: string;
  message?: string;
}

const SHA256 = /^[0-9a-f]{64}$/;
const BUILD = /^mojo[0-9]+(?:\.[0-9]+)*_0$/;
const SAFE_FILENAME = /^[A-Za-z0-9][A-Za-z0-9._+-]{0,254}$/;
const dayOf = (d: Date) => d.toISOString().slice(0, 10);
const isObject = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);

export const actorOf = (p: Principal): Actor => (p.github_id !== undefined ? `u:${p.github_id}` : `ci:${p.token_id}`);

/** Deterministic: committing the same upload ids again is the same publish, which is what makes a retry safe. */
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
    await this.checkQuota(name, req.size);
    await this.reserve(p, owner, name, version, canonical, req.sha256);

    const now = this.now();
    const uploadId = `upl_${this.newId()}`;
    const key = `quarantine/${uploadId}/${req.filename}`;
    const urlExpires = new Date(now.getTime() + this.d.config.uploadUrlTtlSeconds * 1000);
    const rec: UploadRecord = {
      upload_id: uploadId,
      name,
      version,
      canonical,
      subdir: req.subdir,
      filename: req.filename,
      sha256: req.sha256,
      size: req.size,
      key,
      actor: actorOf(p),
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
    if (!NAME_PATTERN.test(name)) throw new RegistryError('invalid_name', `'${name}' is not a valid package name.`, { name });
    return canonicalVersion(version); // throws invalid_version
  }

  private parseBegin(name: string, version: string, body: unknown) {
    if (!isObject(body)) throw invalidRequest('the body is not a JSON object');
    const { subdir, filename, sha256, size } = body;
    if (typeof subdir !== 'string' || !SUBDIRS_V1.includes(subdir)) throw invalidRequest("'subdir' is not a known subdir");
    if (typeof filename !== 'string' || !SAFE_FILENAME.test(filename)) throw invalidRequest("'filename' must be a plain file name");
    if (typeof sha256 !== 'string' || !SHA256.test(sha256)) throw invalidRequest("'sha256' is 64 lowercase hex digits");
    if (typeof size !== 'number' || !Number.isSafeInteger(size) || size < 1) throw invalidRequest("'size' must be a positive integer");
    if (size > this.d.config.maxArchiveBytes) {
      throw new PublishError('payload_too_large', 'The file is larger than the limit.', { limit: String(this.d.config.maxArchiveBytes) });
    }
    const prefix = `mojo-${name}-${version}-`;
    const build = filename.startsWith(prefix) && filename.endsWith('.conda') ? filename.slice(prefix.length, -'.conda'.length) : undefined;
    if (build === undefined || !BUILD.test(build)) {
      throw uploadInvalid(`the file name must be ${prefix}<build>.conda`);
    }
    return { subdir, filename, sha256, size };
  }

  /** The package must exist (claimed); an account token must belong to a current owner (a token outlives an ownership change). */
  private async requireOwner(p: Principal, name: string): Promise<string> {
    const pkg = await this.d.registry.getPackage(name);
    if (!pkg) throw new PublishError('package_not_found', `There is no package '${name}'.`, { name });
    if (p.github_id !== undefined) {
      const owner = (await this.d.registry.listOwners(name)).find((o) => o.github_id === p.github_id);
      if (!owner) throw new PublishError('not_owner', `You are not an owner of '${name}'.`, { name });
      return owner.handle;
    }
    // A CI identity token was issued for exactly this package and version by a matching trusted publisher.
    return 'ci';
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
   * publishes. The error reuses payload_too_large with the room left as its limit; the contract has no separate code.
   */
  private async checkQuota(name: string, size: number): Promise<void> {
    const used = liveBytes(await this.d.registry.listVersions(name));
    const quota = this.d.config.projectQuotaBytes;
    if (used + size > quota) {
      throw new PublishError('payload_too_large', 'The file is larger than the limit.', { limit: String(Math.max(0, quota - used)) });
    }
  }

  /** Create the pending version (a reserved number), or join one that nobody has committed yet. */
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
    const audit = { name, ts: now, id: `a_${this.newId()}`, actor: actorOf(p), action: 'publish_begin', version };
    try {
      await this.d.registry.createVersion(rec, audit);
      return;
    } catch (err) {
      if (!(err instanceof RegistryError) || err.code !== 'version_exists') throw err;
    }
    // The number exists. A pending one that no commit has taken is still only a reservation: join it.
    const current = await this.d.registry.getVersion(name, version);
    if (!current) throw versionExists(name, version, sha256);
    if (current.state !== 'pending' || (await this.d.publishes.versionHolder(name, canonical)) !== undefined) {
      throw versionExists(name, version, current.files[0]?.sha256 ?? current.manifest_sha256);
    }
  }

  // --- commit ---------------------------------------------------------------------------------------------

  async commit(p: Principal, name: string, version: string, body: unknown): Promise<CommitResult> {
    const canonical = this.checkTarget(name, version);
    const req = parseCommit(body);
    const handle = await this.requireOwner(p, name);
    const actor = actorOf(p);
    const publishId = publishIdFor(name, canonical, req.upload_ids);
    const accepted = { publish_id: publishId, status_url: `/api/v1/publishes/${publishId}` };

    // The same upload ids again resume the publish already made (and send the message again if it never left).
    const existing = await this.d.publishes.getPublish(publishId);
    if (existing && existing.actor === actor) {
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

    const v = await this.d.registry.getVersion(name, version);
    if (!v) throw new RegistryError('version_not_found', `'${name}' has no version '${version}'.`, { name, version });
    if (v.state !== 'pending') throw versionExists(name, version, v.files[0]?.sha256 ?? v.manifest_sha256);
    const holder = await this.d.publishes.claimVersion(name, canonical, publishId);
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
      canonical,
      actor,
      published_by: handle,
      status: 'pending',
      manifest_sha256: req.manifest_sha256,
      files: uploads.map((u) => ({ upload_id: u.upload_id, subdir: u.subdir, filename: u.filename, sha256: u.sha256, size: u.size, key: u.key })),
      remaining_subdirs: [],
      created_at: now,
      updated_at: now,
      rev: 0,
    });
    await this.enqueue(rec);
    return accepted;
  }

  private async enqueue(rec: PublishRecord): Promise<void> {
    const msg: ValidateMessage = { type: 'validate', publish_id: rec.publish_id };
    // One group per package: its publishes are validated one at a time, in order, so the project total is exact.
    await this.d.validateQueue.send({ body: JSON.stringify(msg), groupId: rec.name, dedupId: rec.publish_id });
  }

  // --- status ---------------------------------------------------------------------------------------------

  async status(p: Principal, publishId: string): Promise<PublishStatusBody> {
    const rec = await this.d.publishes.getPublish(publishId);
    if (!rec || rec.actor !== actorOf(p)) throw new PublishError('publish_not_found', 'There is no such publish.');
    return {
      publish_id: rec.publish_id,
      name: rec.name,
      version: rec.version,
      status: rec.status,
      ...(rec.status === 'rejected' ? { rejection_code: rec.rejection_code, message: rec.message } : {}),
    };
  }
}

/** Bytes of the files that are still on the channel: published and yanked versions (a tombstone's bytes are gone). */
export function liveBytes(versions: readonly VersionRecord[]): number {
  let n = 0;
  for (const v of versions) if (v.state === 'published' || v.state === 'yanked') for (const f of v.files) n += f.size;
  return n;
}

function parseCommit(body: unknown): { upload_ids: string[]; manifest_sha256: string } {
  if (!isObject(body)) throw invalidRequest('the body is not a JSON object');
  const { upload_ids, manifest_sha256, readme } = body;
  if (!Array.isArray(upload_ids) || upload_ids.length < 1 || upload_ids.length > 20) throw invalidRequest("'upload_ids' holds 1 to 20 ids");
  if (!upload_ids.every((x) => typeof x === 'string' && x.length >= 1 && x.length <= 128)) throw invalidRequest('each upload id must be a string');
  if (new Set(upload_ids).size !== upload_ids.length) throw invalidRequest("'upload_ids' repeats an id");
  if (typeof manifest_sha256 !== 'string' || !SHA256.test(manifest_sha256)) throw invalidRequest("'manifest_sha256' is 64 lowercase hex digits");
  if (readme !== undefined && (typeof readme !== 'string' || readme.length > 524288)) {
    throw invalidRequest("'readme' is a string of at most 524288 characters");
  }
  return { upload_ids: upload_ids as string[], manifest_sha256 };
}
