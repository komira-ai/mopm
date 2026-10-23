import { RegistryError, versionExists } from './errors';
import { API_VIEW, headerKey, membersKey, parseHeader, parseMembers, VersionFunnel, type FunnelOptions, type GroupReader, type View } from './group';
import type { RawVersionPort } from './raw-port';
import { applyEvent, IllegalTransition, type VersionEvent } from './state';
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
export class MemoryStore implements Store {
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
  async updateVersion(name: string, version: string, event: VersionEvent, audit: AuditEntry): Promise<VersionRecord> {
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