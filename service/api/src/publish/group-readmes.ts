import { createHash } from 'node:crypto';
import { README_MAX_BYTES } from '../types';
import type { CommitInput } from '../group-store';
import type { PublishConfig } from './config';
import { parseDisplay } from './display';
import { invalidRequest, uploadInvalid } from './errors';
import { quarantineKeyFor, readmeUploadIdFor } from './group-keys';
import type { ObjectStore, Presigner } from './ports';

/**
 * A member's readme as an uploaded object. A readme can be 64 KiB, so a group's readmes together can pass the size of a request
 * the registry's function takes. The create request therefore declares a member's readme by digest and size (`ReadmeRef`), the
 * answer gives an upload URL pinned to both, and the commit names the object again; the commit then reads it and goes on
 * exactly as if the text had been in the request.
 */

export interface ReadmeRef {
  sha256: string;
  size: number;
}

/** The upload of a member's readme, as the create answer carries it. */
export interface GroupReadmeBody {
  sha256: string;
  size: number;
  upload_id: string;
  /** The object is already in quarantine at that size: nothing to upload. */
  uploaded: boolean;
  put_url?: string;
  put_headers?: Record<string, string>;
  expires_at?: string;
}

const SHA256 = /^[0-9a-f]{64}$/;
const BATCH = 16;

/** `v` as a ReadmeRef, or undefined when it is not one: an object of exactly a lowercase hex sha256 and an integer size of 1 to README_MAX_BYTES. */
function asRef(v: unknown): ReadmeRef | undefined {
  if (typeof v !== 'object' || v === null || Array.isArray(v)) return undefined;
  const { sha256, size } = v as Record<string, unknown>;
  if (typeof sha256 !== 'string' || !SHA256.test(sha256)) return undefined;
  if (typeof size !== 'number' || !Number.isInteger(size) || size < 1 || size > README_MAX_BYTES) return undefined;
  return { sha256, size };
}

/** The readme a create request declares for a member, or undefined when it declares none. Throws invalid_request naming the member. */
export function parseReadmeDeclaration(name: string, v: unknown): ReadmeRef | undefined {
  if (v === undefined) return undefined;
  const ref = asRef(v);
  if (!ref) throw invalidRequest(`'readme' of '${name}' is {"sha256", "size"} of a readme of 1 to ${README_MAX_BYTES} bytes`);
  return ref;
}

/** The ReadmeRef a commit request names for a member whose `readme` is not a string. Throws invalid_request naming the member. */
export function parseReadmeNamed(name: string, v: unknown): ReadmeRef {
  const ref = asRef(v);
  if (!ref) throw invalidRequest(`'readme' of '${name}' is a string or {"sha256", "size"} of a readme of 1 to ${README_MAX_BYTES} bytes`);
  return ref;
}

/**
 * The upload of a member's readme: where it goes in quarantine, and a URL pinned to its digest and size unless the bytes are
 * already there. No record is kept; the key is derived, and the quarantine's lifecycle removes the object.
 */
export async function readmeUpload(
  d: { config: PublishConfig; objects: Pick<ObjectStore, 'head'>; presigner: Presigner; now: Date },
  gid: string,
  m: { name: string; canonical: string; readme?: ReadmeRef },
): Promise<GroupReadmeBody | undefined> {
  if (!m.readme) return undefined;
  const { sha256, size } = m.readme;
  const uploadId = readmeUploadIdFor(gid, m, sha256);
  const key = quarantineKeyFor(uploadId, 'README.md');
  const base = { sha256, size, upload_id: uploadId };
  const stat = await d.objects.head(key);
  if (stat && stat.size === size) return { ...base, uploaded: true };
  const ttl = d.config.uploadUrlTtlSeconds;
  const signed = d.presigner.presignPut(key, { size, sha256, expiresInSeconds: ttl, now: d.now });
  return { ...base, uploaded: false, put_url: signed.url, put_headers: signed.headers, expires_at: new Date(d.now.getTime() + ttl * 1000).toISOString() };
}

/** A commit member that names its readme by digest: the member as the request wrote it, and where it stands in the group's member order. */
export interface ReadmeNamed {
  index: number;
  ref: ReadmeRef;
  member: Record<string, unknown>;
}

/**
 * Read the readmes the commit names and complete the inputs: each member's input becomes the one the inline form stores, field
 * for field. Throws upload_invalid for an object that is absent or is not the one named, invalid_request for one that is not UTF-8.
 */
export async function completeReadmes(
  objects: Pick<ObjectStore, 'get'>,
  gid: string,
  members: ReadonlyArray<{ name: string; canonical: string }>,
  inputs: readonly CommitInput[],
  named: readonly ReadmeNamed[],
): Promise<CommitInput[]> {
  const out = [...inputs];
  const decoder = new TextDecoder('utf-8', { fatal: true, ignoreBOM: true });
  for (let i = 0; i < named.length; i += BATCH) {
    const batch = named.slice(i, i + BATCH);
    const bodies = await Promise.all(batch.map((n) => objects.get(quarantineKeyFor(readmeUploadIdFor(gid, members[n.index]!, n.ref.sha256), 'README.md'))));
    for (const [j, n] of batch.entries()) {
      const who = out[n.index]!.name;
      const bytes = bodies[j];
      if (!bytes) throw uploadInvalid(`the readme of '${who}' (sha256 ${n.ref.sha256}) was not uploaded`);
      if (bytes.length !== n.ref.size || createHash('sha256').update(bytes).digest('hex') !== n.ref.sha256) {
        throw uploadInvalid(`the readme of '${who}' in storage is not the one named (sha256 ${n.ref.sha256}, ${n.ref.size} bytes)`);
      }
      let text: string;
      try {
        text = decoder.decode(bytes);
      } catch {
        throw invalidRequest(`the readme of '${who}' is not UTF-8 text`);
      }
      const { name, manifest_sha256, source_commit } = out[n.index]!;
      const display = parseDisplay({ ...n.member, readme: text });
      out[n.index] = { name, ...(manifest_sha256 !== undefined ? { manifest_sha256 } : {}), display, ...(source_commit !== undefined ? { source_commit } : {}) };
    }
  }
  return out;
}
