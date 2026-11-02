import { createHash } from 'node:crypto';
import { headerKey, membersKey, type GroupMembers } from './group';
import type { GroupEvent } from './state';
import type { DisplayMeta } from './publish/display';
import type { AuditEntry, VersionRecord } from './types';

/**
 * What the store writes for a group (design: a header item and a member list in the `publishes` table, audit rows in the
 * audit table). The readers' view of the same items is in src/group.ts (`parseHeader`, `parseMembers`); this file is the
 * writers' view.
 *
 * Every write is a Put with a condition (create-once, or a compare on `rev`) or a TransactWriteItems of Puts: the roles
 * have GetItem and PutItem on these tables and nothing else, so there is no UpdateItem and no DeleteItem anywhere here
 * (the stacks' iam-wire-coverage test holds the recorded requests to that).
 */

export type GroupStatus = 'open' | 'validating' | 'committed' | 'visible' | 'rejected' | 'failed' | 'expired' | 'aborted' | 'superseded';

/** The statuses of a group that has committed. The marker is `committed_at`; a status never stands in for it. */
export const COMMITTED_STATUSES: readonly GroupStatus[] = ['committed', 'visible'];

/** Where a group yank is: `yanking` and `unyanking` are running, `yanked` and `restored` are at rest. A group that was never yanked has no `yank`. */
export type GroupYankState = 'yanking' | 'yanked' | 'unyanking' | 'restored';

/**
 * The yank intent of a group (src/publish/group-yank.ts), on the header of a group that is `visible`. The group stays `visible` while it
 * is yanked: its rows are `yanked` rows, and the readers' projection (src/group.ts) only ever looks at `pending` ones.
 */
export interface GroupYank {
  reason: string;
  /** The actor that asked for the yank. */
  by: string;
  requested_at: string;
  /** Bitmap of the members this yank changed: the only ones an unyank restores. Saved after each batch of rows. */
  yanked_set: string;
  /** The number of this yank (1 for a group's first, +1 for each yank after an unyank). Rows the yank changed carry it (`group_yank_seq`). */
  seq: number;
  state: GroupYankState;
  /** The running yank or unyank has changed every row it will: what is left is the repodata hops, the index hops and the end. */
  rows_done?: boolean;
  /** Gates of the running yank or unyank's own hops (the repodata subdirs, and positions in `write_order`), as `repodata_released` and `index_released` are for the commit's chain. */
  repodata_done?: string[];
  index_done?: number[];
  /** Who asked for the unyank, and when. */
  unyank_by?: string;
  unyank_at?: string;
}

/** A group's header item, `grp#<group id>`. A few KB at the largest group, because the member list is its own item. */
export interface GroupRecord {
  group_id: string;
  status: GroupStatus;
  /** The attempt a staged row must carry to count. Starts at 1; a reopened group is attempt + 1. */
  attempt: number;
  /** Compare-and-set counter: starts at 0, +1 on every write of the header. */
  rev: number;
  actor: string;
  /** Set when the group was made through a CI identity acting for the actor (`ci:gh-repo:<repository id>`); absent for the account's own group. */
  via?: string;
  member_count: number;
  created_at: string;
  /** Not `expires_at`: the table's TTL is on that name, and a live group must never expire. */
  deadline_at: string;
  progress_at: string;
  /** Set once, by `commitGroup`, never unset. This is the marker readers test. */
  committed_at?: string;
  /** Member indexes in dependency order. Set by `commitGroup`. */
  write_order?: number[];
  /** Checkpoint bitmaps over member indexes (see `bitmapSet`). */
  reserved: string;
  validated: string;
  staged: string;
  copied: string;
  flipped: string;
  /** Release gates of the builders. */
  repodata_released?: string[];
  index_released?: number[];
  /**
   * Resends of the validate message by the sweeper since the group last made progress (the validator sets it back to 0
   * when it does). Part of the dedup id of a resend, so each resend is a new message.
   */
  resend: number;
  cursor?: number;
  yank?: GroupYank;
  /** How far validation got: 1 while the archives are checked, 2 once copying into the channel has begun, 3 once every file is there. Set before the step it names starts. */
  phase?: number;
  /** Hash of the commit request the group is validating (see `commitRequestHash`): the commit inputs are stored under it. */
  commit_hash?: string;
  /** Why a group was rejected or failed. */
  failure?: GroupFailure;
  /** Present while the group is not terminal (for the sweeper's index). */
  sweep_pk?: string;
  sweep_at?: string;
  /**
   * Epoch seconds, the table's TTL. Only a group that ended without committing has one (`ended`, src/publish/group-lifecycle.ts); a
   * group that committed never does (`checkHeaderWrite`).
   */
  expires_at?: number;
}

/** The verdict that ended a group: a stable code, and the words for the caller. `member` names the package it is about, when it is about one. */
export interface GroupFailure {
  code: string;
  message: string;
  member?: string;
}

/** The statuses of a group that ended without committing: the only ones a header may carry an expiry in. */
export const UNCOMMITTED_END: readonly GroupStatus[] = ['rejected', 'failed', 'expired', 'aborted', 'superseded'];

/** The manifest and display fields the commit request carried for one member. They are too large for the header, so each member's are an item of their own. */
export interface CommitInput {
  name: string;
  /** Absent when the request left it out: the validator then uses the hash it computes. */
  manifest_sha256?: string;
  display?: DisplayMeta;
  /** The member's `source_commit`, when the request carried one. */
  source_commit?: string;
}

/** A group in the sweeper's index: what the `by_sweep` index projects (the stacks' data stack), not the whole header. */
export interface ActiveGroup {
  group_id: string;
  status: GroupStatus;
  attempt: number;
  actor: string;
  rev: number;
  progress_at: string;
  sweep_at: string;
  deadline_at: string;
  resend: number;
}

type Item = Record<string, unknown>;

/** A header as the item stored under `grp#<id>`. */
export const groupItem = (g: GroupRecord): Item => ({ ...JSON.parse(JSON.stringify(g)), publish_id: headerKey(g.group_id) });
export const parseGroupRecord = (item: Item): GroupRecord => {
  const { publish_id: _key, ...rest } = item;
  return rest as unknown as GroupRecord;
};
/** The member list as the item stored under `grpm#<id>`. Written once, never changed. */
export const membersItem = (gid: string, m: GroupMembers): Item => ({ ...JSON.parse(JSON.stringify(m)), publish_id: membersKey(gid) });

// --- bitmaps ------------------------------------------------------------------------------------------------------

/** A bitmap over member indexes: hex, four members to a character, lowest index first; missing characters are zero. */
export function bitmapSet(bitmap: string, index: number): string {
  const at = Math.floor(index / 4);
  const chars = bitmap.padEnd(at + 1, '0').split('');
  chars[at] = (parseInt(chars[at]!, 16) | (1 << index % 4)).toString(16);
  return chars.join('');
}
export const bitmapHas = (bitmap: string, index: number): boolean => ((parseInt(bitmap[Math.floor(index / 4)] ?? '0', 16) >> index % 4) & 1) === 1;
export const bitmapIndexes = (bitmap: string): number[] => [...bitmap].flatMap((c, at) => [0, 1, 2, 3].filter((b) => (parseInt(c, 16) >> b) & 1).map((b) => at * 4 + b));

// --- the commit ---------------------------------------------------------------------------------------------------

/**
 * `ClientRequestToken` of the commit transaction: the first 32 hex characters of sha256("commit|<group>|<attempt>")
 * (DynamoDB allows 36). The same attempt of the same group always sends the same token, so a retry that DynamoDB still
 * remembers is the same request, not a second one.
 */
export const commitToken = (gid: string, attempt: number): string => createHash('sha256').update(`commit|${gid}|${attempt}`).digest('hex').slice(0, 32);

/** The header a commit writes: committed at `now`, in the given write order, one revision on. */
export const committedRecord = (cur: GroupRecord, writeOrder: number[], now: string): GroupRecord => ({
  ...cur,
  status: 'committed',
  committed_at: now,
  write_order: writeOrder,
  progress_at: now,
  rev: cur.rev + 1,
});

/**
 * What a header write may not do: the marker is written by the commit alone, so an update leaves `committed_at` as it
 * is, and `committed_at` is present exactly while the status is one of a committed group. Throws.
 */
export function checkHeaderWrite(cur: GroupRecord | undefined, next: GroupRecord): void {
  // The commit refuses a group past its deadline by comparing times; a deadline that is not a time compares as neither
  // past nor not, so it must never be stored.
  if (!Number.isFinite(Date.parse(next.deadline_at))) throw new Error(`group ${next.group_id}: deadline_at '${String(next.deadline_at)}' is not a time`);
  if (cur !== undefined && cur.group_id !== next.group_id) throw new Error(`group ${next.group_id}: the header read is group ${cur.group_id}`);
  if (next.committed_at !== cur?.committed_at) throw new Error(`group ${next.group_id}: committed_at is written by commitGroup alone`);
  if ((next.committed_at !== undefined) !== COMMITTED_STATUSES.includes(next.status)) {
    throw new Error(`group ${next.group_id}: status ${next.status} does not match committed_at`);
  }
  // An expiry is for a group that ended without committing. A committed group is never given one, whatever else is wrong:
  // the TTL would delete the marker its readers test.
  if (next.expires_at !== undefined && (next.committed_at !== undefined || !UNCOMMITTED_END.includes(next.status))) {
    throw new Error(`group ${next.group_id}: expires_at is only for a group that ended without committing (status ${next.status})`);
  }
}

/** First 16 hex characters of the sha256 of the commit request's canonical form: names the set of inputs the request stored. */
export const commitRequestHash = (canonical: string): string => createHash('sha256').update(canonical).digest('hex').slice(0, 16);

/** `publishes` key of one member's commit input. */
export const commitInputKey = (gid: string, hash: string, index: number): string => `grpc#${gid}#${hash}#${index}`;

/**
 * The id of the audit row of a change to a member. Deterministic, so that a redelivered write meets its own audit row and
 * no other. (The audit rows of the group itself are kept under the name `grp#<group id>`, `headerKey`, in the audit table.)
 */
export const memberAuditId = (gid: string, index: number): string => `a_${gid}_${index}`;

// --- the port -----------------------------------------------------------------------------------------------------

export type CommitOutcome =
  /** This call wrote the marker. */
  | { outcome: 'committed'; header: GroupRecord }
  /** The marker was already there (an earlier call whose answer was lost, or another worker). Nothing was written. */
  | { outcome: 'already'; header: GroupRecord }
  /** The header is not `validating` at the revision the caller read: nothing was written. */
  | { outcome: 'conflict'; header: GroupRecord }
  /** `now` is past `deadline_at`: nothing was written. */
  | { outcome: 'deadline'; header: GroupRecord }
  | { outcome: 'missing' };

export type AdoptOutcome =
  | { outcome: 'created'; record: VersionRecord }
  | { outcome: 'adopted'; record: VersionRecord }
  /** The number is held by a row that is not free (the caller said so, or it is not `pending`). */
  | { outcome: 'taken'; existing: VersionRecord }
  /** The row changed between the read and the write: nothing was written. */
  | { outcome: 'lost' };

/**
 * The writers' side of a group, on both store adapters. Nothing here is reachable from a route in this change.
 * Reads of version rows for readers stay on `Store`; these methods read and write the rows as stored.
 */
export interface GroupStore {
  /**
   * Write the member list (create-once, immutable) and then the header with its audit row, both create-once.
   * `created` is false when the header already existed; the existing header is returned then. Throws when the group
   * already has another member list, or when `header` carries a commit marker.
   */
  createGroup(header: GroupRecord, members: GroupMembers, audit: AuditEntry): Promise<{ created: boolean; header: GroupRecord }>;
  /** Consistent reads. */
  getGroup(gid: string): Promise<GroupRecord | undefined>;
  getGroupMembers(gid: string): Promise<GroupMembers | undefined>;
  /**
   * Read the header, let `fn` return the next one (undefined: no change), and write it only if `rev` is unchanged,
   * retrying on a lost race. `rev` is set to the read one + 1. With `audit`, the audit row is written in the same
   * transaction; it is create-once, so a retried change must not send the same audit row twice. Returns the header as
   * it is afterwards, or undefined when there is none. Throws when `fn` would change `committed_at` (see `checkHeaderWrite`).
   */
  updateGroup(gid: string, fn: (cur: GroupRecord) => GroupRecord | undefined, audit?: AuditEntry): Promise<GroupRecord | undefined>;
  /**
   * Set the marker: one transaction of the header (condition: status `validating`, `rev` as read) and an audit row,
   * with the hashed token of `commitToken`. Reads the header first and returns `already` when it is committed.
   */
  commitGroup(gid: string, c: { rev: number; writeOrder: number[]; now: string; audit: AuditEntry }): Promise<CommitOutcome>;
  /**
   * Reserve the number of `rec` (a `pending` row with a `group_id`) for a group: create it, or, when a row is there, take
   * it over if `free` says so and it is `pending`. The takeover is a compare-and-set on the row's `rev`.
   */
  adoptVersion(rec: VersionRecord, audit: AuditEntry, free: (cur: VersionRecord) => boolean): Promise<AdoptOutcome>;
  /**
   * The same takeover for a single publish: `rec` is a `pending` row with no `group_id` (the single's reservation), which
   * replaces a `pending` row that `free` accepts, a compare-and-set on the row's `rev`. A single uses it to take the
   * number of a group that is dead.
   */
  adoptSingle(rec: VersionRecord, audit: AuditEntry, free: (cur: VersionRecord) => boolean): Promise<AdoptOutcome>;
  /**
   * Apply a `stage` or `group_publish` to the row as stored (not as a reader sees it), with its audit row, compare-and-set
   * on `rev`. An event that changes nothing writes nothing (and no audit row). Throws version_not_found, and
   * invalid_transition for a row of another group or a state the event refuses.
   */
  applyGroupEvent(name: string, version: string, event: GroupEvent, audit: AuditEntry): Promise<VersionRecord>;
  /**
   * Store the commit request's per-member inputs under `hash` (see `commitInputKey`). Overwriting is harmless: the key holds
   * its content's hash, so the same key is the same input. `expiresAt` (epoch seconds) is the items' TTL.
   */
  putCommitInputs(gid: string, hash: string, inputs: readonly CommitInput[], expiresAt: number): Promise<void>;
  /** One member's commit input (the member's index in the group's member list), or undefined. A consistent read. */
  getCommitInput(gid: string, hash: string, index: number): Promise<CommitInput | undefined>;
  /**
   * The groups that are not over, from the sweeper's sparse index (an eventually consistent read; the sweeper reads the header of
   * each before it acts). Every page is followed.
   */
  listActiveGroups(): Promise<ActiveGroup[]>;
}

/** Seconds a dead group's member list outlives its header: the header goes first, so a reopened group never finds a header without its list. */
export const MEMBERS_TTL_EXTRA_SECONDS = 2 * 86_400;

/** The member-list item with the expiry that goes with a header's `expires_at` (none when the header has none, which is also how a reopened group clears it). */
export function membersWithExpiry(item: Record<string, unknown>, headerExpiresAt: number | undefined): Record<string, unknown> {
  const { expires_at: _drop, ...rest } = item;
  return headerExpiresAt === undefined ? rest : { ...rest, expires_at: headerExpiresAt + MEMBERS_TTL_EXTRA_SECONDS };
}

/** A commit input as the item stored under its key. `expires_at` is the item's TTL. */
export const commitInputItem = (key: string, i: CommitInput, expiresAt: number): Record<string, unknown> => ({ publish_id: key, name: i.name, ...(i.manifest_sha256 !== undefined ? { manifest_sha256: i.manifest_sha256 } : {}), ...(i.display ? { display: JSON.parse(JSON.stringify(i.display)) } : {}), ...(i.source_commit !== undefined ? { source_commit: i.source_commit } : {}), expires_at: expiresAt });
export const parseCommitInput = (item: Record<string, unknown>): CommitInput => ({
  name: String(item.name),
  ...(item.manifest_sha256 !== undefined ? { manifest_sha256: String(item.manifest_sha256) } : {}),
  ...(item.display && typeof item.display === 'object' ? { display: item.display as DisplayMeta } : {}),
  ...(typeof item.source_commit === 'string' ? { source_commit: item.source_commit } : {}),
});
