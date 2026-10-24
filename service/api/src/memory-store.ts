import { RegistryError, versionExists } from './errors';
import { API_VIEW, headerKey, membersKey, parseHeader, parseMembers, VersionFunnel, type FunnelOptions, type GroupMembers, type GroupReader, type View } from './group';
import {
  checkHeaderWrite,
  commitInputItem,
  commitInputKey,
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
import { applyEvent, IllegalTransition, type GroupEvent, type UserEvent } from './state';
import { auditSortKey, type Store } from './store';
import type { AuditEntry, OwnerRecord, PackageRecord, PackageSummaryRecord, VersionRecord } from './types';
import { canonicalVersion } from './version';

const copy = <T>(v: T): T => structuredClone(v);

const MAX_UPDATE_ATTEMPTS = 5;

/** The group items of the `publishes` table, in memory: what a test (or the local mode) puts there is what the funnel reads. */
export class MemoryGroupItems implements GroupReader {
  private readonly items = new Map<string, Record<string, unknown>>();
  /** The keys read, in order, so a test can assert what a read asked for. */
  readonly reads: string[] = [];
  /** When set, every read throws it (a throttle, an outage). */
  failure?: Error;

  put(key: string, item: Record<string, unknown>): void {
    this.items.set(key, copy(item));
  }
  /** Create-once: false (and nothing written) when the key is taken. For the writers; it is not a read. */
  create(key: string, item: Record<string, unknown>): boolean {
    if (this.items.has(key)) return false;
    this.items.set(key, copy(item));
    return true;
  }
  /** The item as stored, for the writers (a reader goes through `header` and `members`, which are logged). */
  peek(key: string): Record<string, unknown> | undefined {
    const i = this.items.get(key);
    return i && copy(i);
  }
  /** Every item with its key, for the writers' scans (the sweeper's index). */
  entries(): Array<[string, Record<string, unknown>]> {
    return [...this.items.entries()].map(([k, v]) => [k, copy(v)]);
  }
  private read(key: string) {
    this.reads.push(key);
    if (this.failure) throw this.failure;
    const i = this.items.get(key);
    return i && copy(i);
  }
  async header(gid: string) {
    const i = this.read(headerKey(gid));
    return i && parseHeader(i);
  }
  async members(gid: string) {
    const i = this.read(membersKey(gid));
    return i && parseMembers(i);
  }
}

/**
 * In-memory adapter. Every method runs its read-check-write without awaiting in between (an update re-checks the
 * revision after its reads), so each is atomic on the event loop, which is the property DynamoDB gives the other
 * adapter with conditions.
 */
export class MemoryStore implements Store, GroupStore {
  private packages = new Map<string, PackageRecord>();
  private versions = new Map<string, VersionRecord>(); // `${name}\0${canonical}`
  private owners = new Map<string, OwnerRecord>(); // `${name}\0${github_id}`
  private audit: AuditEntry[] = [];

  /** The rows as stored (src/raw-port.ts): for the group module and for tests that must see the stored form. */
  readonly raw: RawVersionPort = {
    rawGet: async (name, version) => {
      const r = this.versions.get(`${name}\0${canonicalVersion(version)}`);
      return r && copy(r);
    },
    rawQuery: async (name) => [...this.versions.values()].filter((v) => v.name === name).map(copy),
  };
  private readonly funnel: VersionFunnel;

  constructor(
    readonly groups: MemoryGroupItems = new MemoryGroupItems(),
    funnel: FunnelOptions = {},
  ) {
    this.funnel = new VersionFunnel(this.raw, groups, funnel);
  }

  async createPackage(pkg: PackageRecord): Promise<void> {
    if (this.packages.has(pkg.name)) throw new RegistryError('name_taken', `'${pkg.name}' is already taken.`, { name: pkg.name });
    this.packages.set(pkg.name, copy(pkg));
  }
  async getPackage(name: string) {
    const p = this.packages.get(name);
    return p && copy(p);
  }
  async listPackageNames() {
    return [...this.packages.keys()].sort();
  }

  async searchPackages(prefix: string, after: string | undefined, limit: number): Promise<PackageSummaryRecord[]> {
    return [...this.packages.values()]
      .filter((p) => p.name.startsWith(prefix) && (after === undefined || p.name > after))
      .sort((a, b) => (a.name < b.name ? -1 : 1))
      .slice(0, limit)
      .map((p) => copy({ name: p.name, state: p.state, created_at: p.created_at, ...(p.description === undefined ? {} : { description: p.description }) }));
  }

  async createVersion(rec: VersionRecord, audit: AuditEntry): Promise<void> {
    const canonical = canonicalVersion(rec.version);
    const key = `${rec.name}\0${canonical}`;
    const existing = this.versions.get(key);
    if (existing) throw versionExists(rec.name, rec.version, existing.files[0]?.sha256 ?? existing.manifest_sha256);
    this.versions.set(key, copy({ ...rec, canonical }));
    this.audit.push(copy(audit));
  }
  async getVersion(name: string, version: string) {
    return this.funnel.getOne(name, version);
  }
  async updateVersion(name: string, version: string, event: UserEvent, audit: AuditEntry): Promise<VersionRecord> {
    const key = `${name}\0${canonicalVersion(version)}`;
    for (let attempt = 0; attempt < MAX_UPDATE_ATTEMPTS; attempt++) {
      // The row as a reader sees it: a member of a committed group is `published` here, and one of a group that has
      // not committed stays `pending` and cannot be changed through this port.
      const cur = await this.funnel.getOne(name, version);
      if (!cur) throw new RegistryError('version_not_found', `'${name}' has no version '${version}'.`, { name, version });
      if (cur.group_id !== undefined && cur.state === 'pending') throw new IllegalTransition(cur, event);
      const next = applyEvent(cur, event);
      if (next === cur) return copy(cur);
      if (this.versions.get(key)?.rev !== cur.rev) continue; // changed while the group was being read
      this.versions.set(key, copy(next));
      this.audit.push(copy(audit));
      return copy(next);
    }
    throw new RegistryError('internal_error', `'${name}' ${version} changed too often while updating.`, { name, version });
  }
  // --- the writers of a group (src/group-store.ts) ----------------------------------------------------------------
  // Each method reads and writes without awaiting in between, so it is atomic on the event loop, as the
  // transactions and conditions of the DynamoDB adapter are.

  private headerOf(gid: string): GroupRecord | undefined {
    const i = this.groups.peek(headerKey(gid));
    return i && parseGroupRecord(i);
  }
  private membersOf(gid: string): GroupMembers | undefined {
    const i = this.groups.peek(membersKey(gid));
    return i && parseMembers(i);
  }
  async getGroup(gid: string): Promise<GroupRecord | undefined> {
    return this.headerOf(gid);
  }
  async getGroupMembers(gid: string): Promise<GroupMembers | undefined> {
    return this.membersOf(gid);
  }

  async createGroup(header: GroupRecord, members: GroupMembers, audit: AuditEntry): Promise<{ created: boolean; header: GroupRecord }> {
    checkHeaderWrite(undefined, header);
    const gid = header.group_id;
    const list = membersItem(gid, members);
    if (!this.groups.create(membersKey(gid), list) && JSON.stringify(this.membersOf(gid)) !== JSON.stringify(parseMembers(list))) {
      throw new Error(`group ${gid} already has another member list`);
    }
    if (!this.groups.create(headerKey(gid), groupItem(header))) return { created: false, header: this.headerOf(gid)! };
    this.audit.push(copy(audit));
    return { created: true, header };
  }

  async updateGroup(gid: string, fn: (cur: GroupRecord) => GroupRecord | undefined, audit?: AuditEntry): Promise<GroupRecord | undefined> {
    const cur = this.headerOf(gid);
    if (!cur) return undefined;
    const changed = fn(structuredClone(cur));
    if (changed === undefined) return cur;
    const next = { ...changed, rev: cur.rev + 1 };
    checkHeaderWrite(cur, next);
    this.groups.put(headerKey(gid), groupItem(next));
    // A header that gains or loses its expiry takes its member list along (as the DynamoDB adapter does, in one transaction).
    if (next.expires_at !== cur.expires_at) {
      const list = this.groups.peek(membersKey(gid));
      if (list) this.groups.put(membersKey(gid), membersWithExpiry(list, next.expires_at));
    }
    if (audit) this.audit.push(copy(audit));
    return next;
  }

  async commitGroup(gid: string, c: { rev: number; writeOrder: number[]; now: string; audit: AuditEntry }): Promise<CommitOutcome> {
    const cur = this.headerOf(gid);
    if (!cur) return { outcome: 'missing' };
    if (cur.committed_at !== undefined) return { outcome: 'already', header: cur };
    if (cur.status !== 'validating' || cur.rev !== c.rev) return { outcome: 'conflict', header: cur };
    if (!(Date.parse(c.now) <= Date.parse(cur.deadline_at))) return { outcome: 'deadline', header: cur }; // a deadline that is not a time is past
    const next = committedRecord(cur, c.writeOrder, c.now);
    this.groups.put(headerKey(gid), groupItem(next));
    this.audit.push(copy(c.audit));
    return { outcome: 'committed', header: next };
  }

  async adoptVersion(rec: VersionRecord, audit: AuditEntry, free: (cur: VersionRecord) => boolean): Promise<AdoptOutcome> {
    if (rec.state !== 'pending' || rec.group_id === undefined) throw new Error('adoptVersion takes a pending row that names a group');
    return this.adopt(rec, audit, free);
  }
  async adoptSingle(rec: VersionRecord, audit: AuditEntry, free: (cur: VersionRecord) => boolean): Promise<AdoptOutcome> {
    if (rec.state !== 'pending' || rec.group_id !== undefined) throw new Error('adoptSingle takes a pending row that names no group');
    return this.adopt(rec, audit, free);
  }
  private adopt(rec: VersionRecord, audit: AuditEntry, free: (cur: VersionRecord) => boolean): AdoptOutcome {
    const canonical = canonicalVersion(rec.version);
    const key = `${rec.name}\0${canonical}`;
    const fresh = { ...rec, canonical };
    const cur = this.versions.get(key);
    if (cur === undefined) {
      this.versions.set(key, copy(fresh));
      this.audit.push(copy(audit));
      return { outcome: 'created', record: copy(fresh) };
    }
    if (cur.state !== 'pending' || !free(copy(cur))) return { outcome: 'taken', existing: copy(cur) };
    const next = { ...fresh, rev: cur.rev + 1 };
    this.versions.set(key, copy(next));
    this.audit.push(copy(audit));
    return { outcome: 'adopted', record: copy(next) };
  }

  async applyGroupEvent(name: string, version: string, event: GroupEvent, audit: AuditEntry): Promise<VersionRecord> {
    const key = `${name}\0${canonicalVersion(version)}`;
    const cur = this.versions.get(key);
    if (!cur) throw new RegistryError('version_not_found', `'${name}' has no version '${version}'.`, { name, version });
    const next = applyEvent(cur, event);
    if (next === cur) return copy(cur);
    this.versions.set(key, copy(next));
    this.audit.push(copy(audit));
    return copy(next);
  }

  async putCommitInputs(gid: string, hash: string, inputs: readonly CommitInput[], expiresAt: number): Promise<void> {
    inputs.forEach((input, i) => {
      const key = commitInputKey(gid, hash, i);
      this.groups.put(key, commitInputItem(key, input, expiresAt));
    });
  }
  async getCommitInput(gid: string, hash: string, index: number): Promise<CommitInput | undefined> {
    const i = this.groups.peek(commitInputKey(gid, hash, index));
    return i && parseCommitInput(i);
  }

  async listActiveGroups(): Promise<ActiveGroup[]> {
    const out: ActiveGroup[] = [];
    for (const [key, i] of this.groups.entries()) {
      if (!key.startsWith('grp#') || i.sweep_pk !== 'active') continue;
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
    return out;
  }

  async listVersions(name: string) {
    return (await this.versionsOf([name], API_VIEW)).get(name)!;
  }
  async versionsOf(names: readonly string[], view: View) {
    return this.funnel.versionsOf(names, view);
  }

  async addOwner(o: OwnerRecord): Promise<void> {
    const key = `${o.name}\0${o.github_id}`;
    if (this.owners.has(key)) throw new RegistryError('already_owner', `'${o.handle}' already owns '${o.name}'.`, { name: o.name });
    this.owners.set(key, copy(o));
  }
  async removeOwner(name: string, githubId: number): Promise<void> {
    if (!this.owners.delete(`${name}\0${githubId}`)) {
      throw new RegistryError('owner_not_found', 'That account is not an owner of the package.', { name });
    }
  }
  async listOwners(name: string) {
    return [...this.owners.values()].filter((o) => o.name === name).map(copy).sort((a, b) => a.github_id - b.github_id);
  }

  async appendAudit(entry: AuditEntry): Promise<void> {
    this.audit.push(copy(entry));
  }
  async listAudit(name: string) {
    return this.audit.filter((e) => e.name === name).map(copy).sort((a, b) => (auditSortKey(a) < auditSortKey(b) ? -1 : 1));
  }
}