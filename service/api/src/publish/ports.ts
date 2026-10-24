import type { PublishRecord, UploadRecord } from './types';

/** The channel bucket: quarantine/, <subdir>/<file>.conda and <subdir>/repodata.json(.zst). */
export interface ObjectStore {
  /** Size of the object, or undefined when it is absent. */
  head(key: string): Promise<{ size: number } | undefined>;
  /** The bytes, or undefined when absent. */
  get(key: string): Promise<Buffer | undefined>;
  /** `createOnly` refuses to replace an existing object (S3 `If-None-Match: *`) and answers 'exists'. */
  put(key: string, body: Buffer, opts: { contentType: string; cacheControl?: string; createOnly?: boolean }): Promise<'created' | 'exists'>;
  delete(key: string): Promise<void>;
}

export interface PresignedPut {
  url: string;
  /** The caller must send these exactly: they are part of the signature. */
  headers: Record<string, string>;
}

/** A presigned PUT pinned to one exact length and sha256. Pure: no I/O. */
export interface Presigner {
  presignPut(key: string, o: { size: number; sha256: string; expiresInSeconds: number; now: Date }): PresignedPut;
}

export interface Invalidator {
  /** Paths start with `/`. The reference makes a retry of the same batch idempotent. */
  invalidate(paths: string[], reference: string): Promise<void>;
}

export interface QueueMessage {
  body: string;
  /** FIFO MessageGroupId: messages of one group are delivered one at a time, in order. */
  groupId: string;
  /** FIFO MessageDeduplicationId. */
  dedupId: string;
}
export interface Queue {
  send(m: QueueMessage): Promise<void>;
}

/** Whether new uploads are refused. Reads never consult it. */
export interface Flags {
  readOnly(): Promise<boolean>;
}

/**
 * Persistence of the publish pipeline: upload records, publish records, the per-version commit lock and the
 * rate counters. Every method is atomic (a conditional write in DynamoDB).
 */
export interface PublishStore {
  putUpload(u: UploadRecord): Promise<void>;
  getUpload(id: string): Promise<UploadRecord | undefined>;
  /** Mark the upload as taken by a publish. False when another publish took it; true again for the same one. */
  useUpload(id: string, publishId: string): Promise<boolean>;

  /** Create-once lock on (name, canonical version): the publish id that holds it (the caller's when it won). */
  claimVersion(name: string, canonical: string, publishId: string): Promise<string>;
  versionHolder(name: string, canonical: string): Promise<string | undefined>;

  /** Create-once. Returns the stored record: the argument when created, the existing one otherwise. */
  createPublish(rec: PublishRecord): Promise<PublishRecord>;
  getPublish(id: string): Promise<PublishRecord | undefined>;
  /**
   * Read, apply `fn`, write back only if nothing changed in between (retrying). `fn` returns the new record,
   * or undefined to leave it. Returns the record as it is afterwards, or undefined when there is none.
   */
  updatePublish(id: string, fn: (cur: PublishRecord) => PublishRecord | undefined): Promise<PublishRecord | undefined>;

  /**
   * Count `n` hits (one by default) on `key` unless that would take it past `limit`: then nothing is counted and `ok` is
   * false. `expiresAt` is epoch seconds (TTL cleanup). A group charges all its files at once with one `n`; the
   * counter is one item, so the charge is one conditional write, all or nothing.
   */
  hit(key: string, limit: number, expiresAt: number, n?: number): Promise<{ ok: boolean; count: number }>;
}
