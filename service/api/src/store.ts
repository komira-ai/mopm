import { compareVersions } from './version';
import type { VersionEvent } from './state';
import type { AuditEntry, OwnerRecord, PackageRecord, PackageSummaryRecord, VersionRecord } from './types';

/**
 * The registry's persistence port. Two adapters implement it: memory (tests and the local mode) and
 * DynamoDB. Rules every adapter keeps:
 *
 * - A (name, version) is created at most once, ever: a second `createVersion` of `1.0.0` fails with
 *   version_exists, whatever state the first one is in (a tombstone keeps the number burned). Two concurrent creates: exactly one wins.
 * - Every change to a version also appends its audit entry, atomically with it.
 * - Version rows are never deleted.
 */
export interface Store {
  /** Create-once. Throws name_taken when the package exists. */
  createPackage(pkg: PackageRecord): Promise<void>;
  getPackage(name: string): Promise<PackageRecord | undefined>;
  listPackageNames(): Promise<string[]>;
  /**
   * Packages whose name starts with `prefix` (empty matches all), ordered by name, strictly after `after`,
   * at most `limit`. This is the read path of search: the DynamoDB adapter answers it with one Query on the
   * name index (never a Scan), so it can only return the attributes that index projects.
   */
  searchPackages(prefix: string, after: string | undefined, limit: number): Promise<PackageSummaryRecord[]>;

  /** Create-once, with its audit entry. Throws invalid_version, version_exists. */
  createVersion(rec: VersionRecord, audit: AuditEntry): Promise<void>;
  /** Throws invalid_version for anything that is not MAJOR.MINOR.PATCH. */
  getVersion(name: string, version: string): Promise<VersionRecord | undefined>;
  /**
   * Apply an event through the state machine and persist it with its audit entry, retrying on a
   * concurrent change. Throws version_not_found (missing, or an event the state refuses).
   */
  updateVersion(name: string, version: string, event: VersionEvent, audit: AuditEntry): Promise<VersionRecord>;
  /** Oldest to newest by conda ordering. */
  listVersions(name: string): Promise<VersionRecord[]>;

  addOwner(owner: OwnerRecord): Promise<void>; // already_owner
  removeOwner(name: string, githubId: number): Promise<void>; // owner_not_found
  listOwners(name: string): Promise<OwnerRecord[]>; // by github_id

  appendAudit(entry: AuditEntry): Promise<void>;
  /** Oldest first. */
  listAudit(name: string): Promise<AuditEntry[]>;
}

export const byVersion = (a: VersionRecord, b: VersionRecord) => compareVersions(a.version, b.version);

/** Audit rows are keyed by time then id, so they sort oldest first and never collide. */
export const auditSortKey = (e: Pick<AuditEntry, 'ts' | 'id'>) => `${e.ts}#${e.id}`;
