import { GetCommand, UpdateCommand } from '@aws-sdk/lib-dynamodb';
import type { DocClient } from '../dynamo-store';
import type { TokenRecord } from '../auth/types';

/**
 * Row layout of the `tokens` table. The table is keyed by `token_hash` and its TTL attribute `expires_at` must be
 * epoch seconds, while a TokenRecord carries RFC 3339 text, so the text moves to `expires_at_iso`. The login
 * wiring that issues tokens writes rows with `tokenToItem`; this module only reads them.
 */
export const tokenToItem = (t: TokenRecord): Record<string, unknown> => {
  const item: Record<string, unknown> = { ...t, token_hash: t.hash, expires_at: Math.floor(Date.parse(t.expires_at) / 1000), expires_at_iso: t.expires_at };
  for (const k of Object.keys(item)) if (item[k] === undefined) delete item[k];
  return item;
};
export const tokenFromItem = (i: Record<string, any>): TokenRecord => { // eslint-disable-line @typescript-eslint/no-explicit-any
  const { token_hash: _h, expires_at: _e, expires_at_iso, ...rest } = i;
  return { ...rest, expires_at: expires_at_iso } as TokenRecord;
};

/**
 * The part of the auth store the bearer middleware needs. Rows are keyed by hash and touch is by id, but the
 * middleware touches a token only right after looking it up, so the adapter remembers the hash it just read.
 */
export class DynamoTokenReader {
  private readonly hashById = new Map<string, string>();
  constructor(
    private readonly doc: DocClient,
    private readonly table: string,
  ) {}

  async getTokenByHash(hash: string): Promise<TokenRecord | undefined> {
    const r = await this.doc.send(new GetCommand({ TableName: this.table, Key: { token_hash: hash }, ConsistentRead: true }));
    if (!r.Item) return undefined;
    const rec = tokenFromItem(r.Item);
    if (this.hashById.size > 1000) this.hashById.clear();
    this.hashById.set(rec.id, hash);
    return rec;
  }

  /** Only `last_used_at` changes, and only on a row that still exists (a revoked row is not resurrected). */
  async touchToken(id: string, at: string): Promise<void> {
    const hash = this.hashById.get(id);
    if (!hash) return;
    try {
      await this.doc.send(
        new UpdateCommand({
          TableName: this.table,
          Key: { token_hash: hash },
          UpdateExpression: 'SET #t = :t',
          ConditionExpression: 'attribute_exists(#k)',
          ExpressionAttributeNames: { '#t': 'last_used_at', '#k': 'token_hash' },
          ExpressionAttributeValues: { ':t': at },
        }),
      );
    } catch (err) {
      if ((err as { name?: string })?.name !== 'ConditionalCheckFailedException') throw err;
    }
  }
}
