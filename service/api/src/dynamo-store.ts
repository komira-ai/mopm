import {
  DeleteCommand,
  GetCommand,
  PutCommand,
  QueryCommand,
  ScanCommand,
  TransactWriteCommand,
} from '@aws-sdk/lib-dynamodb';
import { RegistryError, versionExists } from './errors';
import { applyEvent, type VersionEvent } from './state';
import { auditSortKey, byVersion, type Store } from './store';
import type { AuditEntry, OwnerRecord, PackageRecord, VersionRecord } from './types';
import { canonicalVersion } from './version';

/** What the adapter needs from a DynamoDBDocumentClient; tests pass an in-process fake. */
export interface DocClient {
  send(command: any): Promise<any>; // eslint-disable-line @typescript-eslint/no-explicit-any
}

/** Table names (service/infra/stacks/lib/config.ts: `mopm-<stage>-<table>`). */
export interface Tables {
  packages: string;
  versions: string;
  owners: string;
  audit: string;
}

export const tablesFor = (stage: string): Tables => ({
  packages: `mopm-${stage}-packages`,
  versions: `mopm-${stage}-versions`,
  owners: `mopm-${stage}-owners`,
  audit: `mopm-${stage}-audit`,
});

const MAX_UPDATE_ATTEMPTS = 5;

type Item = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

/**
 * Version rows are keyed (name, version) where `version` holds the canonical form, so equivalent
 * spellings are the same key and a conditional put cannot create the second one. The spelling that was
 * published is kept in `version_spelling`.
 */
const toItem = (r: VersionRecord): Item => {
  const { canonical, version, ...rest } = r;
  return { ...rest, version: canonical, version_spelling: version };
};
const fromItem = (i: Item): VersionRecord => {
  const { version, version_spelling, ...rest } = i;
  return { ...rest, version: version_spelling, canonical: version } as VersionRecord;
};
const auditItem = (e: AuditEntry): Item => ({ ...e, ts_seq: auditSortKey(e) });
const fromAuditItem = (i: Item): AuditEntry => {
  const { ts_seq: _k, ...rest } = i;
  return rest as AuditEntry;
};

const cancelledByCondition = (err: unknown, index: number): boolean => {
  const e = err as { name?: string; CancellationReasons?: { Code?: string }[] };
  return e?.name === 'TransactionCanceledException' && e.CancellationReasons?.[index]?.Code === 'ConditionalCheckFailed';
};

export class DynamoStore implements Store {
  constructor(
    private readonly doc: DocClient,
    private readonly tables: Tables,
  ) {}

  async createPackage(pkg: PackageRecord): Promise<void> {
    try {
      await this.doc.send(
        new PutCommand({
          TableName: this.tables.packages,
          Item: pkg,
          ConditionExpression: 'attribute_not_exists(#n)',
          ExpressionAttributeNames: { '#n': 'name' },
        }),
      );
    } catch (err) {
      if ((err as { name?: string }).name === 'ConditionalCheckFailedException') {
        throw new RegistryError('name_taken', `'${pkg.name}' is already taken.`, { name: pkg.name });
      }
      throw err;
    }
  }
  async getPackage(name: string) {
    const r = await this.doc.send(new GetCommand({ TableName: this.tables.packages, Key: { name } }));
    return r.Item as PackageRecord | undefined;
  }
  async listPackageNames() {
    const names: string[] = [];
    let start: Item | undefined;
    do {
      const r = await this.doc.send(
        new ScanCommand({ TableName: this.tables.packages, ProjectionExpression: '#n', ExpressionAttributeNames: { '#n': 'name' }, ExclusiveStartKey: start }),
      );
      for (const i of r.Items ?? []) names.push(i.name);
      start = r.LastEvaluatedKey;
    } while (start);
    return names.sort();
  }

  /** One transaction: the version row, created only if the key is absent, and its audit row. No read first. */
  async createVersion(rec: VersionRecord, audit: AuditEntry): Promise<void> {
    const canonical = canonicalVersion(rec.version);
    try {
      await this.doc.send(
        new TransactWriteCommand({
          TransactItems: [
            {
              Put: {
                TableName: this.tables.versions,
                Item: toItem({ ...rec, canonical }),
                ConditionExpression: 'attribute_not_exists(#n)',
                ExpressionAttributeNames: { '#n': 'name' },
              },
            },
            {
              Put: {
                TableName: this.tables.audit,
                Item: auditItem(audit),
                ConditionExpression: 'attribute_not_exists(#n)',
                ExpressionAttributeNames: { '#n': 'name' },
              },
            },
          ],
        }),
      );
    } catch (err) {
      if (cancelledByCondition(err, 0)) {
        const existing = await this.getVersion(rec.name, rec.version);
        throw versionExists(rec.name, rec.version, existing?.files[0]?.sha256 ?? existing?.manifest_sha256 ?? 'unknown');
      }
      throw err;
    }
  }
  async getVersion(name: string, version: string) {
    const r = await this.doc.send(
      new GetCommand({ TableName: this.tables.versions, Key: { name, version: canonicalVersion(version) }, ConsistentRead: true }),
    );
    return r.Item ? fromItem(r.Item) : undefined;
  }

  /** Read, apply the state machine, write back only if `rev` is unchanged; on a lost race read again. */
  async updateVersion(name: string, version: string, event: VersionEvent, audit: AuditEntry): Promise<VersionRecord> {
    for (let attempt = 0; attempt < MAX_UPDATE_ATTEMPTS; attempt++) {
      const cur = await this.getVersion(name, version);
      if (!cur) throw new RegistryError('version_not_found', `'${name}' has no version '${version}'.`, { name, version });
      const next = applyEvent(cur, event);
      if (next === cur) return cur;
      try {
        await this.doc.send(
          new TransactWriteCommand({
            TransactItems: [
              {
                Put: {
                  TableName: this.tables.versions,
                  Item: toItem(next),
                  ConditionExpression: '#r = :r',
                  ExpressionAttributeNames: { '#r': 'rev' },
                  ExpressionAttributeValues: { ':r': cur.rev },
                },
              },
              {
                Put: {
                  TableName: this.tables.audit,
                  Item: auditItem(audit),
                  ConditionExpression: 'attribute_not_exists(#n)',
                  ExpressionAttributeNames: { '#n': 'name' },
                },
              },
            ],
          }),
        );
        return next;
      } catch (err) {
        if (cancelledByCondition(err, 0)) continue;
        throw err;
      }
    }
    throw new RegistryError('internal_error', `'${name}' ${version} changed too often while updating.`, { name, version });
  }
  async listVersions(name: string) {
    const out: VersionRecord[] = [];
    let start: Item | undefined;
    do {
      const r = await this.doc.send(
        new QueryCommand({
          TableName: this.tables.versions,
          KeyConditionExpression: '#n = :n',
          ExpressionAttributeNames: { '#n': 'name' },
          ExpressionAttributeValues: { ':n': name },
          ConsistentRead: true,
          ExclusiveStartKey: start,
        }),
      );
      for (const i of r.Items ?? []) out.push(fromItem(i));
      start = r.LastEvaluatedKey;
    } while (start);
    return out.sort(byVersion);
  }

  // Owners: sort key github_id is a string in the table.
  async addOwner(o: OwnerRecord): Promise<void> {
    try {
      await this.doc.send(
        new PutCommand({
          TableName: this.tables.owners,
          Item: { ...o, github_id: String(o.github_id), github_id_num: o.github_id },
          ConditionExpression: 'attribute_not_exists(#n)',
          ExpressionAttributeNames: { '#n': 'name' },
        }),
      );
    } catch (err) {
      if ((err as { name?: string }).name === 'ConditionalCheckFailedException') {
        throw new RegistryError('already_owner', `'${o.handle}' already owns '${o.name}'.`, { name: o.name });
      }
      throw err;
    }
  }
  async removeOwner(name: string, githubId: number): Promise<void> {
    try {
      await this.doc.send(
        new DeleteCommand({
          TableName: this.tables.owners,
          Key: { name, github_id: String(githubId) },
          ConditionExpression: 'attribute_exists(#n)',
          ExpressionAttributeNames: { '#n': 'name' },
        }),
      );
    } catch (err) {
      if ((err as { name?: string }).name === 'ConditionalCheckFailedException') {
        throw new RegistryError('owner_not_found', 'That account is not an owner of the package.', { name });
      }
      throw err;
    }
  }
  async listOwners(name: string) {
    const items = await this.queryAll(this.tables.owners, name);
    return items
      .map((i): OwnerRecord => ({ name: i.name, github_id: i.github_id_num, handle: i.handle, added_at: i.added_at }))
      .sort((a, b) => a.github_id - b.github_id);
  }

  async appendAudit(entry: AuditEntry): Promise<void> {
    await this.doc.send(
      new PutCommand({
        TableName: this.tables.audit,
        Item: auditItem(entry),
        ConditionExpression: 'attribute_not_exists(#n)',
        ExpressionAttributeNames: { '#n': 'name' },
      }),
    );
  }
  async listAudit(name: string) {
    return (await this.queryAll(this.tables.audit, name)).map(fromAuditItem);
  }

  private async queryAll(table: string, name: string): Promise<Item[]> {
    const out: Item[] = [];
    let start: Item | undefined;
    do {
      const r = await this.doc.send(
        new QueryCommand({
          TableName: table,
          KeyConditionExpression: '#n = :n',
          ExpressionAttributeNames: { '#n': 'name' },
          ExpressionAttributeValues: { ':n': name },
          ConsistentRead: true,
          ExclusiveStartKey: start,
        }),
      );
      out.push(...(r.Items ?? []));
      start = r.LastEvaluatedKey;
    } while (start);
    return out;
  }
}
