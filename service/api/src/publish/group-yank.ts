import type { GroupMembers } from '../group';
import { bitmapHas, bitmapIndexes, bitmapSet, memberAuditId, type GroupRecord, type GroupYank } from '../group-store';
import { progressed, requireMembers, stale, touchedSubdirs, writeOrderOf, type ChainQueues, type HopDeps } from './group-chain';
import { groupAudit } from './group-lifecycle';
import type { Queue } from './ports';
import type { GroupHop, IndexMessage, IndexPkgMessage, YankGroupMessage } from './types';

/**
 * Yank and unyank of a whole group (design: group publish, "group yank and unyank"). It is allowed only for a group that is `visible`:
 * every member is then a plain row, and no commit-time flip can race the yank into a build. The group stays `visible` while it is
 * yanked; what says where the yank is, is `yank` on its header (src/group-store.ts, GroupYank).
 *
 *   yank     a compare-and-set of the intent on the header (`yanking`, a new sequence number, the reason, the actor), and a
 *            `yank_group` message. The group queue's job then yanks every member that is `published` (a member somebody yanked by hand,
 *            or took down, is left as it is) and records exactly the members it changed in `yanked_set`, saved after each batch; every
 *            row it changes carries the sequence number. Then the files follow, in the benign direction: one repodata hop for each
 *            subdir a yanked member has files in, one index hop for each yanked member, in the header's `write_order`, and the end
 *            (`yanked`, which takes the group out of the sweeper's index).
 *   unyank   the same machine the other way round, for a group that is `yanked`: the rows first (only the members of `yanked_set`
 *            that still carry the marker of that yank), then repodata hops, then index hops, then `restored`. As for a single version's
 *            unyank, the rows are the truth and come first, so a build nobody asked for between the rows and the hops can list a
 *            restored member in the index before repodata lists it; the hops put the files right, and a client whose index runs ahead of
 *            repodata fails closed. What the gates here do is the order of the chain's own hops (an index hop that arrives before the
 *            repodata hops, or before the hop of a member it follows, releases nothing and sends the step that is missing); they do
 *            not hide a restored row from a build, as the commit's gates hide a member that is not yet flipped.
 *
 * Every step is idempotent and the header, not the message, says which is next (as in src/publish/group-chain.ts); the sweeper
 * resends the next step of a group whose yank or unyank stops moving, with the header's `resend` counter in the dedup id.
 */

export type YankOp = 'yank' | 'unyank';

const RUNNING: Record<YankOp, GroupYank['state']> = { yank: 'yanking', unyank: 'unyanking' };
const AT_REST: Record<YankOp, GroupYank['state']> = { yank: 'yanked', unyank: 'restored' };
/** Longest reason (the spec's limit for a yank): it is kept on the header and on every row the yank changes. */
export const MAX_REASON = 280;
/** Members changed at a time; the header is saved after each batch. */
const BATCH = 16;

/** A header of a visible group with a yank on it. */
export type YankedGroup = GroupRecord & { yank: GroupYank };

/** The header is of a visible group, at that attempt, whose yank number `seq` is running as `op`: the only group a step of that yank works on. */
export function yankLive(h: GroupRecord | undefined, op: YankOp, seq: number, attempt: number): h is YankedGroup {
  return h !== undefined && h.status === 'visible' && h.attempt === attempt && h.yank !== undefined && h.yank.seq === seq && h.yank.state === RUNNING[op];
}

/** A visible group whose yank or unyank is running (what the sweeper and the operator's tool look for). */
export const yankRunning = (h: GroupRecord): h is YankedGroup => h.status === 'visible' && h.yank !== undefined && (h.yank.state === 'yanking' || h.yank.state === 'unyanking');
/** The operation that is running. */
export const runningOp = (y: GroupYank): YankOp => (y.state === 'unyanking' ? 'unyank' : 'yank');

/** The member indexes in `yanked_set`. */
const yankedIndexes = (y: GroupYank, members: GroupMembers): number[] => bitmapIndexes(y.yanked_set).filter((i) => i < members.members.length);
const subdirsOf = (y: GroupYank, members: GroupMembers): string[] => touchedSubdirs({ members: yankedIndexes(y, members).map((i) => members.members[i]!) });

/** One step of a yank or unyank. `finish` has no message: whoever finds it next does it. */
export type YankStep = { kind: 'rows' } | { kind: 'repodata'; subdir: string } | { kind: 'index'; position: number; name: string } | { kind: 'finish' };

/** The first step the header does not show done: the rows, then a repodata hop for each subdir of the yanked members, then an index hop for each of them in `write_order`, then the end. */
export function nextYankStep(h: YankedGroup, members: GroupMembers): YankStep {
  const y = h.yank;
  if (!y.rows_done) return { kind: 'rows' };
  const subdir = subdirsOf(y, members).find((s) => !(y.repodata_done ?? []).includes(s));
  if (subdir !== undefined) return { kind: 'repodata', subdir };
  const order = writeOrderOf(h, members);
  const done = y.index_done ?? [];
  const position = order.findIndex((member, p) => bitmapHas(y.yanked_set, member) && !done.includes(p));
  if (position >= 0) return { kind: 'index', position, name: members.members[order[position]!]!.name };
  return { kind: 'finish' };
}

type Sent = Exclude<YankStep, { kind: 'finish' }>;

/** The dedup id of a step: one message per step and resend count (a resend carries a higher count), and the yank's number keeps a second yank's steps apart from the first's. */
export const yankDedupId = (gid: string, attempt: number, op: YankOp, seq: number, step: Sent, resend: number): string =>
  `grp:${gid}:${attempt}:${op === 'yank' ? 'y' : 'u'}${seq}:${step.kind === 'rows' ? 'rows' : step.kind === 'repodata' ? `r-${step.subdir}` : `i-${step.position}`}:${resend}`;

/** Queue the row step of a yank or unyank (the group queue; FIFO group: the group id). */
export async function sendYankRows(q: Queue, gid: string, attempt: number, op: YankOp, seq: number, resend: number): Promise<void> {
  const msg: YankGroupMessage = { type: 'yank_group', group_id: gid, attempt, op, seq, resend };
  await q.send({ body: JSON.stringify(msg), groupId: gid, dedupId: yankDedupId(gid, attempt, op, seq, { kind: 'rows' }, resend) });
}

/** Queue a step. The FIFO groups are those of the files it writes (the subdir, `pkg:<name>`), as for the commit's chain. */
export async function sendYankStep(q: ChainQueues, gid: string, attempt: number, op: YankOp, seq: number, resend: number, step: Sent): Promise<void> {
  if (step.kind === 'rows') return sendYankRows(q.groupQueue, gid, attempt, op, seq, resend);
  const hop: GroupHop = { group_id: gid, attempt, resend, yank: { op, seq } };
  const dedupId = yankDedupId(gid, attempt, op, seq, step, resend);
  if (step.kind === 'repodata') {
    const msg: IndexMessage = { type: 'index', subdir: step.subdir, then: { group: hop } };
    return q.indexQueue.send({ body: JSON.stringify(msg), groupId: step.subdir, dedupId });
  }
  const msg: IndexPkgMessage = { type: 'index_pkg', name: step.name, rev: 0, group: { ...hop, position: step.position } };
  return q.indexQueue.send({ body: JSON.stringify(msg), groupId: `pkg:${step.name}`, dedupId });
}

/**
 * Do or send the step the header says is next: the end is done here (the header becomes `yanked` or `restored`, and leaves the
 * sweeper's index); any other step is queued. Nothing when the yank is not running at that attempt and number. Returns the step.
 */
export async function sendYankNext(d: HopDeps, q: ChainQueues, gid: string, attempt: number, op: YankOp, seq: number, resend: number): Promise<YankStep | undefined> {
  const h = await d.groups.getGroup(gid);
  if (!yankLive(h, op, seq, attempt)) return undefined;
  const step = nextYankStep(h, await requireMembers(d.groups, gid));
  if (step.kind === 'finish') await finishYank(d, gid, attempt, op, seq);
  else await sendYankStep(q, gid, attempt, op, seq, resend, step);
  return step;
}

/** The end: `yanked` or `restored`, no entry in the sweeper's index, one audit row. A repeat, or a yank that is not at its end, changes nothing. */
async function finishYank(d: HopDeps, gid: string, attempt: number, op: YankOp, seq: number): Promise<void> {
  const at = d.now().toISOString();
  let wrote = false;
  await d.groups.updateGroup(
    gid,
    (cur) => {
      if (!yankLive(cur, op, seq, attempt) || cur.yank.rows_done !== true) return undefined;
      wrote = true;
      const { sweep_pk: _pk, sweep_at: _at, ...rest } = cur;
      return { ...rest, progress_at: at, resend: 0, yank: { ...cur.yank, state: AT_REST[op] } };
    },
    groupAudit(gid, `a_${gid}_${op}_done_${seq}`, op === 'yank' ? 'group_yanked' : 'group_unyanked', at, 'system'),
  );
  if (wrote) d.log({ level: 'info', msg: op === 'yank' ? 'group yanked' : 'group restored', group_id: gid, seq });
}

// --- the rows ----------------------------------------------------------------------------------------------------------

export interface YankDeps extends HopDeps, ChainQueues {}
export type YankRowsOutcome = 'done' | 'already' | 'skipped';

/**
 * The rows of a yank or unyank. A yank applies `group_yank` to each member not yet in `yanked_set` and adds to the set the members that
 * come back yanked with this yank's marker (so a member the yank changed before a crash is found again, and a member yanked by hand is
 * not); an unyank applies `group_unyank` to each member of the set, which restores the ones that still carry the marker. Sixteen at a
 * time, the header saved after each batch. Then `rows_done`, and the first hop. A repeat after that only sends the step that is next.
 */
export async function yankRows(d: YankDeps, msg: YankGroupMessage): Promise<YankRowsOutcome> {
  const gid = msg.group_id;
  const { op, seq, attempt } = msg;
  const h = await d.groups.getGroup(gid);
  if (!yankLive(h, op, seq, attempt)) {
    d.log({ level: 'info', msg: `group ${op}: the rows of a ${op} that is not running; nothing done`, group_id: gid, seq });
    return 'skipped';
  }
  if (h.yank.rows_done) {
    await sendYankNext(d, d, gid, attempt, op, seq, msg.resend);
    return 'already';
  }
  const members = await requireMembers(d.groups, gid);
  const y = h.yank;
  const by = op === 'yank' ? y.by : (y.unyank_by ?? y.by);
  const todo = op === 'yank' ? members.members.map((_m, i) => i).filter((i) => !bitmapHas(y.yanked_set, i)) : yankedIndexes(y, members);

  for (let k = 0; k < todo.length; k += BATCH) {
    const batch = todo.slice(k, k + BATCH);
    const at = d.now().toISOString();
    const rows = await Promise.all(
      batch.map((i) => {
        const m = members.members[i]!;
        return d.groups.applyGroupEvent(
          m.name,
          m.version,
          op === 'yank' ? { type: 'group_yank', group_id: gid, seq, reason: y.reason } : { type: 'group_unyank', group_id: gid, seq },
          { name: m.name, ts: at, id: `${memberAuditId(gid, i)}_group_${op}_${seq}`, actor: by, action: `group_${op}`, version: m.version, detail: { group_id: gid, ...(op === 'yank' ? { reason: y.reason } : {}) } },
        );
      }),
    );
    const mine = batch.filter((_i, j) => rows[j]!.state === 'yanked' && rows[j]!.group_yank_seq === seq);
    const saved = await d.groups.updateGroup(gid, (cur) => {
      if (!yankLive(cur, op, seq, attempt)) return undefined;
      let set = cur.yank.yanked_set;
      if (op === 'yank') for (const i of mine) set = bitmapSet(set, i);
      return { ...cur, yank: { ...cur.yank, yanked_set: set }, ...progressed(at) };
    });
    if (!yankLive(saved, op, seq, attempt)) return 'skipped';
  }

  const at = d.now().toISOString();
  const done = await d.groups.updateGroup(gid, (cur) => (!yankLive(cur, op, seq, attempt) || cur.yank.rows_done ? undefined : { ...cur, yank: { ...cur.yank, rows_done: true }, ...progressed(at) }));
  if (!yankLive(done, op, seq, attempt)) return 'skipped';
  await sendYankNext(d, d, gid, attempt, op, seq, 0);
  return 'done';
}

// --- the gates of the hops ---------------------------------------------------------------------------------------------

type YankHop = GroupHop & { yank: NonNullable<GroupHop['yank']> };

/**
 * The gate of a repodata hop of a yank or unyank: set the subdir in `yank.repodata_done` (already set is fine), and answer the member
 * list, or undefined when the hop is not for a yank that is running at its attempt with its rows done, or for a subdir none of the
 * yanked members has a file in. The caller builds the subdir's repodata only when this answers.
 */
export async function releaseYankRepodata(d: HopDeps, hop: YankHop, subdir: string): Promise<GroupMembers | undefined> {
  const { op, seq } = hop.yank;
  const at = d.now().toISOString();
  const members = await d.groups.getGroupMembers(hop.group_id);
  const first = await d.groups.getGroup(hop.group_id);
  if (!members || !yankLive(first, op, seq, hop.attempt) || !first.yank.rows_done) return stale(d, hop, `a ${op} repodata hop for a group whose ${op} is not running or has not changed its rows`);
  if (!subdirsOf(first.yank, members).includes(subdir)) return stale(d, hop, `a ${op} repodata hop for ${subdir}, which holds no file of a yanked member`);
  const after = await d.groups.updateGroup(hop.group_id, (cur) =>
    !yankLive(cur, op, seq, hop.attempt) || !cur.yank.rows_done || (cur.yank.repodata_done ?? []).includes(subdir)
      ? undefined
      : { ...cur, yank: { ...cur.yank, repodata_done: [...(cur.yank.repodata_done ?? []), subdir] }, ...progressed(at) },
  );
  return yankLive(after, op, seq, hop.attempt) ? members : stale(d, hop, `a ${op} repodata hop for a group that is no longer in its ${op}`);
}

/**
 * The gate of an index hop of a yank or unyank: set `position` in `yank.index_done`, but only once the rows are done, every repodata
 * gate is set and every position of a yanked member before it is. Answers the member list when the position is released (now or
 * before), 'redirected' when it is not (the step that is missing is sent instead), and undefined when the hop is not for a yank that
 * is running or not for a yanked member at that place of the write order.
 */
export async function releaseYankIndex(d: HopDeps, q: ChainQueues, hop: YankHop & { position: number }, name: string): Promise<GroupMembers | 'redirected' | undefined> {
  const { op, seq } = hop.yank;
  const at = d.now().toISOString();
  const members = await d.groups.getGroupMembers(hop.group_id);
  const first = await d.groups.getGroup(hop.group_id);
  if (!members || !yankLive(first, op, seq, hop.attempt)) return stale(d, hop, `a ${op} index hop for a group whose ${op} is not running`);
  if (!first.yank.rows_done) {
    d.log({ level: 'warn', msg: `a ${op} index hop arrived before the rows were done; the missing step is sent instead`, group_id: hop.group_id, position: hop.position });
    await sendYankNext(d, q, hop.group_id, hop.attempt, op, seq, hop.resend);
    return 'redirected';
  }
  const order = writeOrderOf(first, members);
  const member = order[hop.position];
  if (member === undefined || members.members[member]?.name !== name || !bitmapHas(first.yank.yanked_set, member)) {
    return stale(d, hop, `a ${op} index hop for ${name} at position ${hop.position}, which is not a yanked member's place in the write order`);
  }
  const subdirs = subdirsOf(first.yank, members);
  const after = await d.groups.updateGroup(hop.group_id, (cur) => {
    if (!yankLive(cur, op, seq, hop.attempt) || !cur.yank.rows_done) return undefined;
    const done = cur.yank.index_done ?? [];
    if (done.includes(hop.position)) return undefined;
    const ready = subdirs.every((s) => (cur.yank.repodata_done ?? []).includes(s)) && order.slice(0, hop.position).every((m, p) => !bitmapHas(cur.yank.yanked_set, m) || done.includes(p));
    return ready ? { ...cur, yank: { ...cur.yank, index_done: [...done, hop.position] }, ...progressed(at) } : undefined;
  });
  if (!yankLive(after, op, seq, hop.attempt)) return stale(d, hop, `a ${op} index hop for a group that is no longer in its ${op}`);
  if ((after.yank.index_done ?? []).includes(hop.position)) return members;
  d.log({ level: 'warn', msg: `a ${op} index hop arrived before the steps it follows; the missing step is sent instead`, group_id: hop.group_id, position: hop.position });
  await sendYankNext(d, q, hop.group_id, hop.attempt, op, seq, hop.resend);
  return 'redirected';
}

/** A hop is done: do or send what the header says is next. */
export async function advanceYank(d: HopDeps, q: ChainQueues, hop: YankHop): Promise<void> {
  await sendYankNext(d, q, hop.group_id, hop.attempt, hop.yank.op, hop.yank.seq, 0);
}
