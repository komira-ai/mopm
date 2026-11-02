import { bitmapHas, memberAuditId, type GroupRecord, type GroupStore } from '../group-store';
import { ended, groupAudit } from '../publish/group-lifecycle';

/**
 * The operator's tool for groups (service/docs/runbook.md, "Groups"): what is open, and how to end a group that is stuck.
 * Two modes, both flags (`--mode=status`, `--mode=fail`), run by a person with the stage's credentials from a built copy
 * (`npm run build` writes dist/ops/group-ops-bin.js; `node dist/ops/group-ops-bin.js --stage=<stage> --mode=status`).
 *
 *   status  Read-only. Lists every group that is not over (open, validating, committed and not yet visible, or visible with a yank or
 *           unyank running: its `yank` says which) with its phase, the age of its last sign of life and, for a committed one, its
 *           members not yet flipped, and the depth of the
 *           queues. It ends with one `verdict` line: `safe_to_revert` is true only when no group is in that list and the queues
 *           are empty. Exit status 0 when it is safe, 3 when it is not: run it before any revert is merged, because an older
 *           receiver acknowledges the messages of a newer one and loses them (design: rollback).
 *   fail    Ends a group that is `validating` and not moving, by name (`--group=<id>`). Without `--apply` it only prints what it
 *           would do. It changes the header FIRST, with a compare-and-set that holds only while the group is validating and
 *           has not committed: a commit that starts after it loses (its own condition is `status = validating`), and a
 *           validator that wakes up finds the group over and stops. A group still in its first phase is `rejected` (nothing
 *           was copied, its numbers are free again); one that has begun to copy is `failed`, and then its members' numbers are
 *           burned. It never touches a group that has committed.
 *
 * Nothing here reads the environment for its settings: the stage, the region and the group are flags. (The AWS credentials are
 * the standard variables of the AWS SDK, as for any tool of the stage.)
 */

export type OpsMode = 'status' | 'fail';
export interface OpsArgs {
  mode: OpsMode;
  group?: string;
  apply: boolean;
  stage?: string;
  region?: string;
}

const USAGE = 'usage: group-ops --stage=<beta|gamma|prod> [--region=<region>] --mode=status | --mode=fail --group=<group id> [--apply]';

/** The flags as an OpsArgs. Throws an Error that says what is wrong. No positional arguments: every setting is a flag. */
export function parseOpsArgs(argv: readonly string[]): OpsArgs {
  const flags = new Map<string, string>();
  for (const a of argv) {
    const m = /^--([a-z-]+)(?:=(.*))?$/.exec(a);
    if (!m) throw new Error(`${USAGE}\nnot a flag: ${a}`);
    if (flags.has(m[1]!)) throw new Error(`${USAGE}\n--${m[1]} is given twice`);
    flags.set(m[1]!, m[2] ?? '');
  }
  const known = new Set(['mode', 'group', 'apply', 'stage', 'region']);
  for (const k of flags.keys()) if (!known.has(k)) throw new Error(`${USAGE}\nunknown flag --${k}`);
  const mode = flags.get('mode');
  if (mode !== 'status' && mode !== 'fail') throw new Error(`${USAGE}\n--mode is status or fail`);
  const group = flags.get('group');
  if (mode === 'fail' && !group) throw new Error(`${USAGE}\n--mode=fail needs --group`);
  if (mode === 'status' && (group !== undefined || flags.has('apply'))) throw new Error(`${USAGE}\n--mode=status is read-only and takes neither --group nor --apply`);
  const stage = flags.get('stage');
  const region = flags.get('region');
  return { mode, ...(group ? { group } : {}), apply: flags.has('apply'), ...(stage ? { stage } : {}), ...(region ? { region } : {}) };
}

export interface QueueDepth {
  queue: string;
  visible: number;
  in_flight: number;
}

export interface OpsDeps {
  groups: GroupStore;
  /** The depth of the stage's queues (validate, index, group and their dead-letter queues). */
  queueDepth(): Promise<QueueDepth[]>;
  now?: () => Date;
  /** One JSON line each. */
  out: (line: Record<string, unknown>) => void;
}

const popcount = (bitmap: string, n: number): number => Array.from({ length: n }, (_x, i) => (bitmapHas(bitmap, i) ? 1 : 0)).reduce<number>((a, b) => a + b, 0);

/** Run a mode. Returns the exit status: 0 done (or safe), 2 refused (nothing to do or not allowed), 3 not safe to revert, 4 lost a race. */
export async function runOps(args: OpsArgs, d: OpsDeps): Promise<number> {
  const now = (d.now ?? (() => new Date()))();
  if (args.mode === 'status') return status(d, now);
  return fail(args, d, now);
}

async function status(d: OpsDeps, now: Date): Promise<number> {
  const active = await d.groups.listActiveGroups();
  for (const a of active.sort((x, y) => (x.group_id < y.group_id ? -1 : 1))) {
    const h = await d.groups.getGroup(a.group_id);
    if (!h) continue;
    const members = h.member_count;
    d.out({
      kind: 'group',
      group_id: h.group_id,
      status: h.status,
      attempt: h.attempt,
      actor: h.actor,
      phase: h.phase ?? null,
      committed: h.committed_at !== undefined,
      members,
      unflipped: h.committed_at !== undefined ? members - popcount(h.flipped, members) : null,
      // A visible group is listed only while its yank or unyank is running: where it is, and how many members the yank has changed so far.
      yank: h.yank ? h.yank.state : null,
      yanked_members: h.yank ? popcount(h.yank.yanked_set, members) : null,
      last_sign_of_life_seconds: Math.max(0, Math.floor((now.getTime() - Math.max(Date.parse(h.progress_at), Date.parse(h.sweep_at ?? h.progress_at))) / 1000)),
      resend: h.resend,
      deadline_at: h.deadline_at,
    });
  }
  const queues = await d.queueDepth();
  for (const q of queues) d.out({ kind: 'queue', ...q });
  const busy = queues.filter((q) => q.visible > 0 || q.in_flight > 0).map((q) => q.queue);
  const safe = active.length === 0 && busy.length === 0;
  d.out({ kind: 'verdict', safe_to_revert: safe, groups_not_over: active.length, queues_not_empty: busy });
  return safe ? 0 : 3;
}

async function fail(args: OpsArgs, d: OpsDeps, now: Date): Promise<number> {
  const gid = args.group!;
  const h = await d.groups.getGroup(gid);
  if (!h) {
    d.out({ kind: 'refused', group_id: gid, reason: 'there is no such group' });
    return 2;
  }
  if (h.committed_at !== undefined || h.status !== 'validating') {
    d.out({ kind: 'refused', group_id: gid, status: h.status, reason: 'only a group that is validating and has not committed can be ended here' });
    return 2;
  }
  const phase = h.phase ?? 1;
  const to = phase >= 2 ? 'failed' : 'rejected';
  d.out({ kind: 'plan', group_id: gid, from: 'validating', to, phase, burns_numbers: to === 'failed', members: h.member_count, dry_run: !args.apply });
  if (!args.apply) return 0;

  const at = now.toISOString();
  const failure = { code: 'operator', message: `ended by an operator at ${at}` };
  const after = await d.groups.updateGroup(
    gid,
    // Only the header this script read: a validator that moved on to the copies meanwhile makes this a different decision.
    (cur: GroupRecord) => (cur.status === 'validating' && cur.committed_at === undefined && cur.attempt === h.attempt && (cur.phase ?? 1) === phase ? ended(cur, to, at, failure) : undefined),
    groupAudit(gid, `a_${gid}_operator_${h.attempt}`, 'group_operator_end', at, 'operator', { to }),
  );
  if (!after || after.status !== to) {
    d.out({ kind: 'lost', group_id: gid, status: after?.status ?? 'missing', reason: 'the group changed before this script could end it; read its status and run it again if it is still stuck' });
    return 4;
  }
  d.out({ kind: 'ended', group_id: gid, status: after.status });
  if (to === 'failed') {
    const members = await d.groups.getGroupMembers(gid);
    const date = at.slice(0, 10);
    for (const [i, m] of (members?.members ?? []).entries()) {
      await d.groups.applyGroupEvent(
        m.name,
        m.version,
        { type: 'group_burn', group_id: gid, reason_code: failure.code, date },
        { name: m.name, ts: at, id: `${memberAuditId(gid, i)}_group_burn_${after.attempt}`, actor: 'operator', action: 'group_burn', version: m.version, detail: { group_id: gid } },
      );
    }
    d.out({ kind: 'burned', group_id: gid, members: members?.members.length ?? 0 });
  }
  return 0;
}
