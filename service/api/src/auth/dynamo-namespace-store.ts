import { GetCommand, PutCommand, QueryCommand, TransactWriteCommand } from '@aws-sdk/lib-dynamodb';
import type { DocClient } from '../dynamo-store';
import { decideRemove, decideSet, type NamespaceMember, type NamespaceRecord, type NamespaceStore } from './namespaces';

/** The namespaces table's index by GitHub id (service/infra/stacks/lib/data-stack.ts): partition github_id, sort namespace. */
export const NAMESPACES_BY_GITHUB_ID = 'by_github_id';

/** The members table's index by member (data-stack.ts): partition member (the GitHub id as a string), sort namespace. */
export const MEMBERS_BY_MEMBER = 'by_member';

/** A member change that loses the namespace row's `members_rev` condition is read and decided again this many times more. */
const MEMBER_RETRIES = 3;

type Item = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

const conditionFailed = (err: unknown) => (err as { name?: string })?.name === 'ConditionalCheckFailedException';
/** A cancelled transaction is a lost race when one of its conditions failed; any other reason is an error. */
const transactionLost = (err: unknown) =>
  (err as { name?: string })?.name === 'TransactionCanceledException' &&
  ((err as { CancellationReasons?: { Code?: string }[] }).CancellationReasons ?? []).some((r) => r.Code === 'ConditionalCheckFailed');

// Index keys are strings (as in the owners and tokens tables); the number is kept beside them for reading back.
const toItem = (r: NamespaceRecord): Item => ({
  ...r,
  github_id: String(r.github_id),
  github_id_num: r.github_id,
});
const fromItem = (i: Item): NamespaceRecord => {
  const { github_id: _s, github_id_num, members_rev: _r, ...rest } = i;
  return { ...rest, github_id: github_id_num } as NamespaceRecord;
};

// A member row is keyed by namespace and `member`, the GitHub id as a string (the index key); the number is kept beside it.
// A removed member's row stays (no DeleteItem): role `removed`, who removed it and when; every read skips it.
const memberItem = (m: NamespaceMember): Item => ({
  ...m,
  member: String(m.github_id),
});
const memberFrom = (i: Item): NamespaceMember => {
  const { member: _m, removed_by: _b, removed_at: _a, ...rest } = i;
  return rest as NamespaceMember;
};
const live = (i: Item) => i.role !== 'removed';

/**
 * NamespaceStore on DynamoDB: table `mopm-<stage>-namespaces` keyed by `namespace`, and table `mopm-<stage>-namespace_members`
 * keyed by `namespace` and `member`. Create-once is a PutItem conditional on the key being absent; the loser of a race reads
 * the winner's row with a strongly consistent read. No path deletes a row (the tables deny DeleteItem to this role,
 * data-stack.ts) or changes a GitHub id. listNamespaces and listMemberships read indexes, which are eventually consistent:
 * a row written a moment ago may be missing from them for a short time.
 *
 * The last-owner rule needs the members read and written as one: every member change reads the namespace row (with its
 * `members_rev`) and the members, decides with the same code as the memory adapter, and writes in one TransactWriteItems the
 * namespace row with `members_rev` + 1, conditional on it being the value read, and the member row. A change that lost the
 * condition to another change reads and decides again, up to MEMBER_RETRIES more times; a loss after that is an error.
 * A removal writes the member row back with role `removed` (a re-add writes it again as owner or member).
 */
export class DynamoNamespaceStore implements NamespaceStore {
  constructor(
    private readonly doc: DocClient,
    private readonly table: string,
    private readonly membersTable: string,
  ) {}

  async getNamespace(namespace: string): Promise<NamespaceRecord | undefined> {
    const r = await this.doc.send(
      new GetCommand({
        TableName: this.table,
        Key: { namespace },
        ConsistentRead: true,
      }),
    );
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

  async createOrgNamespace(rec: NamespaceRecord, owner: NamespaceMember): Promise<{ created: boolean; record: NamespaceRecord }> {
    if (rec.kind !== 'org' || owner.namespace !== rec.namespace)
      throw new Error(`namespace ${rec.namespace}: not an organization namespace with its owner`);
    try {
      await this.doc.send(
        new TransactWriteCommand({
          TransactItems: [
            {
              Put: {
                TableName: this.table,
                Item: { ...toItem(rec), members_rev: 1 },
                ConditionExpression: 'attribute_not_exists(#n)',
                ExpressionAttributeNames: { '#n': 'namespace' },
              },
            },
            { Put: { TableName: this.membersTable, Item: memberItem(owner) } },
          ],
        }),
      );
      return { created: true, record: rec };
    } catch (err) {
      if (!transactionLost(err)) throw err;
    }
    const held = await this.getNamespace(rec.namespace);
    // The condition failed, so a row existed; rows are never deleted, so it is still there.
    if (!held) throw new Error(`namespace ${rec.namespace}: the create was refused but no row is stored`);
    return { created: false, record: held };
  }

  async getMember(namespace: string, github_id: number): Promise<NamespaceMember | undefined> {
    const r = await this.doc.send(
      new GetCommand({
        TableName: this.membersTable,
        Key: { namespace, member: String(github_id) },
        ConsistentRead: true,
      }),
    );
    return r.Item && live(r.Item) ? memberFrom(r.Item) : undefined;
  }

  async listMembers(namespace: string): Promise<NamespaceMember[]> {
    return (await this.partition(namespace))
      .filter(live)
      .map(memberFrom)
      .sort((a, b) => a.github_id - b.github_id);
  }

  async listMemberships(github_id: number): Promise<NamespaceMember[]> {
    const out: Item[] = [];
    let start: Item | undefined;
    do {
      const r = await this.doc.send(
        new QueryCommand({
          TableName: this.membersTable,
          IndexName: MEMBERS_BY_MEMBER,
          KeyConditionExpression: '#m = :m',
          ExpressionAttributeNames: { '#m': 'member' },
          ExpressionAttributeValues: { ':m': String(github_id) },
          ExclusiveStartKey: start,
        }),
      );
      out.push(...(r.Items ?? []));
      start = r.LastEvaluatedKey;
    } while (start);
    return out.filter(live).map(memberFrom);
  }

  async setMember(m: NamespaceMember): Promise<'added' | 'changed' | 'same' | 'last_owner'> {
    return this.change(m.namespace, (members) => {
      const outcome = decideSet(members, m);
      return {
        outcome,
        write: outcome === 'added' || outcome === 'changed' ? memberItem(m) : undefined,
      };
    });
  }

  async removeMember(namespace: string, github_id: number, removed_by: number, at: string): Promise<'removed' | 'not_member' | 'last_owner'> {
    return this.change(
      namespace,
      (members) => {
        const outcome = decideRemove(members, github_id);
        const held = members.find((x) => x.github_id === github_id);
        return {
          outcome,
          write:
            outcome === 'removed'
              ? {
                  ...memberItem(held!),
                  role: 'removed',
                  removed_by,
                  removed_at: at,
                }
              : undefined,
        };
      },
      'not_member',
    );
  }

  /** Every row of a namespace's partition of the members table, removed ones included (strongly consistent). */
  private async partition(namespace: string): Promise<Item[]> {
    const out: Item[] = [];
    let start: Item | undefined;
    do {
      const r = await this.doc.send(
        new QueryCommand({
          TableName: this.membersTable,
          KeyConditionExpression: '#n = :n',
          ExpressionAttributeNames: { '#n': 'namespace' },
          ExpressionAttributeValues: { ':n': namespace },
          ConsistentRead: true,
          ExclusiveStartKey: start,
        }),
      );
      out.push(...(r.Items ?? []));
      start = r.LastEvaluatedKey;
    } while (start);
    return out;
  }

  /**
   * Read the namespace row and the members, let `decide` answer, and write its row (when any) under the `members_rev` condition.
   * A namespace that is not an organization one is `notOrg` when given, else an error.
   */
  private async change<T>(namespace: string, decide: (members: NamespaceMember[]) => { outcome: T; write?: Item }, notOrg?: T): Promise<T> {
    for (let attempt = 0; ; attempt++) {
      const row = (
        await this.doc.send(
          new GetCommand({
            TableName: this.table,
            Key: { namespace },
            ConsistentRead: true,
          }),
        )
      ).Item as Item | undefined;
      if (!row || row.kind !== 'org') {
        if (notOrg !== undefined) return notOrg;
        throw new Error(`namespace ${namespace} is not an organization namespace`);
      }
      const members = (await this.partition(namespace)).filter(live).map(memberFrom);
      const { outcome, write } = decide(members);
      if (!write) return outcome;
      const rev: number | undefined = row.members_rev;
      try {
        await this.doc.send(
          new TransactWriteCommand({
            TransactItems: [
              {
                Put: {
                  TableName: this.table,
                  Item: { ...row, members_rev: (rev ?? 0) + 1 },
                  ...(rev
                    ? {
                        ConditionExpression: '#r = :r',
                        ExpressionAttributeNames: { '#r': 'members_rev' },
                        ExpressionAttributeValues: { ':r': rev },
                      }
                    : {
                        ConditionExpression: 'attribute_not_exists(#r)',
                        ExpressionAttributeNames: { '#r': 'members_rev' },
                      }),
                },
              },
              { Put: { TableName: this.membersTable, Item: write } },
            ],
          }),
        );
        return outcome;
      } catch (err) {
        if (!transactionLost(err) || attempt >= MEMBER_RETRIES) throw err;
      }
    }
  }
}
