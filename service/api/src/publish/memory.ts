import { createHash } from 'node:crypto';
import type { Invalidator, ObjectStore, PresignedPut, Presigner, PublishStore, Queue, QueueMessage } from './ports';
import type { PublishRecord, UploadRecord } from './types';

const copy = <T>(v: T): T => structuredClone(v);

export class MemoryPublishStore implements PublishStore {
  uploads = new Map<string, UploadRecord>();
  publishes = new Map<string, PublishRecord>();
  locks = new Map<string, string>();
  counters = new Map<string, number>();

  async putUpload(u: UploadRecord) {
    this.uploads.set(u.upload_id, copy(u));
  }
  async getUpload(id: string) {
    const u = this.uploads.get(id);
    return u && copy(u);
  }
  async useUpload(id: string, publishId: string) {
    const u = this.uploads.get(id);
    if (!u) return false;
    if (u.used_by !== undefined) return u.used_by === publishId;
    u.used_by = publishId;
    return true;
  }
  async claimVersion(name: string, canonical: string, publishId: string) {
    const k = `${name}\0${canonical}`;
    const held = this.locks.get(k);
    if (held !== undefined) return held;
    this.locks.set(k, publishId);
    return publishId;
  }
  async versionHolder(name: string, canonical: string) {
    return this.locks.get(`${name}\0${canonical}`);
  }
  async createPublish(rec: PublishRecord) {
    const have = this.publishes.get(rec.publish_id);
    if (have) return copy(have);
    this.publishes.set(rec.publish_id, copy(rec));
    return copy(rec);
  }
  async getPublish(id: string) {
    const p = this.publishes.get(id);
    return p && copy(p);
  }
  async updatePublish(id: string, fn: (cur: PublishRecord) => PublishRecord | undefined) {
    const cur = this.publishes.get(id);
    if (!cur) return undefined;
    const next = fn(copy(cur));
    if (next === undefined) return copy(cur);
    this.publishes.set(id, copy({ ...next, rev: cur.rev + 1 }));
    return copy(this.publishes.get(id)!);
  }
  async hit(key: string, limit: number) {
    const n = this.counters.get(key) ?? 0;
    if (n >= limit) return { ok: false, count: n };
    this.counters.set(key, n + 1);
    return { ok: true, count: n + 1 };
  }
}

export class MemoryObjectStore implements ObjectStore {
  objects = new Map<string, { body: Buffer; contentType: string; cacheControl?: string }>();
  log: string[] = [];
  async head(key: string) {
    const o = this.objects.get(key);
    return o ? { size: o.body.length } : undefined;
  }
  async get(key: string) {
    const o = this.objects.get(key);
    return o && Buffer.from(o.body);
  }
  async put(key: string, body: Buffer, opts: { contentType: string; cacheControl?: string; createOnly?: boolean }) {
    this.log.push(`put ${key}`);
    if (opts.createOnly && this.objects.has(key)) return 'exists' as const;
    this.objects.set(key, { body: Buffer.from(body), contentType: opts.contentType, cacheControl: opts.cacheControl });
    return 'created' as const;
  }
  async delete(key: string) {
    this.log.push(`delete ${key}`);
    this.objects.delete(key);
  }
  keys(prefix = ''): string[] {
    return [...this.objects.keys()].filter((k) => k.startsWith(prefix)).sort();
  }
}

/**
 * What S3 does with a presigned PUT, as far as the tests need: the bytes must have exactly the signed length and
 * the signed sha256, and the URL must not be expired. It reads back what presignPut returned.
 */
export class FakeS3Upload {
  constructor(private readonly store: MemoryObjectStore) {}
  async put(key: string, signed: PresignedPut, body: Buffer, now: Date, expiresAt: Date): Promise<'ok' | 'expired' | 'bad_length' | 'bad_checksum'> {
    if (now.getTime() > expiresAt.getTime()) return 'expired';
    if (String(body.length) !== signed.headers['content-length']) return 'bad_length';
    if (createHash('sha256').update(body).digest('base64') !== signed.headers['x-amz-checksum-sha256']) return 'bad_checksum';
    await this.store.put(key, body, { contentType: 'application/octet-stream' });
    return 'ok';
  }
}

export class MemoryPresigner implements Presigner {
  presignPut(key: string, o: { size: number; sha256: string; expiresInSeconds: number; now: Date }): PresignedPut {
    return {
      url: `https://bucket.invalid/${key}?expires=${o.expiresInSeconds}`,
      headers: { 'content-length': String(o.size), 'x-amz-checksum-sha256': Buffer.from(o.sha256, 'hex').toString('base64') },
    };
  }
}

export class MemoryQueue implements Queue {
  sent: QueueMessage[] = [];
  /** Dedup ids seen: FIFO drops a repeat within its window. */
  private seen = new Set<string>();
  async send(m: QueueMessage) {
    if (this.seen.has(m.dedupId)) return;
    this.seen.add(m.dedupId);
    this.sent.push({ ...m });
  }
  /** The next message, oldest first. */
  take(): QueueMessage | undefined {
    return this.sent.shift();
  }
}

export class MemoryInvalidator implements Invalidator {
  batches: Array<{ paths: string[]; reference: string }> = [];
  async invalidate(paths: string[], reference: string) {
    this.batches.push({ paths: [...paths], reference });
  }
}
