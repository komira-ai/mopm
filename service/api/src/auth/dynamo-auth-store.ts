import { GetCommand, PutCommand, QueryCommand, UpdateCommand, DeleteCommand } from '@aws-sdk/lib-dynamodb';
import type { DocClient } from '../dynamo-store';
import type { AuthStore, DeviceLoginRecord, TokenRecord, TrustedPublisher, UserRecord } from './types';

/** Table names (service/infra/stacks/lib/config.ts: `mopm-<stage>-<table>`). */
export interface AuthTables {
  users: string;
  tokens: string;
  device_logins: string;
  trusted_publishers: string;
}

export const authTablesFor = (stage: string): AuthTables => ({
  users: `mopm-${stage}-users`,
  tokens: `mopm-${stage}-tokens`,
  device_logins: `mopm-${stage}-device_logins`,
  trusted_publishers: `mopm-${stage}-trusted_publishers`,
});

/** The tokens table's index by account (service/infra/stacks/lib/data-stack.ts): partition github_id, sort id. */
export const TOKENS_BY_GITHUB_ID = 'by_github_id';

type Item = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

const conditionFailed = (err: unknown) => (err as { name?: string })?.name === 'ConditionalCheckFailedException';
const epochSeconds = (iso: string) => Math.floor(Date.parse(iso) / 1000);
const strip = (i: Item, ...drop: string[]) => {
  const out = { ...i };
  for (const k of drop) delete out[k];
  return out;
};

// DynamoDB's time-to-live reads a NUMBER of epoch seconds from the table's TTL attribute, here `expires_at`. The
// records carry ISO strings, so the item keeps both: `expires_at` (seconds, for DynamoDB) and `expires_at_iso`
// (what the record said, millisecond exact). TTL deletion is lazy cleanup, typically within two days of expiry; the
// code decides expiry on every read from the record, so a row that is expired but not yet removed behaves as expired.

const tokenToItem = (r: TokenRecord): Item => {
  const { hash, github_id, expires_at, ...rest } = r;
  return {
    ...rest,
    token_hash: hash,
    expires_at: epochSeconds(expires_at),
    // Index keys are strings (like the owners table); the number is kept for reading back.
    ...(github_id !== undefined ? { github_id: String(github_id) } : {}),
  };
};
const tokenFromItem = (i: Item): TokenRecord => {
  const { token_hash, github_id, github_id_num, expires_at, expires_at_iso, ...rest } = i;
  return { ...rest, hash: token_hash, expires_at: expires_at_iso, ...(github_id_num !== undefined ? { github_id: github_id_num } : {}) } as TokenRecord;
};

/**
 * AuthStore on DynamoDB. Deviations a reader needs to know:
 * - No row is ever deleted by this adapter's normal paths: the tables deny DeleteItem to every role but the
 *   takedown/cleanup roles (data-stack.ts), and this Lambda's role is not one of them. A finished device login is
 *   marked consumed (its GitHub device code is removed from the row) and TTL removes the row later.
 * - listTokens and getUserToken read the by-account index, which is eventually consistent: a token created a moment
 *   ago may be missing from a list for a short time.
 * - removeTrustedPublisher is a real delete and so needs a role the table policy exempts; no route in the Lambda
 *   registers or removes publishers yet.
 */
export class DynamoAuthStore implements AuthStore {
  constructor(
    private readonly doc: DocClient,
    private readonly tables: AuthTables,
  ) {}

  async upsertUser(github_id: number, handle: string, now: string, two_factor?: boolean): Promise<UserRecord> {
    const old = await this.getUser(github_id);
    const rec: UserRecord = { github_id, handle, created_at: old?.created_at ?? now, last_login_at: now };
    if (two_factor !== undefined) rec.two_factor = two_factor;
    await this.doc.send(
      new PutCommand({ TableName: this.tables.users, Item: { ...rec, github_id: String(github_id), github_id_num: github_id } }),
    );
    return rec;
  }

  async getUser(github_id: number): Promise<UserRecord | undefined> {
    const r = await this.doc.send(new GetCommand({ TableName: this.tables.users, Key: { github_id: String(github_id) } }));
    if (!r.Item) return undefined;
    return { ...strip(r.Item, 'github_id_num'), github_id: r.Item.github_id_num } as UserRecord;
  }

  async putToken(rec: TokenRecord): Promise<void> {
    await this.doc.send(
      new PutCommand({
        TableName: this.tables.tokens,
        Item: tokenToItem(rec),
        // A token hash is 256 bits of a random secret: a collision is a bug, never overwrite.
        ConditionExpression: 'attribute_not_exists(#h)',
        ExpressionAttributeNames: { '#h': 'token_hash' },
      }),
    );
  }

  async getTokenByHash(hash: string): Promise<TokenRecord | undefined> {
    const r = await this.doc.send(new GetCommand({ TableName: this.tables.tokens, Key: { token_hash: hash }, ConsistentRead: true }));
    return r.Item ? tokenFromItem(r.Item) : undefined;
  }

  async getUserToken(github_id: number, id: string): Promise<TokenRecord | undefined> {
    const r = await this.doc.send(
      new QueryCommand({
        TableName: this.tables.tokens,
        IndexName: TOKENS_BY_GITHUB_ID,
        KeyConditionExpression: '#g = :g AND #i = :i',
        ExpressionAttributeNames: { '#g': 'github_id', '#i': 'id' },
        ExpressionAttributeValues: { ':g': String(github_id), ':i': id },
      }),
    );
    const item = (r.Items ?? [])[0];
    return item ? tokenFromItem(item) : undefined;
  }

  async listTokens(github_id: number): Promise<TokenRecord[]> {
    const out: TokenRecord[] = [];
    let start: Item | undefined;
    do {
      const r = await this.doc.send(
        new QueryCommand({
          TableName: this.tables.tokens,
          IndexName: TOKENS_BY_GITHUB_ID,
          KeyConditionExpression: '#g = :g',
          ExpressionAttributeNames: { '#g': 'github_id' },
          ExpressionAttributeValues: { ':g': String(github_id) },
          ExclusiveStartKey: start,
        }),
      );
      out.push(...(r.Items ?? []).map(tokenFromItem));
      start = r.LastEvaluatedKey;
    } while (start);
    return out;
  }

  async revokeToken(hash: string, at: string): Promise<void> {
    try {
      await this.doc.send(
        new UpdateCommand({
          TableName: this.tables.tokens,
          Key: { token_hash: hash },
          UpdateExpression: 'SET #r = :at',
          // The first revocation time stays; a missing row is nothing to revoke.
          ConditionExpression: 'attribute_exists(#h) AND attribute_not_exists(#r)',
          ExpressionAttributeNames: { '#r': 'revoked_at', '#h': 'token_hash' },
          ExpressionAttributeValues: { ':at': at },
        }),
      );
    } catch (err) {
      if (!conditionFailed(err)) throw err;
    }
  }

  async touchToken(hash: string, at: string): Promise<void> {
    try {
      await this.doc.send(
        new UpdateCommand({
          TableName: this.tables.tokens,
          Key: { token_hash: hash },
          UpdateExpression: 'SET #u = :at',
          ConditionExpression: 'attribute_exists(#h)',
          ExpressionAttributeNames: { '#u': 'last_used_at', '#h': 'token_hash' },
          ExpressionAttributeValues: { ':at': at },
        }),
      );
    } catch (err) {
      if (!conditionFailed(err)) throw err;
    }
  }

  async putDeviceLogin(rec: DeviceLoginRecord): Promise<void> {
    const { expires_at, ...rest } = rec;
    await this.doc.send(
      new PutCommand({
        TableName: this.tables.device_logins,
        Item: { ...rest, expires_at: epochSeconds(expires_at), expires_at_iso: expires_at },
        ConditionExpression: 'attribute_not_exists(#id)',
        ExpressionAttributeNames: { '#id': 'id' },
      }),
    );
  }

  async getDeviceLogin(id: string): Promise<DeviceLoginRecord | undefined> {
    const r = await this.doc.send(new GetCommand({ TableName: this.tables.device_logins, Key: { id }, ConsistentRead: true }));
    const i = r.Item;
    if (!i || i.consumed_at !== undefined) return undefined;
    const { expires_at, expires_at_iso, consumed_at: _c, ...rest } = i;
    return { ...rest, expires_at: expires_at_iso } as DeviceLoginRecord;
  }

  async setDevicePolled(id: string, at: string, interval: number): Promise<void> {
    try {
      await this.doc.send(
        new UpdateCommand({
          TableName: this.tables.device_logins,
          Key: { id },
          UpdateExpression: 'SET #p = :at, #n = :n',
          ConditionExpression: 'attribute_exists(#id) AND attribute_not_exists(#c)',
          ExpressionAttributeNames: { '#p': 'last_polled_at', '#n': 'interval', '#id': 'id', '#c': 'consumed_at' },
          ExpressionAttributeValues: { ':at': at, ':n': interval },
        }),
      );
    } catch (err) {
      if (!conditionFailed(err)) throw err;
    }
  }

  async deleteDeviceLogin(id: string): Promise<void> {
    try {
      await this.doc.send(
        new UpdateCommand({
          TableName: this.tables.device_logins,
          Key: { id },
          // Consumed: no longer pollable, and GitHub's device code leaves the row now. TTL removes the row.
          UpdateExpression: 'SET #c = :t REMOVE #g',
          ConditionExpression: 'attribute_exists(#id)',
          ExpressionAttributeNames: { '#c': 'consumed_at', '#g': 'github_device_code', '#id': 'id' },
          ExpressionAttributeValues: { ':t': new Date().toISOString() },
        }),
      );
    } catch (err) {
      if (!conditionFailed(err)) throw err;
    }
  }

  async addTrustedPublisher(tp: TrustedPublisher): Promise<void> {
    await this.doc.send(
      new PutCommand({
        TableName: this.tables.trusted_publishers,
        Item: { ...tp, publisher: tp.id },
        ConditionExpression: 'attribute_not_exists(#p)',
        ExpressionAttributeNames: { '#p': 'publisher' },
      }),
    );
  }

  async listTrustedPublishers(name: string): Promise<TrustedPublisher[]> {
    const out: TrustedPublisher[] = [];
    let start: Item | undefined;
    do {
      const r = await this.doc.send(
        new QueryCommand({
          TableName: this.tables.trusted_publishers,
          KeyConditionExpression: '#n = :n',
          ExpressionAttributeNames: { '#n': 'name' },
          ExpressionAttributeValues: { ':n': name },
          ConsistentRead: true,
          ExclusiveStartKey: start,
        }),
      );
      out.push(...(r.Items ?? []).map((i: Item) => strip(i, 'publisher') as unknown as TrustedPublisher));
      start = r.LastEvaluatedKey;
    } while (start);
    return out;
  }

  async removeTrustedPublisher(name: string, id: string): Promise<void> {
    await this.doc.send(new DeleteCommand({ TableName: this.tables.trusted_publishers, Key: { name, publisher: id } }));
  }
}
