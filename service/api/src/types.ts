/** A conda subdir. New values may be added (spec), so this is a string, with the four v1 values listed. */
export type Subdir = string;
export const SUBDIRS_V1: readonly Subdir[] = ['linux-64', 'linux-aarch64', 'noarch', 'osx-arm64'];

/** `pending` exists only inside the registry: a reserved number whose files are not yet committed. */
export type VersionState = 'pending' | 'published' | 'yanked' | 'tombstoned';

export interface FileRef {
  subdir: Subdir;
  filename: string;
  sha256: string;
  size: number;
  /** Absent once tombstoned. */
  url?: string;
}

export interface Dep {
  name: string;
  range?: string;
}

export interface NativeRef {
  id: string;
  soname: string;
}

export interface Tombstone {
  reason_code: string;
  /** YYYY-MM-DD */
  date: string;
}

export interface VersionRecord {
  name: string;
  /** The spelling that was published (and is in the file name). */
  version: string;
  /** The key create-once is enforced on (the version itself: a version has one spelling). */
  canonical: string;
  build: string;
  state: VersionState;
  yank_reason?: string;
  tombstone?: Tombstone;
  published_at: string;
  published_by?: string;
  requires_mojo: string;
  deps: Dep[];
  native: NativeRef[];
  files: FileRef[];
  manifest_sha256: string;
  /** Where the files were built, when a CI identity vouched for it. Absent means no provenance (`kind: none`). */
  provenance?: { kind: 'none' | 'oidc'; repository?: string; workflow_ref?: string };
  /**
   * Display metadata from the package's mopm.toml [package] table (spec/mopm-toml.md), as of this version.
   * Stored and served when present; the publish pipeline is what populates them.
   */
  description?: string;
  license?: string;
  repository?: string;
  homepage?: string;
  keywords?: string[];
  /** Markdown, at most README_MAX_BYTES of UTF-8. */
  readme?: string;
  /** Optimistic-concurrency counter: starts at 0, +1 on every state change. */
  rev: number;
}

export interface PackageRecord {
  name: string;
  state: 'claimed' | 'active';
  created_at: string;
  repository?: string;
  license?: string;
  description?: string;
  homepage?: string;
  keywords?: string[];
}

/** The most readme text, in UTF-8 bytes, the API serves. */
export const README_MAX_BYTES = 65536;

/** What a package search needs from a package; the search index projects exactly these attributes. */
export type PackageSummaryRecord = Pick<PackageRecord, 'name' | 'state' | 'created_at' | 'description'>;

export interface OwnerRecord {
  name: string;
  github_id: number;
  handle: string;
  added_at: string;
}

export interface AuditEntry {
  name: string;
  /** RFC 3339 */
  ts: string;
  /** Unique within the package; with `ts` it forms the append-only key. */
  id: string;
  actor: string;
  action: string;
  version?: string;
  detail?: Record<string, string>;
}
