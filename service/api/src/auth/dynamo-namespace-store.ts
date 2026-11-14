import { GetCommand, PutCommand, QueryCommand } from '@aws-sdk/lib-dynamodb';
import type { DocClient } from '../dynamo-store';
import type { NamespaceRecord, NamespaceStore } from './namespaces';

/** The namespaces table's index by GitHub id (service/infra/stacks/lib/data-stack.ts): partition github_id, sort namespace. */
export const NAMESPACES_BY_GITHUB_ID = 'by_github_id';

type Item = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

const conditionFailed = (err: unknown) => (err as { name?: string })?.name === 'ConditionalCheckFailedException';

// Index keys are strings (as in the owners and tokens tables); the number is kept beside them for reading back.
const toItem = (r: NamespaceRecord): Item => ({ ...r, github_id: String(r.github_id), github_id_num: r.github_id });
const fromItem = (i: Item): NamespaceRecord => {
  const { github_id: _s, github_id_num, ...rest } = i;
  return { ...rest, github_id: github_id_num } as NamespaceRecord;
};

/**
 * NamespaceStore on DynamoDB, table `mopm-<stage>-namespaces` keyed by `namespace`. Create-once is a PutItem conditional
 * on the key being absent; the loser of a race reads the winner's row with a strongly consistent read. No path deletes
 * or overwrites a row (the table denies DeleteItem to this role, data-stack.ts). listNamespaces reads the by-GitHub-id
 * index, which is eventually consistent: a namespace created a moment ago may be missing from a list for a short time.
 */
export class DynamoNamespaceStore implements NamespaceStore {
  constructor(
    private readonly doc: DocClient,
    private readonly table: string,
  ) {}

  async getNamespace(namespace: string): Promise<NamespaceRecord | undefined> {
    const r = await this.doc.send(new GetCommand({ TableName: this.table, Key: { namespace }, ConsistentRead: true }));
    return r.Item ? fromItem(r.Item) : undefined;
  }

  async createNamespace(rec: NamespaceRecord): Promise<{ created: boolean; record: NamespaceRecord }> {
    try {
      await this.doc.send(
        new PutCommand({
          TableName: this.table,
          Item: toItem(rec),
          ConditionExpression: 'attribute_not_exists(#n)',
          ExpressionAttributeNames: { '#n': 'namespace' },
        }),
      );
      return { created: true, record: rec };
    } catch (err) {
      if (!conditionFailed(err)) throw err;
    }
    const held = await this.getNamespace(rec.namespace);
    // The condition failed, so a row existed; rows are never deleted, so it is still there.
    if (!held) throw new Error(`namespace ${rec.namespace}: the create was refused but no row is stored`);
    return { created: false, record: held };
  }

  async listNamespaces(github_id: number): Promise<NamespaceRecord[]> {
    const out: NamespaceRecord[] = [];
    let start: Item | undefined;
    do {
      const r = await this.doc.send(
        new QueryCommand({
          TableName: this.table,
          IndexName: NAMESPACES_BY_GITHUB_ID,
          KeyConditionExpression: '#g = :g',
          ExpressionAttributeNames: { '#g': 'github_id' },
          ExpressionAttributeValues: { ':g': String(github_id) },
          ExclusiveStartKey: start,
        }),
      );
      out.push(...(r.Items ?? []).map(fromItem));
      start = r.LastEvaluatedKey;
    } while (start);
    return out;
  }
}
