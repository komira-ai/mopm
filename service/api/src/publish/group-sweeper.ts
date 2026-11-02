import type { GroupRecord, GroupStore } from '../group-store';
import { Metrics } from '../metrics';
import { sendValidateGroup } from './group-commit';
import { nextStep, requireMembers, sendStep, type ChainStep } from './group-chain';
import { groupAudit } from './group-lifecycle';
import { runningOp, sendYankNext, yankRunning } from './group-yank';
import type { Queue } from './ports';

/**
 * The sweeper: a scheduled job (every five minutes) that finds a group that has stopped moving and asks for it to go on. It reads the
 * sparse index of groups that are not over (a group leaves it when it is `visible`, or ends; a yank puts a visible group back until it
 * ends), and looks after three kinds:
 *
 *   - a group that is `validating` and has shown no sign of life for longer than the queue's visibility timeout plus slack
 *     (`STALL_MS`: a message that is being worked on is invisible for 30 minutes): it sends the validate message again, from the
 *     bitmaps the header holds.
 *   - a group that is `committed` and has shown no sign of life for `CHAIN_STALL_MS`: a hop of its chain was lost (a message that
 *     went to the dead-letter queue, a send that never left). It reads the header, which says which step is next (the repodata hops, the
 *     index hops, the flip: src/publish/group-chain.ts) and sends that step again.
 *   - a group that is `visible` and has a yank or unyank running (src/publish/group-yank.ts; it is in the index only while one runs) and has
 *     shown no sign of life for `CHAIN_STALL_MS`: it sends the step the header's `yank` says is next (the rows, a repodata hop, an index hop,
 *     or the end), with the same counter in its dedup id.
 *
 * It never ends a group, aborts it or burns anything: a stalled group that does not move after `MAX_RESENDS` resends only
 * raises an alarm (the metric `group_sweeper_gave_up`), and ending it is a person's decision (src/ops/group-ops.ts). It
 * writes the header to count a resend (`resend`) and to move the group's `sweep_at`, so that it does not resend every five
 * minutes; a validator that saves progress, or a hop that releases a gate, sets `resend` back to 0. Each resend is a message of its
 * own: the counter is part of its dedup id, and a FIFO queue drops a repeated id for five minutes.
 */

export const STALL_MS = 35 * 60_000;
/** A hop is a delivery, a few reads and one write: ten minutes without one is a lost message, not a slow one. */
export const CHAIN_STALL_MS = 10 * 60_000;
export const MAX_RESENDS = 3;

export interface SweeperDeps {
  groups: GroupStore;
  groupQueue: Queue;
  /** The queue of the repodata and index hops. */
  indexQueue: Queue;
  now?: () => Date;
  metrics?: Metrics;
  log?: (line: Record<string, unknown>) => void;
}

export interface SweepResult {
  /** Groups that are validating. */
  validating: number;
  /** Groups that are committed and not yet visible. */
  committed: number;
  /** Visible groups whose yank or unyank is running. */
  yanking: number;
  /** Groups a message was sent again for (the validate message, or the step of the chain, yank or unyank that is next). */
  resent: string[];
  /** Stalled groups that have used their resends and are left to a person. */
  gaveUp: string[];
  /** Seconds since the least recently active group that is validating, committed or being yanked showed a sign of life (0 when none is). */
  oldestSeconds: number;
}

/** The last sign of life of a group: its validator or a hop saving progress, or the sweeper resending. */
const lastSeen = (h: Pick<GroupRecord, 'progress_at' | 'sweep_at'>): number => Math.max(Date.parse(h.progress_at), Date.parse(h.sweep_at ?? h.progress_at));

export async function sweepGroups(d: SweeperDeps): Promise<SweepResult> {
  const now = (d.now ?? (() => new Date()))();
  const log = d.log ?? ((l: Record<string, unknown>) => console.log(JSON.stringify(l)));
  // A validating group is given the validator's visibility timeout; every other group the sweeper looks after moves in hops of seconds.
  const stalled = (h: Pick<GroupRecord, 'progress_at' | 'sweep_at' | 'status'>) => now.getTime() - lastSeen(h) > (h.status === 'validating' ? STALL_MS : CHAIN_STALL_MS);
  const out: SweepResult = { validating: 0, committed: 0, yanking: 0, resent: [], gaveUp: [], oldestSeconds: 0 };
  const hopDeps = { groups: d.groups, now: d.now ?? (() => new Date()), log };

  for (const a of await d.groups.listActiveGroups()) {
    // A `visible` group is in the index only while a yank or unyank of it is running (src/publish/group-yank.ts).
    if (a.status !== 'validating' && a.status !== 'committed' && a.status !== 'visible') continue;
    if (a.status === 'validating') out.validating++;
    else if (a.status === 'committed') out.committed++;
    else out.yanking++;
    out.oldestSeconds = Math.max(out.oldestSeconds, Math.floor((now.getTime() - lastSeen(a)) / 1000));
    if (!stalled(a)) continue;
    // The index is eventually consistent: act on the header, not on the index's copy of it.
    const h = await d.groups.getGroup(a.group_id);
    if (!h || h.status !== a.status || !stalled(h)) continue;
    // An entry of a visible group whose yank has ended since (the index lags): nothing to do.
    const yank = h.status === 'visible' ? (yankRunning(h) ? h.yank : undefined) : undefined;
    if (h.status === 'visible' && !yank) continue;
    if (h.resend >= MAX_RESENDS) {
      out.gaveUp.push(h.group_id);
      log({ level: 'error', msg: `a group stopped ${yank ? `${runningOp(yank)}ing` : h.status === 'committed' ? 'moving through its chain' : 'validating'} and the sweeper has resent it as often as it will`, group_id: h.group_id, status: h.status, resend: h.resend });
      continue;
    }
    // What to send, read before the header is written: the member list is immutable and the gates only grow.
    let step: ChainStep | undefined;
    // A committed group has a step left (the flip is the last, and it makes the group visible, which takes it out of the index).
    if (h.status === 'committed') step = nextStep(h, await requireMembers(d.groups, h.group_id));
    const at = now.toISOString();
    const after = await d.groups.updateGroup(
      h.group_id,
      (cur) =>
        cur.status === h.status && cur.attempt === h.attempt && cur.yank?.seq === h.yank?.seq && cur.yank?.state === h.yank?.state && stalled(cur) && cur.resend < MAX_RESENDS
          ? { ...cur, resend: cur.resend + 1, sweep_at: at }
          : undefined,
      groupAudit(
        h.group_id,
        yank ? `a_${h.group_id}_${runningOp(yank)}_resend_${yank.seq}_${h.resend + 1}` : `a_${h.group_id}_${h.status === 'committed' ? 'chain_' : ''}resend_${h.attempt}_${h.resend + 1}`,
        'group_resend',
        at,
        'system',
        { resend: String(h.resend + 1) },
      ),
    );
    // A validator or a hop that saved progress between the read and the write changed the header, and the group is not stalled any more.
    if (after && after.sweep_at === at && after.resend === h.resend + 1) {
      if (yank) await sendYankNext(hopDeps, d, after.group_id, after.attempt, runningOp(yank), yank.seq, after.resend);
      else if (step) await sendStep(d, after.group_id, after.attempt, after.resend, step);
      else await sendValidateGroup(d.groupQueue, after.group_id, after.attempt, 0, after.resend);
      out.resent.push(after.group_id);
    }
  }

  (d.metrics ?? new Metrics()).emit([
    { name: 'group_oldest_nonterminal_age_seconds', value: out.oldestSeconds, unit: 'Seconds' },
    { name: 'group_sweeper_resends', value: out.resent.length },
    { name: 'group_sweeper_gave_up', value: out.gaveUp.length },
  ]);
  return out;
}
