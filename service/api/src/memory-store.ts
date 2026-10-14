import { RegistryError, versionExists } from './errors';
import { applyEvent, type VersionEvent } from './state';
import { auditSortKey, byVersion, type Store } from './store';
import type { AuditEntry, OwnerRecord, PackageRecord, PackageSummaryRecord, VersionRecord } from './types';
import { canonicalVersion } from './version';

const copy = <T>(v: T): T => structuredClone(v);

/**
 * In-memory adapter. Every method runs its read-check-write without awaiting in between, so each is
 * atomic on the event loop, which is the property DynamoDB gives the other adapter with conditions.
 */
export class MemoryStore implements Store {
  private packages = new Map<string, PackageRecord>();
  private versions = new Map<string, VersionRecord>(); // `${name}\0${canonical}`
  private owners = new Map<string, OwnerRecord>(); // `${name}\0${github_id}`
  private audit: AuditEntry[] = [];

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
    const r = this.versions.get(`${name}\0${canonicalVersion(version)}`);
    return r && copy(r);
  }
  async updateVersion(name: string, version: string, event: VersionEvent, audit: AuditEntry): Promise<VersionRecord> {
    const key = `${name}\0${canonicalVersion(version)}`;
    const cur = this.versions.get(key);
    if (!cur) throw new RegistryError('version_not_found', `'${name}' has no version '${version}'.`, { name, version });
    const next = applyEvent(cur, event);
    if (next !== cur) {
      this.versions.set(key, copy(next));
      this.audit.push(copy(audit));
    }
    return copy(next);
  }
  async listVersions(name: string) {
    return [...this.versions.values()].filter((v) => v.name === name).map(copy).sort(byVersion);
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
