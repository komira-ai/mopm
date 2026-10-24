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
  /**
   * The group this version is a member of, when it was published as part of one. Absent on every row written by a
   * single publish. A `pending` row with a group is shown as `published` only through the store's projection
   * (src/group.ts): when the group's header is committed and `staged_attempt` is the header's `attempt`.
   */
  group_id?: string;
  /** The group attempt that filled this row. Set in the same write that fills a group member; absent before. */
  staged_attempt?: number;
  /**
   * Epoch seconds. Set on a reserved row of a group (the end of the group's deadline plus a tail), and removed by the write
   * that publishes or burns the row. Once it has passed, a `pending` row whose group header is gone (a dead group's header
   * is given a TTL, see src/publish/group-lifecycle.ts) is free for any group or single to take. A row without it is never
   * free that way, and a committed group's header never expires.
   */
  free_after?: number;
  /**
   * Set on a row that a group yank changed (`group_yank`, src/state.ts), to the sequence number of that yank (`GroupYank.seq`, src/group-store.ts),
   * and removed by anything that moves the row on (an unyank by hand or by the group, a tombstone). The group unyank restores a row only while
   * it still carries the marker of the yank it undoes, so a member somebody yanked by hand is never restored by it.
   */
  group_yank_seq?: number;
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
