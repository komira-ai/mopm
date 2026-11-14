import { GetCommand, PutCommand } from '@aws-sdk/lib-dynamodb';
import type { DocClient } from '../dynamo-store';
import { passKey, type MembershipPass, type MembershipPassStore, type OrgRole } from './org-membership';

/**
 * MembershipPassStore on DynamoDB, table `mopm-<stage>-membership_passes` keyed by `key` (`<org id>:<account id>`), one
 * row per pair, replaced by each pass. DynamoDB's time-to-live reads `expires_at` as epoch seconds and removes old rows
 * lazily (typically within two days); the item keeps the exact time as `expires_at_iso`, and the check decides expiry
 * from it on every read, so a row past it is never used. No refusal is ever written.
 */
export class DynamoMembershipPassStore implements MembershipPassStore {
  constructor(
    private readonly doc: DocClient,
    private readonly table: string,
  ) {}

  async getPass(org_id: number, account_id: number): Promise<MembershipPass | undefined> {
    const r = await this.doc.send(new GetCommand({ TableName: this.table, Key: { key: passKey(org_id, account_id) }, ConsistentRead: true }));
    if (!r.Item) return undefined;
    return { role: r.Item.role as OrgRole, expires_at: r.Item.expires_at_iso as string };
  }

  async putPass(org_id: number, account_id: number, pass: MembershipPass): Promise<void> {
    await this.doc.send(
      new PutCommand({
        TableName: this.table,
        Item: {
          key: passKey(org_id, account_id),
          role: pass.role,
          expires_at: Math.floor(Date.parse(pass.expires_at) / 1000),
          expires_at_iso: pass.expires_at,
        },
      }),
    );
  }
}
