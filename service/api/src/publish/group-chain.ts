import type { GroupMembers } from '../group';
import { bitmapHas, bitmapSet, memberAuditId, type GroupRecord, type GroupStore } from '../group-store';
import { SUBDIRS_V1 } from '../types';
import { groupAudit } from './group-lifecycle';
import type { Queue } from './ports';
import type { FlipGroupMessage, GroupHop, IndexMessage, IndexPkgMessage } from './types';

/**
 * What follows a group's commit: the chain that puts the group into the channel's files, in an order a client can rely on, and then
 * makes its rows plain `published` rows.
 *
 *   1. one repodata hop per subdir the group has files in,
 *   2. then one index hop per member, in the header's `write_order` (dependencies first),
 *   3. then the flip: every member row becomes `published`, and the header `visible`.
 *
 * A hop releases what it builds on the group's header first (`repodata_released`, `index_released`: the gates the builders'
 * views read, src/group.ts) and then builds, so a build that nobody asked for (a yank of another version, an operator's rebuild,
 * the chain of another publish) between two hops lists the members released so far and no others. The header, not the message,
 * says what comes next: every hop ends by reading it and sending the first step that is not done, so a message that arrives twice
 * or late sends the step that is needed, and one that arrives early does nothing but send the step that is missing.
 *
 * Post-commit work is roll-forward and idempotent: nothing here ends a group. A hop that does not find the group committed at its
 * attempt (and not yet visible) does nothing.
 */

/** One step of the chain. */
export type ChainStep = { kind: 'repodata'; subdir: string } | { kind: 'index'; position: number; name: string } | { kind: 'flip' };

/** The subdirs the group has files in, in the channel's order. These are the repodata hops. */
export function touchedSubdirs(members: GroupMembers): string[] {
  const all = new Set(members.members.flatMap((m) => m.subdirs));
  return SUBDIRS_V1.filter((s) => all.has(s));
}

/** The header is of a group that committed at `attempt` and is not visible yet: the only group whose chain runs. */
export const chainLive = (h: GroupRecord | undefined, attempt: number): h is GroupRecord => h !== undefined && h.attempt === attempt && h.committed_at !== undefined && h.status === 'committed';

export const writeOrderOf = (h: GroupRecord, members: GroupMembers): number[] => {
  const order = h.write_order;
  if (order === undefined || order.length !== members.members.length) {
    throw new Error(`group ${h.group_id}: the header's write_order does not list the ${members.members.length} members`);
  }
  return order;
};

/** The first step the header does not show done: repodata hops, then index hops in `write_order`, then the flip; none once the group is visible. */
export function nextStep(h: GroupRecord, members: GroupMembers): ChainStep | undefined {
  if (h.committed_at === undefined || h.status !== 'committed') return undefined;
  const released = h.repodata_released ?? [];
  const subdir = touchedSubdirs(members).find((s) => !released.includes(s));
  if (subdir !== undefined) return { kind: 'repodata', subdir };
  const order = writeOrderOf(h, members);
  const done = h.index_released ?? [];
  const position = order.findIndex((_member, p) => !done.includes(p));
  if (position >= 0) return { kind: 'index', position, name: members.members[order[position]!]!.name };
  return { kind: 'flip' };
}

export interface ChainQueues {
  /** The repodata and index hops. */
  indexQueue: Queue;
  /** The flip. */
  groupQueue: Queue;
}

/** The dedup id of a step: the same step at the same resend count is one message to a FIFO queue; a resend carries a higher count. */
export const stepDedupId = (gid: string, attempt: number, step: ChainStep, resend: number): string =>
  `grp:${gid}:${attempt}:${step.kind === 'repodata' ? `r-${step.subdir}` : step.kind === 'index' ? `i-${step.position}` : 'flip'}:${resend}`;

/** Queue a step. The FIFO groups are those of the files it writes (the subdir, `pkg:<name>`), so a hop never runs beside another writer of the same file. */
export async function sendStep(q: ChainQueues, gid: string, attempt: number, resend: number, step: ChainStep): Promise<void> {
  const dedupId = stepDedupId(gid, attempt, step, resend);
  const hop: GroupHop = { group_id: gid, attempt, resend };
  switch (step.kind) {
    case 'repodata': {
      const msg: IndexMessage = { type: 'index', subdir: step.subdir, then: { group: hop } };
      return q.indexQueue.send({ body: JSON.stringify(msg), groupId: step.subdir, dedupId });
    }
    case 'index': {
      // `rev` only separates dedup ids of the other senders; a hop's dedup id is above.
      const msg: IndexPkgMessage = { type: 'index_pkg', name: step.name, rev: 0, group: { ...hop, position: step.position } };
      return q.indexQueue.send({ body: JSON.stringify(msg), groupId: `pkg:${step.name}`, dedupId });
    }
    case 'flip': {
      const msg: FlipGroupMessage = { type: 'flip_group', ...hop };
      return q.groupQueue.send({ body: JSON.stringify(msg), groupId: gid, dedupId });
    }
  }
}

/**
 * Send the step the header says is next (none when the group is visible). Reads the header and member list as they are now.
 * Returns the step, or undefined.
 */
export async function sendNext(groups: GroupStore, q: ChainQueues, gid: string, attempt: number, resend = 0): Promise<ChainStep | undefined> {
  const h = await groups.getGroup(gid);
  if (!chainLive(h, attempt)) return undefined;
  // A group that is live is committed, and a committed group always has a step left: the flip is the last, and it makes the group visible.
  const step = nextStep(h, await requireMembers(groups, gid))!;
  await sendStep(q, gid, attempt, resend, step);
  return step;
}

/** A group's member list. A committed group without one is a defect, not a state: it throws (the message is retried and then alarms). */
export async function requireMembers(groups: GroupStore, gid: string): Promise<GroupMembers> {
  const members = await groups.getGroupMembers(gid);
  if (!members) throw new Error(`group ${gid}: its member list is missing`);
  return members;
}

/** A hop made progress: the clock the sweeper reads moves, and its resend count starts again. */
export const progressed = (at: string): Pick<GroupRecord, 'progress_at' | 'sweep_at' | 'resend'> => ({ progress_at: at, sweep_at: at, resend: 0 });

export interface HopDeps {
  groups: GroupStore;
  now: () => Date;
  log: (line: Record<string, unknown>) => void;
}

/**
 * The gate of a repodata hop: set the subdir in the header's `repodata_released` (a compare-and-set; already set is fine), and
 * answer the member list, or undefined when the hop is not for a group that is committed at its attempt and not yet visible, or for
 * a subdir the group has no file in. The caller builds the subdir's repodata only when this answers.
 */
export async function releaseRepodata(d: HopDeps, hop: GroupHop, subdir: string): Promise<GroupMembers | undefined> {
  const at = d.now().toISOString();
  const members = await d.groups.getGroupMembers(hop.group_id);
  if (!members) return stale(d, hop, 'a repodata hop for a group that has no member list');
  if (!touchedSubdirs(members).includes(subdir)) return stale(d, hop, `a repodata hop for ${subdir}, which holds no file of the group`);
  const after = await d.groups.updateGroup(hop.group_id, (cur) =>
    !chainLive(cur, hop.attempt) || (cur.repodata_released ?? []).includes(subdir) ? undefined : { ...cur, repodata_released: [...(cur.repodata_released ?? []), subdir], ...progressed(at) },
  );
  return chainLive(after, hop.attempt) ? members : stale(d, hop, 'a repodata hop for a group that is no longer in its chain');
}

/**
 * The gate of an index hop: set `position` in `index_released`, but only when every repodata gate is set and every position before
 * it is (so a message that arrives early cannot release a package ahead of what it depends on). Answers the member list when the
 * position is released (now or before), 'redirected' when it is not (the step that is missing is sent instead), and undefined
 * when the hop is not for a group in its chain.
 */
export async function releaseIndex(d: HopDeps, q: ChainQueues, hop: GroupHop & { position: number }, name: string): Promise<GroupMembers | 'redirected' | undefined> {
  const at = d.now().toISOString();
  const members = await d.groups.getGroupMembers(hop.group_id);
  const first = await d.groups.getGroup(hop.group_id);
  if (!chainLive(first, hop.attempt) || !members) return stale(d, hop, 'an index hop for a group that is not committed at that attempt');
  const order = writeOrderOf(first, members);
  if (members.members[order[hop.position] ?? -1]?.name !== name) return stale(d, hop, `an index hop for ${name} at position ${hop.position}, which is not that member's place in the write order`);
  const subdirs = touchedSubdirs(members);
  const after = await d.groups.updateGroup(hop.group_id, (cur) => {
    if (!chainLive(cur, hop.attempt)) return undefined;
    const done = cur.index_released ?? [];
    if (done.includes(hop.position)) return undefined;
    const ready = subdirs.every((s) => (cur.repodata_released ?? []).includes(s)) && order.slice(0, hop.position).every((_m, p) => done.includes(p));
    return ready ? { ...cur, index_released: [...done, hop.position], ...progressed(at) } : undefined;
  });
  if (!chainLive(after, hop.attempt)) return stale(d, hop, 'an index hop for a group that is no longer in its chain');
  if ((after.index_released ?? []).includes(hop.position)) return members;
  d.log({ level: 'warn', msg: 'an index hop arrived before the steps it follows; the missing step is sent instead', group_id: hop.group_id, position: hop.position });
  await sendNext(d.groups, q, hop.group_id, hop.attempt, hop.resend);
  return 'redirected';
}

export function stale(d: HopDeps, hop: GroupHop, what: string): undefined {
  d.log({ level: 'info', msg: `group chain: ${what}; nothing done`, group_id: hop.group_id, attempt: hop.attempt });
  return undefined;
}

/** A hop is done: send what the header says is next. */
export async function advance(d: HopDeps, q: ChainQueues, hop: GroupHop): Promise<void> {
  await sendNext(d.groups, q, hop.group_id, hop.attempt, 0);
}

// --- the flip -------------------------------------------------------------------------------------------------------

/** Members flipped at a time, and saved to the header after each batch. */
const FLIP_BATCH = 16;

export type FlipOutcome = 'visible' | 'already' | 'redirected' | 'skipped';

/** The header of a group that is visible: no entry in the sweeper's index any more, so the operator's tool can report that nothing is left to revert. */
export function madeVisible(cur: GroupRecord, at: string): GroupRecord {
  const { sweep_pk: _pk, sweep_at: _at, ...rest } = cur;
  return { ...rest, status: 'visible', progress_at: at };
}

/**
 * The flip: every member of a committed group becomes `published` (at the commit time; a yanked or tombstoned member is left as
 * it is), then the header becomes `visible` in one compare-and-set that leaves the sweeper's index. Only after every hop: a group
 * whose gates are not all set sends the missing step instead. The members already flipped (the header's `flipped` bitmap, saved
 * after each batch) are not touched again, and a repeat of the whole flip changes nothing and writes nothing.
 */
export async function flipGroup(d: HopDeps & { indexQueue: Queue; groupQueue: Queue }, msg: FlipGroupMessage): Promise<FlipOutcome> {
  const gid = msg.group_id;
  const h = await d.groups.getGroup(gid);
  if (!h || h.attempt !== msg.attempt) return 'skipped';
  if (h.status === 'visible') return 'already';
  if (!chainLive(h, msg.attempt)) return 'skipped';
  const members = await requireMembers(d.groups, gid);
  const step = nextStep(h, members)!; // the group is committed, so there is a step: at the latest, this one
  if (step.kind !== 'flip') {
    d.log({ level: 'warn', msg: 'a flip arrived before the steps it follows; the missing step is sent instead', group_id: gid });
    await sendStep(d, gid, msg.attempt, msg.resend, step);
    return 'redirected';
  }

  const committedAt = h.committed_at!;
  const todo = members.members.map((_m, i) => i).filter((i) => !bitmapHas(h.flipped, i));
  for (let k = 0; k < todo.length; k += FLIP_BATCH) {
    const batch = todo.slice(k, k + FLIP_BATCH);
    const at = d.now().toISOString();
    await Promise.all(
      batch.map((i) => {
        const m = members.members[i]!;
        return d.groups.applyGroupEvent(
          m.name,
          m.version,
          { type: 'group_publish', group_id: gid, attempt: msg.attempt, committed_at: committedAt },
          { name: m.name, ts: at, id: `${memberAuditId(gid, i)}_group_flip_${msg.attempt}`, actor: 'system', action: 'group_flip', version: m.version, detail: { group_id: gid } },
        );
      }),
    );
    const saved = await d.groups.updateGroup(gid, (cur) => {
      if (!chainLive(cur, msg.attempt)) return undefined;
      let flipped = cur.flipped;
      for (const i of batch) flipped = bitmapSet(flipped, i);
      return { ...cur, flipped, ...progressed(at) };
    });
    // Anything but committed here is another flip that finished while this one was working (a group does not go anywhere else after
    // its commit): there is nothing left for this one to do.
    if (saved?.status !== 'committed') return 'already';
  }

  const at = d.now().toISOString();
  let wrote = false;
  await d.groups.updateGroup(
    gid,
    (cur) => {
      // Every member is flipped (this flip's batches are saved, and merged with the others' in the header), so the group is visible,
      // unless it already is.
      wrote = cur.status === 'committed';
      return wrote ? madeVisible(cur, at) : undefined;
    },
    groupAudit(gid, `a_${gid}_visible_${msg.attempt}`, 'group_visible', at, 'system'),
  );
  if (wrote) d.log({ level: 'info', msg: 'group visible', group_id: gid, attempt: msg.attempt });
  return wrote ? 'visible' : 'already';
}
