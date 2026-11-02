import { GetCommand, PutCommand } from '@aws-sdk/lib-dynamodb';
import type { DocClient } from '../dynamo-store';
import type { ActorGroup, ActorGroups, PublishStore } from './ports';
import type { PublishRecord, UploadRecord } from './types';

/** Table names (service/infra/stacks/lib/config.ts: `mopm-<stage>-<table>`) the publish path uses. */
export interface PublishTables {
  uploads: string;
  publishes: string;
  config: string;
  tokens: string;
}
export const publishTablesFor = (stage: string): PublishTables => ({
  uploads: `mopm-${stage}-uploads`,
  publishes: `mopm-${stage}-publishes`,
  config: `mopm-${stage}-config`,
  tokens: `mopm-${stage}-tokens`,
});

const MAX_ATTEMPTS = 8;
/** A counter is hit by every begin of an account or token: a CLI uploading 20 files in parallel contends on it. */
const MAX_HIT_ATTEMPTS = 40;
type Item = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

/** The document client refuses undefined members; records may carry optional ones. */
const clean = <T>(v: T): T => JSON.parse(JSON.stringify(v)) as T;
const condFailed = (err: unknown) => (err as { name?: string })?.name === 'ConditionalCheckFailedException';

/**
 * DynamoDB adapter. Every mutation is a conditional PutItem (create-once, or compare-and-swap on `rev`), so the
 * role needs GetItem and PutItem only. `publishes` is keyed by `publish_id` and holds six kinds of row, told
 * apart by the key's prefix: `pub_...` publish records, `ver#<name>#<canonical>` commit locks, `rl#...` counters,
 * `grp#<id>` and `grpm#<id>`, a group's header and member list (written by the version store, src/group-store.ts), and
 * `grpa#<actor>`, the list of groups an actor has open.
 */
export class DynamoPublishStore implements PublishStore {
  constructor(
    private readonly doc: DocClient,
    private readonly tables: Pick<PublishTables, 'uploads' | 'publishes'>,
  ) {}

  private async get(table: string, keyAttr: string, key: string): Promise<Item | undefined> {
    const r = await this.doc.send(new GetCommand({ TableName: table, Key: { [keyAttr]: key }, ConsistentRead: true }));
    return r.Item as Item | undefined;
  }

  private async putIfAbsent(table: string, keyAttr: string, item: Item): Promise<boolean> {
    try {
      await this.doc.send(
        new PutCommand({
          TableName: table,
          Item: clean(item),
          ConditionExpression: 'attribute_not_exists(#k)',
          ExpressionAttributeNames: { '#k': keyAttr },
        }),
      );
      return true;
    } catch (err) {
      if (condFailed(err)) return false;
      throw err;
    }
  }

  /** Replace the item only if its `rev` is still `rev`. */
  private async swap(table: string, item: Item, rev: number): Promise<boolean> {
    try {
      await this.doc.send(
        new PutCommand({
          TableName: table,
          Item: clean(item),
          ConditionExpression: '#r = :r',
          ExpressionAttributeNames: { '#r': 'rev' },
          ExpressionAttributeValues: { ':r': rev },
        }),
      );
      return true;
    } catch (err) {
      if (condFailed(err)) return false;
      throw err;
    }
  }

  async putUpload(u: UploadRecord) {
    if (!(await this.putIfAbsent(this.tables.uploads, 'upload_id', u))) throw new Error(`upload ${u.upload_id} already exists`);
  }
  async getUpload(id: string) {
    return (await this.get(this.tables.uploads, 'upload_id', id)) as UploadRecord | undefined;
  }
  async useUpload(id: string, publishId: string): Promise<boolean> {
    for (let i = 0; i < MAX_ATTEMPTS; i++) {
      const cur = await this.get(this.tables.uploads, 'upload_id', id);
      if (!cur) return false;
      if (cur.used_by !== undefined) return cur.used_by === publishId;
      try {
        await this.doc.send(
          new PutCommand({
            TableName: this.tables.uploads,
            Item: clean({ ...cur, used_by: publishId }),
            ConditionExpression: 'attribute_not_exists(#u)',
            ExpressionAttributeNames: { '#u': 'used_by' },
          }),
        );
        return true;
      } catch (err) {
        if (!condFailed(err)) throw err;
      }
    }
    throw new Error(`upload ${id} changed too often while being taken`);
  }

  private lockKey = (name: string, canonical: string) => `ver#${name}#${canonical}`;
  async claimVersion(name: string, canonical: string, publishId: string): Promise<string> {
    const key = this.lockKey(name, canonical);
    if (await this.putIfAbsent(this.tables.publishes, 'publish_id', { publish_id: key, winner: publishId })) return publishId;
    const held = await this.get(this.tables.publishes, 'publish_id', key);
    if (!held) throw new Error('the version lock vanished');
    return held.winner as string;
  }
  async versionHolder(name: string, canonical: string) {
    const held = await this.get(this.tables.publishes, 'publish_id', this.lockKey(name, canonical));
    return held?.winner as string | undefined;
  }

  async createPublish(rec: PublishRecord): Promise<PublishRecord> {
    if (await this.putIfAbsent(this.tables.publishes, 'publish_id', rec)) return rec;
    const have = await this.getPublish(rec.publish_id);
    if (!have) throw new Error('the publish vanished');
    return have;
  }
  async getPublish(id: string) {
    return (await this.get(this.tables.publishes, 'publish_id', id)) as PublishRecord | undefined;
  }
  async updatePublish(id: string, fn: (cur: PublishRecord) => PublishRecord | undefined): Promise<PublishRecord | undefined> {
    for (let i = 0; i < MAX_ATTEMPTS; i++) {
      const cur = await this.getPublish(id);
      if (!cur) return undefined;
      const next = fn(structuredClone(cur));
      if (next === undefined) return cur;
      const written = { ...next, rev: cur.rev + 1 };
      if (await this.swap(this.tables.publishes, written, cur.rev)) return written;
    }
    throw new Error(`publish ${id} changed too often while updating`);
  }

  async hit(key: string, limit: number, expiresAt: number, n = 1): Promise<{ ok: boolean; count: number }> {
    for (let i = 0; i < MAX_HIT_ATTEMPTS; i++) {
      const cur = await this.get(this.tables.publishes, 'publish_id', key);
      if (!cur) {
        if (n > limit) return { ok: false, count: 0 };
        if (await this.putIfAbsent(this.tables.publishes, 'publish_id', { publish_id: key, count: n, rev: 0, expires_at: expiresAt })) {
          return { ok: true, count: n };
        }
        continue;
      }
      const count = cur.count as number;
      if (count + n > limit) return { ok: false, count };
      if (await this.swap(this.tables.publishes, { ...cur, count: count + n, rev: (cur.rev as number) + 1 }, cur.rev as number)) {
        return { ok: true, count: count + n };
      }
    }
    throw new Error(`counter ${key} changed too often`);
  }

  private actorKey = (actor: string) => `grpa#${actor}`;
  async getActorGroups(actor: string): Promise<ActorGroups | undefined> {
    const i = await this.get(this.tables.publishes, 'publish_id', this.actorKey(actor));
    return i && { actor, groups: i.groups as ActorGroup[], rev: i.rev as number };
  }
  async putActorGroups(actor: string, groups: ActorGroup[], rev: number | undefined): Promise<boolean> {
    if (typeof rev !== 'number') return this.putIfAbsent(this.tables.publishes, 'publish_id', { publish_id: this.actorKey(actor), actor, groups, rev: 0 });
    return this.swap(this.tables.publishes, { publish_id: this.actorKey(actor), actor, groups, rev: rev + 1 }, rev);
  }
}
