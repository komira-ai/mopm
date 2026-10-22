import { headerKey } from '../group';
import type { GroupRecord, GroupStatus, GroupStore } from '../group-store';
import type { AuditEntry } from '../types';

/**
 * What both the group routes and the single publish need to know about a group that is over. A number held by a group
 * that is dead is free: a group or a single may take it over, checked against the row's revision.
 */

/** The statuses of a group that ended without committing and without burning its numbers. */
export const DEAD_STATUSES: readonly GroupStatus[] = ['expired', 'aborted', 'rejected', 'superseded'];
export const isDead = (s: GroupStatus): boolean => DEAD_STATUSES.includes(s);

/** Past the deadline. A deadline that is not a time counts as past (the group ends rather than lives forever). */
export const pastDeadline = (h: Pick<GroupRecord, 'deadline_at'>, now: Date): boolean => !(now.getTime() <= Date.parse(h.deadline_at));

/** The header of a group that has ended: its new status, and no entry in the sweeper's index. Nothing else changes. */
export function ended(cur: GroupRecord, status: 'expired' | 'aborted' | 'superseded', at: string): GroupRecord {
  const { sweep_pk: _pk, sweep_at: _at, ...rest } = cur;
  return { ...rest, status, progress_at: at };
}

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
