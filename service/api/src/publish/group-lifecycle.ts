import { headerKey } from '../group';
import type { GroupFailure, GroupRecord, GroupStatus, GroupStore } from '../group-store';
import type { AuditEntry, VersionRecord } from '../types';

/**
 * What both the group routes and the single publish need to know about a group that is over. A number held by a group
 * that is dead is free: a group or a single may take it over, checked against the row's revision.
 */

/** The statuses of a group that ended without committing and without burning its numbers. */
export const DEAD_STATUSES: readonly GroupStatus[] = ['expired', 'aborted', 'rejected', 'superseded'];
export const isDead = (s: GroupStatus): boolean => DEAD_STATUSES.includes(s);

/** Past the deadline. A deadline that is not a time counts as past (the group ends rather than lives forever). */
export const pastDeadline = (h: Pick<GroupRecord, 'deadline_at'>, now: Date): boolean => !(now.getTime() <= Date.parse(h.deadline_at));

/**
 * Seconds a header that ended without committing is kept after the later of its end and its deadline, and then left to the
 * table's TTL. The rows its members reserved are free for the taking from the same moment (`orphanFree`), so an expired
 * header never leaves a number that nobody can take.
 */
export const ENDED_TAIL_SECONDS = 7 * 86_400;

/** The status a group ends with when it does not commit. */
export type EndStatus = 'expired' | 'aborted' | 'superseded' | 'rejected' | 'failed';

/**
 * The header of a group that has ended: its new status, no entry in the sweeper's index, and an expiry (the table's TTL).
 * Nothing else changes. A header that committed is never passed here (the store refuses an expiry on one).
 */
export function ended(cur: GroupRecord, status: EndStatus, at: string, failure?: GroupFailure): GroupRecord {
  const { sweep_pk: _pk, sweep_at: _at, ...rest } = cur;
  const until = Math.max(Date.parse(at), Date.parse(cur.deadline_at));
  return { ...rest, status, progress_at: at, ...(failure ? { failure } : {}), expires_at: Math.floor(until / 1000) + ENDED_TAIL_SECONDS };
}

/**
 * A `pending` row whose group has no header is free once `free_after` (stamped on the row when it was reserved, see
 * VersionRecord) has passed: the header was given its expiry at the end of the group, never before. A row with no
 * `free_after` is a row whose group never had a header (which should not happen) or one that was filled, and stays
 * hidden and untaken.
 */
export const orphanFree = (row: Pick<VersionRecord, 'state' | 'free_after'>, now: Date): boolean =>
  row.state === 'pending' && row.free_after !== undefined && now.getTime() / 1000 > row.free_after;

/** The `free_after` of a row reserved for a group whose deadline is `deadlineAt`: the same moment its header's expiry begins to count. */
export const freeAfterFor = (deadlineAt: string): number => Math.floor(Date.parse(deadlineAt) / 1000) + ENDED_TAIL_SECONDS;

export const groupAudit = (gid: string, id: string, action: string, at: string, actor: string, detail?: Record<string, string>): AuditEntry => ({
  name: headerKey(gid),
  ts: at,
  id,
  actor,
  action,
  ...(detail ? { detail } : {}),
});

/**
 * Lazy expiry: whoever meets an `open` group past its deadline first makes it `expired` (a compare-and-set on the header,
 * so exactly one caller does, and a group that meanwhile began validating is left alone). Returns the header as it is.
 */
export async function expireIfDue(groups: GroupStore, h: GroupRecord, now: Date): Promise<GroupRecord> {
  if (h.status !== 'open' || !pastDeadline(h, now)) return h;
  const at = now.toISOString();
  const after = await groups.updateGroup(
    h.group_id,
    (cur) => (cur.status === 'open' && pastDeadline(cur, now) ? ended(cur, 'expired', at) : undefined),
    groupAudit(h.group_id, `a_${h.group_id}_expire_${h.attempt}`, 'group_expire', at, 'system'),
  );
  return after ?? h;
}
