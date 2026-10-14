import { QueryCommand } from '@aws-sdk/lib-dynamodb';
import type { DocClient } from '../dynamo-store';

/** The owners table's index by account (data-stack.ts): partition github_id, sort name. */
export const OWNERS_BY_GITHUB_ID = 'by_github_id';

/** The packages an account owns, from the owners table's index. Read-only: it needs Query on that index. */
export function ownedPackagesFrom(doc: DocClient, ownersTable: string): (github_id: number) => Promise<string[]> {
  return async (github_id) => {
    const names: string[] = [];
    let start: Record<string, unknown> | undefined;
    do {
      const r = await doc.send(
        new QueryCommand({
          TableName: ownersTable,
          IndexName: OWNERS_BY_GITHUB_ID,
          KeyConditionExpression: '#g = :g',
          ExpressionAttributeNames: { '#g': 'github_id' },
          ExpressionAttributeValues: { ':g': String(github_id) },
          ExclusiveStartKey: start,
        }),
      );
      names.push(...(r.Items ?? []).map((i: { name: string }) => i.name));
      start = r.LastEvaluatedKey;
    } while (start);
    return names;
  };
}
