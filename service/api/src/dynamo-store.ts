import {
  DeleteCommand,
  GetCommand,
  PutCommand,
  QueryCommand,
  ScanCommand,
  TransactWriteCommand,
} from '@aws-sdk/lib-dynamodb';
import { RegistryError, versionExists } from './errors';
import { API_VIEW, headerKey, membersKey, parseHeader, parseMembers, VersionFunnel, type FunnelOptions, type GroupMembers, type GroupReader, type View } from './group';
import {
  checkHeaderWrite,
  commitInputItem,
  commitInputKey,
  commitToken,
  committedRecord,
  groupItem,
  membersItem,
  membersWithExpiry,
  parseCommitInput,
  parseGroupRecord,
  type ActiveGroup,
  type AdoptOutcome,
  type CommitInput,
  type CommitOutcome,
  type GroupRecord,
  type GroupStatus,
  type GroupStore,
} from './group-store';
import type { RawVersionPort } from './raw-port';
import { applyEvent, IllegalTransition, type GroupEvent, type UserEvent, type VersionEvent } from './state';
import { auditSortKey, type Store } from './store';
import type { AuditEntry, OwnerRecord, PackageRecord, PackageSummaryRecord, VersionRecord } from './types';
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
  /** The publish pipeline's table: it also holds the group headers and member lists a version read consults (src/group.ts). */
  publishes: string;
}

export const tablesFor = (stage: string): Tables => ({
  packages: `mopm-${stage}-packages`,
  versions: `mopm-${stage}-versions`,
  owners: `mopm-${stage}-owners`,
  audit: `mopm-${stage}-audit`,
  publishes: `mopm-${stage}-publishes`,
});

const MAX_UPDATE_ATTEMPTS = 5;

/**
 * The name-search index of the packages table (service/infra/stacks/lib/data-stack.ts, which creates it: keep the
 * two in step; both sides are pinned by tests). Partition key `search_bucket`, sort key `name`, so a prefix
 * search is one Query with `begins_with` on the sort key, in name order, with no Scan.
 *
 * Every package row carries the same bucket value: one partition. That is deliberate. A single GSI partition
 * serves up to 3000 read units a second, which is thousands of searches a second against a few thousand names
 * (a claim is rare; search results are small), and an empty `q` (browse everything) stays one ordered Query
 * instead of a merge over buckets. If search ever outgrows that, the bucket becomes a function of the name and
 * only this file and the stack change.
 */
export const SEARCH_INDEX = {
  name: 'by_search_bucket',
  bucketAttribute: 'search_bucket',
  bucket: 'all',
  /** Non-key attributes the index projects (the keys, search_bucket and name, always are). */
  projected: ['description', 'state', 'created_at'],
} as const;

type Item = Record<string, any>; // eslint-disable-line @typescript-eslint/no-explicit-any

/**
 * Version rows are keyed (name, version) where `version` holds the canonical form (today the version itself,
 * since a version has one spelling), so a conditional put cannot create the second one. The published
 * spelling is also kept in `version_spelling`, which older rows and readers rely on.
 */
const toItem = (r: VersionRecord): Item => {
  const { canonical, version, ...rest } = r;
  return { ...rest, version: canonical, version_spelling: version };
};
const fromItem = (i: Item): VersionRecord => {
  const { version, version_spelling, ...rest } = i;
  return { ...rest, version: version_spelling, canonical: version } as VersionRecord;
};
const packageItem = (pkg: PackageRecord): Item => ({ ...pkg, [SEARCH_INDEX.bucketAttribute]: SEARCH_INDEX.bucket });
const fromPackageItem = (i: Item): PackageRecord => {
  const { [SEARCH_INDEX.bucketAttribute]: _b, ...rest } = i;
  return rest as PackageRecord;
};
const ownerItem = (o: OwnerRecord): Item => ({ ...o, github_id: String(o.github_id), github_id_num: o.github_id });
const auditItem = (e: AuditEntry): Item => ({ ...e, ts_seq: auditSortKey(e) });
const fromAuditItem = (i: Item): AuditEntry => {
  const { ts_seq: _k, ...rest } = i;
  return rest as AuditEntry;
};

const cancelledByCondition = (err: unknown, index: number): boolean => {
  const e = err as { name?: string; CancellationReasons?: { Code?: string }[] };
  return e?.name === 'TransactionCanceledException' && e.CancellationReasons?.[index]?.Code === 'ConditionalCheckFailed';
};
/** A single conditional Put that lost: `ConditionalCheckFailedException`. */
const putLost = (err: unknown): boolean => (err as { name?: string })?.name === 'ConditionalCheckFailedException';

/**
 * A group's header and member list, read from the `publishes` table (key attribute `publish_id`, as for its other
 * rows). Both reads are consistent: a reader that has seen a commit must not be answered from before it.
 */
class DynamoGroupReader implements GroupReader {
  constructor(
    private readonly doc: DocClient,
    private readonly table: string,
  ) {}
  private async item(key: string): Promise<Item | undefined> {
    const r = await this.doc.send(new GetCommand({ TableName: this.table, Key: { publish_id: key }, ConsistentRead: true }));
    return r.Item as Item | undefined;
  }
  async header(gid: string) {
    const i = await this.item(headerKey(gid));
    return i && parseHeader(i);
  }
  async members(gid: string) {
    const i = await this.item(membersKey(gid));
    return i && parseMembers(i);
  }
}

export class DynamoStore implements Store, GroupStore {
  private readonly funnel: VersionFunnel;
  /** The rows as stored (src/raw-port.ts): for the group module and for tests that must see the stored form. */
  readonly raw: RawVersionPort;

  constructor(
    private readonly doc: DocClient,
    private readonly tables: Tables,
    funnel: FunnelOptions = {},
  ) {
    this.raw = {
      rawGet: (name, version) => this.rowOf(name, version),
      rawQuery: (name) => this.rowsOf(name),
    };
    this.funnel = new VersionFunnel(this.raw, new DynamoGroupReader(doc, tables.publishes), funnel);
  }

  async createPackage(pkg: PackageRecord): Promise<void> {
    try {
      await this.doc.send(
        new PutCommand({
          TableName: this.tables.packages,
          Item: packageItem(pkg),
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
  /** One transaction: the package row, the owner row and the audit row, each created only if its key is absent. */
  async claimPackage(pkg: PackageRecord, owner: OwnerRecord, audit: AuditEntry): Promise<void> {
    const create = (table: string, item: Item) => ({
      Put: { TableName: table, Item: item, ConditionExpression: 'attribute_not_exists(#n)', ExpressionAttributeNames: { '#n': 'name' } },
    });
    try {
      await this.doc.send(
        new TransactWriteCommand({
          TransactItems: [create(this.tables.packages, packageItem(pkg)), create(this.tables.owners, ownerItem(owner)), create(this.tables.audit, auditItem(audit))],
        }),
      );
    } catch (err) {
      // The package or the owner row is already there: the name is taken. (The audit key is a fresh id.)
      if (cancelledByCondition(err, 0) || cancelledByCondition(err, 1)) {
        throw new RegistryError('name_taken', `'${pkg.name}' is already taken.`, { name: pkg.name });
      }
      throw err;
    }
  }
  async getPackage(name: string) {
    const r = await this.doc.send(new GetCommand({ TableName: this.tables.packages, Key: { name } }));
    return r.Item ? fromPackageItem(r.Item) : undefined;
  }
  async listPackageNames() {
    const names: string[] = [];
    let start: Item | undefined;
    do {
      // Consistent: the builders list the packages to read, and a package claimed a moment ago must be in the list.
      // (A package claimed after the scan started is covered by the builders widening their read, src/group.ts.)
      const r = await this.doc.send(
        new ScanCommand({
          TableName: this.tables.packages,
          ProjectionExpression: '#n',
          ExpressionAttributeNames: { '#n': 'name' },
          ConsistentRead: true,
          ExclusiveStartKey: start,
        }),
      );
      for (const i of r.Items ?? []) names.push(i.name);
      start = r.LastEvaluatedKey;
    } while (start);
    return names.sort();
  }

  async searchPackages(prefix: string, after: string | undefined, limit: number): Promise<PackageSummaryRecord[]> {
    const out: PackageSummaryRecord[] = [];
    if (limit < 1) return out;
    // The index is eventually consistent (a GSI cannot be read consistently): a package claimed a moment ago may
    // not be listed yet. getPackage reads the table and is consistent.
    let start: Item | undefined = after === undefined ? undefined : { [SEARCH_INDEX.bucketAttribute]: SEARCH_INDEX.bucket, name: after };
    do {
      const r = await this.doc.send(
        new QueryCommand({
          TableName: this.tables.packages,
          IndexName: SEARCH_INDEX.name,
          // DynamoDB refuses an empty string in a key condition, so "everything" has no begins_with.
          KeyConditionExpression: prefix === '' ? '#b = :b' : '#b = :b AND begins_with(#n, :p)',
          ExpressionAttributeNames: prefix === '' ? { '#b': SEARCH_INDEX.bucketAttribute } : { '#b': SEARCH_INDEX.bucketAttribute, '#n': 'name' },
          ExpressionAttributeValues: prefix === '' ? { ':b': SEARCH_INDEX.bucket } : { ':b': SEARCH_INDEX.bucket, ':p': prefix },
          Limit: limit - out.length,
          ExclusiveStartKey: start,
        }),
      );
      for (const i of r.Items ?? []) {
        out.push({ name: i.name, state: i.state, created_at: i.created_at, ...(i.description === undefined ? {} : { description: i.description }) });
      }
      start = r.LastEvaluatedKey;
    } while (start && out.length < limit);
    return out;
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
    return this.funnel.getOne(name, version);
  }
  private async rowOf(name: string, version: string) {
    const r = await this.doc.send(
      new GetCommand({ TableName: this.tables.versions, Key: { name, version: canonicalVersion(version) }, ConsistentRead: true }),
    );
    return r.Item ? fromItem(r.Item) : undefined;
  }

  /**
   * Read (as a reader sees the row), apply the state machine, write back only if `rev` is unchanged; on a lost race
   * read again. A member of a committed group is `published` here, and its `rev` is the stored one, so the write
   * that follows is an ordinary one. A member of a group that has not committed is refused: only the group's own
   * code may change it.
   */
  async updateVersion(name: string, version: string, event: UserEvent, audit: AuditEntry): Promise<VersionRecord> {
    return this.change(name, version, event, audit, true);
  }

  /**
   * Read the row, apply the state machine, write back only if `rev` is unchanged; on a lost race read again. `asReader`:
   * the row is read as a reader sees it (see updateVersion's note); otherwise as stored, for a group's own event.
   */
  private async change(name: string, version: string, event: VersionEvent, audit: AuditEntry, asReader: boolean): Promise<VersionRecord> {
    for (let attempt = 0; attempt < MAX_UPDATE_ATTEMPTS; attempt++) {
      const cur = asReader ? await this.getVersion(name, version) : await this.rowOf(name, version);
      if (!cur) throw new RegistryError('version_not_found', `'${name}' has no version '${version}'.`, { name, version });
      if (asReader && cur.group_id !== undefined && cur.state === 'pending') throw new IllegalTransition(cur, event);
      const next = applyEvent(cur, event);
      if (next === cur) return cur;
      try {
        await this.doc.send(new TransactWriteCommand({ TransactItems: [this.versionPut(next, '#r = :r', { '#r': 'rev' }, { ':r': cur.rev }), this.auditPut(audit)] }));
        return next;
      } catch (err) {
        if (cancelledByCondition(err, 0)) continue;
        throw err;
      }
    }
    throw new RegistryError('internal_error', `'${name}' ${version} changed too often while updating.`, { name, version });
  }
  private versionPut(rec: VersionRecord, cond: string, names: Record<string, string>, values?: Record<string, unknown>) {
    return {
      Put: {
        TableName: this.tables.versions,
        Item: toItem(rec),
        ConditionExpression: cond,
        ExpressionAttributeNames: names,
        ...(values ? { ExpressionAttributeValues: values } : {}),
      },
    };
  }
  private auditPut(audit: AuditEntry) {
    return {
      Put: {
        TableName: this.tables.audit,
        Item: auditItem(audit),
        ConditionExpression: 'attribute_not_exists(#n)',
        ExpressionAttributeNames: { '#n': 'name' },
      },
    };
  }

  // --- the writers of a group (src/group-store.ts) ----------------------------------------------------------------

  private async publishItem(key: string): Promise<Item | undefined> {
    const r = await this.doc.send(new GetCommand({ TableName: this.tables.publishes, Key: { publish_id: key }, ConsistentRead: true }));
    return r.Item as Item | undefined;
  }
  private publishPut(item: Item, cond: string, names: Record<string, string>, values?: Record<string, unknown>) {
    return {
      Put: {
        TableName: this.tables.publishes,
        Item: item,
        ConditionExpression: cond,
        ExpressionAttributeNames: names,
        ...(values ? { ExpressionAttributeValues: values } : {}),
      },
    };
  }

  async getGroup(gid: string): Promise<GroupRecord | undefined> {
    const i = await this.publishItem(headerKey(gid));
    return i && parseGroupRecord(i);
  }
  async getGroupMembers(gid: string): Promise<GroupMembers | undefined> {
    const i = await this.publishItem(membersKey(gid));
    return i && parseMembers(i);
  }

  async createGroup(header: GroupRecord, members: GroupMembers, audit: AuditEntry): Promise<{ created: boolean; header: GroupRecord }> {
    checkHeaderWrite(undefined, header);
    const gid = header.group_id;
    const list = membersItem(gid, members);
    try {
      await this.doc.send(new PutCommand({ TableName: this.tables.publishes, Item: list, ConditionExpression: 'attribute_not_exists(#k)', ExpressionAttributeNames: { '#k': 'publish_id' } }));
    } catch (err) {
      if (!putLost(err)) throw err;
      // Written before (a retried create): it is the same list, or this is not the same group.
      if (JSON.stringify(await this.getGroupMembers(gid)) !== JSON.stringify(parseMembers(list))) throw new Error(`group ${gid} already has another member list`);
    }
    try {
      await this.doc.send(new TransactWriteCommand({ TransactItems: [this.publishPut(groupItem(header), 'attribute_not_exists(#k)', { '#k': 'publish_id' }), this.auditPut(audit)] }));
      return { created: true, header };
    } catch (err) {
      if (!cancelledByCondition(err, 0)) throw err;
      return { created: false, header: (await this.getGroup(gid))! };
    }
  }

  async updateGroup(gid: string, fn: (cur: GroupRecord) => GroupRecord | undefined, audit?: AuditEntry): Promise<GroupRecord | undefined> {
    for (let attempt = 0; attempt < MAX_UPDATE_ATTEMPTS; attempt++) {
      const cur = await this.getGroup(gid);
      if (!cur) return undefined;
      const changed = fn(structuredClone(cur));
      if (changed === undefined) return cur;
      const next = { ...changed, rev: cur.rev + 1 };
      checkHeaderWrite(cur, next);
      const put = this.publishPut(groupItem(next), '#r = :r', { '#r': 'rev' }, { ':r': cur.rev });
      // A header that gains or loses its expiry (a group that ended, or was opened again) takes its member list along, in the
      // same transaction: the list expires after the header, and a reopened group keeps it.
      const list = next.expires_at !== cur.expires_at ? await this.publishItem(membersKey(gid)) : undefined;
      const together = list ? [{ Put: { TableName: this.tables.publishes, Item: membersWithExpiry(list, next.expires_at) } }] : [];
      try {
        if (audit || together.length > 0) await this.doc.send(new TransactWriteCommand({ TransactItems: [put, ...(audit ? [this.auditPut(audit)] : []), ...together] }));
        else await this.doc.send(new PutCommand(put.Put));
        return next;
      } catch (err) {
        if (putLost(err) || cancelledByCondition(err, 0)) continue;
        throw err;
      }
    }
    throw new RegistryError('internal_error', `Group ${gid} changed too often while updating.`, { group_id: gid });
  }

  async commitGroup(gid: string, c: { rev: number; writeOrder: number[]; now: string; audit: AuditEntry }): Promise<CommitOutcome> {
    // Read first: a commit whose answer was lost shows up here as the marker, and a stale `rev` must not look like a conflict.
    const cur = await this.getGroup(gid);
    if (!cur) return { outcome: 'missing' };
    if (cur.committed_at !== undefined) return { outcome: 'already', header: cur };
    if (cur.status !== 'validating' || cur.rev !== c.rev) return { outcome: 'conflict', header: cur };
    if (!(Date.parse(c.now) <= Date.parse(cur.deadline_at))) return { outcome: 'deadline', header: cur }; // a deadline that is not a time is past
    const next = committedRecord(cur, c.writeOrder, c.now);
    try {
      await this.doc.send(
        new TransactWriteCommand({
          ClientRequestToken: commitToken(gid, cur.attempt),
          TransactItems: [
            this.publishPut(groupItem(next), '#s = :s AND #r = :r', { '#s': 'status', '#r': 'rev' }, { ':s': 'validating', ':r': cur.rev }),
            this.auditPut(c.audit),
          ],
        }),
      );
      return { outcome: 'committed', header: next };
    } catch (err) {
      if (!cancelledByCondition(err, 0)) throw err;
      const now = (await this.getGroup(gid))!;
      return now.committed_at !== undefined ? { outcome: 'already', header: now } : { outcome: 'conflict', header: now };
    }
  }

  async adoptVersion(rec: VersionRecord, audit: AuditEntry, free: (cur: VersionRecord) => boolean): Promise<AdoptOutcome> {
    if (rec.state !== 'pending' || rec.group_id === undefined) throw new Error('adoptVersion takes a pending row that names a group');
    return this.adopt(rec, audit, free);
  }
  async adoptSingle(rec: VersionRecord, audit: AuditEntry, free: (cur: VersionRecord) => boolean): Promise<AdoptOutcome> {
    if (rec.state !== 'pending' || rec.group_id !== undefined) throw new Error('adoptSingle takes a pending row that names no group');
    return this.adopt(rec, audit, free);
  }
  private async adopt(rec: VersionRecord, audit: AuditEntry, free: (cur: VersionRecord) => boolean): Promise<AdoptOutcome> {
    const fresh = { ...rec, canonical: canonicalVersion(rec.version) };
    try {
      await this.doc.send(new TransactWriteCommand({ TransactItems: [this.versionPut(fresh, 'attribute_not_exists(#n)', { '#n': 'name' }), this.auditPut(audit)] }));
      return { outcome: 'created', record: fresh };
    } catch (err) {
      if (!cancelledByCondition(err, 0)) throw err;
    }
    const cur = (await this.rowOf(rec.name, rec.version))!; // rows are never deleted, so the one that stopped the create is still there
    if (cur.state !== 'pending' || !free(cur)) return { outcome: 'taken', existing: cur };
    const next = { ...fresh, rev: cur.rev + 1 };
    try {
      await this.doc.send(new TransactWriteCommand({ TransactItems: [this.versionPut(next, '#r = :r', { '#r': 'rev' }, { ':r': cur.rev }), this.auditPut(audit)] }));
      return { outcome: 'adopted', record: next };
    } catch (err) {
      if (cancelledByCondition(err, 0)) return { outcome: 'lost' };
      throw err;
    }
  }

  async applyGroupEvent(name: string, version: string, event: GroupEvent, audit: AuditEntry): Promise<VersionRecord> {
    return this.change(name, version, event, audit, false);
  }

  async putCommitInputs(gid: string, hash: string, inputs: readonly CommitInput[], expiresAt: number): Promise<void> {
    // Sixteen at a time: a group has up to 500 members, and the call that stores them has a few seconds.
    for (let i = 0; i < inputs.length; i += 16) {
      await Promise.all(
        inputs.slice(i, i + 16).map((input, k) => this.doc.send(new PutCommand({ TableName: this.tables.publishes, Item: commitInputItem(commitInputKey(gid, hash, i + k), input, expiresAt) }))),
      );
    }
  }
  async getCommitInput(gid: string, hash: string, index: number): Promise<CommitInput | undefined> {
    const i = await this.publishItem(commitInputKey(gid, hash, index));
    return i && parseCommitInput(i);
  }

  async listActiveGroups(): Promise<ActiveGroup[]> {
    const out: ActiveGroup[] = [];
    let start: Item | undefined;
    do {
      const r = await this.doc.send(
        new QueryCommand({
          TableName: this.tables.publishes,
          IndexName: 'by_sweep',
          KeyConditionExpression: '#p = :p',
          ExpressionAttributeNames: { '#p': 'sweep_pk' },
          ExpressionAttributeValues: { ':p': 'active' },
          Limit: 100,
          ExclusiveStartKey: start,
        }),
      );
      for (const i of r.Items ?? []) {
        const key = String(i.publish_id);
        if (!key.startsWith('grp#')) continue;
        out.push({
          group_id: key.slice('grp#'.length),
          status: i.status as GroupStatus,
          attempt: Number(i.attempt),
          actor: String(i.actor),
          rev: Number(i.rev),
          progress_at: String(i.progress_at),
          sweep_at: String(i.sweep_at),
          deadline_at: String(i.deadline_at),
          resend: Number(i.resend ?? 0),
        });
      }
      start = r.LastEvaluatedKey;
    } while (start);
    return out;
  }
  async listVersions(name: string) {
    return (await this.versionsOf([name], API_VIEW)).get(name)!;
  }
  async versionsOf(names: readonly string[], view: View) {
    return this.funnel.versionsOf(names, view);
  }
  private async rowsOf(name: string) {
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
    return out;
  }

  // Owners: sort key github_id is a string in the table.
  async addOwner(o: OwnerRecord): Promise<void> {
    try {
      await this.doc.send(
        new PutCommand({
          TableName: this.tables.owners,
          Item: ownerItem(o),
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
