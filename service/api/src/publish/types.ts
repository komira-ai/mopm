import type { RejectionCode } from '../validate';
import type { DisplayMeta } from './display';

/** `u:<github id>` for an account's token, `ci:<token id>` for a CI identity's token. */
export type Actor = string;

/** One file of a version, announced by begin-upload. The presigned URL points at `key` in quarantine. */
export interface UploadRecord {
  upload_id: string;
  name: string;
  /** The spelling the caller used; commit must use the same one. */
  version: string;
  canonical: string;
  subdir: string;
  filename: string;
  sha256: string;
  size: number;
  /** quarantine/<upload id>/<filename> */
  key: string;
  actor: Actor;
  created_at: string;
  url_expires_at: string;
  /** Epoch seconds: the table's TTL attribute (lazy cleanup) and the end of the commit window. */
  expires_at: number;
  /** Set when a commit takes the upload; single use. */
  used_by?: string;
}

export type PublishStatus = 'pending' | 'validating' | 'indexing' | 'published' | 'rejected';

export interface PublishFile {
  upload_id: string;
  subdir: string;
  filename: string;
  sha256: string;
  size: number;
  key: string;
}

export interface PublishRecord {
  publish_id: string;
  name: string;
  version: string;
  canonical: string;
  actor: Actor;
  published_by: string;
  status: PublishStatus;
  rejection_code?: RejectionCode;
  message?: string;
  manifest_sha256: string;
  /** Display metadata from the commit request (description, license, repository, homepage, keywords, readme). */
  display?: DisplayMeta;
  files: PublishFile[];
  /** Subdirs whose repodata does not yet list this publish (set when the version is published). */
  remaining_subdirs: string[];
  /**
   * Set by the job that lists the last subdir: the repodata is done, the package's sparse-index file is not.
   * The publish becomes `published` when that file is written. Separate from `remaining_subdirs`, which only
   * ever holds conda subdirs.
   */
  index_pending?: boolean;
  created_at: string;
  updated_at: string;
  /** Optimistic-concurrency counter, +1 per change. */
  rev: number;
}

/** What the validator queue carries. */
export interface ValidateMessage {
  type: 'validate';
  publish_id: string;
}
/** What the index queue carries. Without a publish id it is a plain rebuild (init, a later yank). */
export interface IndexMessage {
  type: 'index';
  subdir: string;
  publish_id?: string;
  /**
   * Gate for a change the CLI must not see in the sparse index before repodata shows it (unyank): once this
   * subdir is rewritten, rewrite `next[0]` (carrying the rest), and after the last one send `index_pkg`.
   */
  then?: { name: string; rev: number; next: string[] };
}
/**
 * Rewrite `index/<aa>/<bb>/<name>` from the package's rows as they are when the job runs (not as they were when
 * it was sent). `rev` is `packageRev` at send time; it only separates dedup ids. FIFO group `pkg:<name>`.
 */
export interface IndexPkgMessage {
  type: 'index_pkg';
  name: string;
  rev: number;
  /** The publish to move to `published` once the file is written. */
  publish_id?: string;
}
/** Rebuild `index/takedowns.json` from every tombstoned row. FIFO group `takedowns`. */
export interface IndexTakedownsMessage {
  type: 'index_takedowns';
}
export type IndexQueueMessage = IndexMessage | IndexPkgMessage | IndexTakedownsMessage;

/**
 * What the group queue carries: run (or go on with) the validation of one attempt of a group. `n` counts the messages
 * a validator sent itself to go on after its time budget (it is part of their dedup id).
 */
export interface ValidateGroupMessage {
  type: 'validate_group';
  group_id: string;
  attempt: number;
  n: number;
}
