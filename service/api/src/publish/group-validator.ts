import { createHash } from 'node:crypto';
import { performance } from 'node:perf_hooks';
import { API_VIEW, type GroupMember, type GroupMembers } from '../group';
import { bitmapHas, bitmapSet, memberAuditId, type GroupFailure, type GroupRecord, type GroupStore } from '../group-store';
import type { Store } from '../store';
import type { AuditEntry, VersionRecord } from '../types';
import type { ValidatorOptions } from '../validate';
import type { PublishConfig } from './config';
import { sendValidateGroup } from './group-commit';
import { quarantineKeyFor, uploadIdFor } from './group-keys';
import { ended, groupAudit, pastDeadline } from './group-lifecycle';
import type { ObjectStore, PublishStore, Queue } from './ports';
import { liveBytes } from './service';
import { fillFrom, Rejected, validateArchives } from './validator';

/**
 * The group's validator: the job the group queue carries once a group has been committed to validation (POST
 * /groups/{id}/commit moved it from `open` to `validating`). It runs in three phases, each saved in the group's header
 * (the bitmaps `validated`, `staged`, `copied` and the number `phase`), so a crashed or time-limited invocation goes on
 * where the last one stopped:
 *
 *   1. every member's archives are validated, and the member's row is filled and stamped with the attempt (`stage`,
 *      which leaves it `pending`: nothing a reader can see). Nothing is copied. A bad member ends the group `rejected`,
 *      and its numbers are free again. The group's declared bytes, the age of each upload (a quarantine object is
 *      deleted a day after it was written, and the copies need the rest of that day) and the deadline are checked first.
 *   2. each member's files are copied into the channel from a second read of quarantine, checked against the declared
 *      sha256 again, with create-only writes: a file that is already there must hold the same bytes. From the moment this
 *      phase is recorded (before the first copy) any failure ends the group `failed`: its members' numbers are burned (a
 *      tombstone, as for a rejected single publish), because bytes under those names may already be public. Abort and
 *      expiry only ever end a group that is `open`, so a group in validation is immune to both.
 *   3. a verification pass reads every member row back and finds it as it was staged, the project quota is checked again
 *      against what the registry holds now, the order the chain will write the packages in is worked out, and the group is
 *      committed: the one write that makes it visible to the API (`commitGroup`).
 *
 * Every step is idempotent, and after the commit nothing here is done again: a message for a committed group does no more
 * than delete what is left in quarantine. What follows a commit (repodata, the sparse index, the flip) is a later change.
 *
 * A defect in our own code (anything that is not a verdict) is thrown, so the message is retried and, after the queue's
 * receive limit, lands in the dead-letter queue, which has an alarm. A group whose rows are not as staged is such a defect:
 * it is never committed.
 */

export interface GroupValidatorDeps {
  registry: Store & GroupStore;
  /** Only `getUpload`: the record of an upload says when it was begun. */
  publishes: Pick<PublishStore, 'getUpload'>;
  objects: ObjectStore;
  /** The group queue: a validator that runs out of time sends its own continuation. */
  groupQueue: Queue;
  config: PublishConfig;
  /** https://conda.<stage>.mopm.dev: the channel's public base, for the file URLs of published versions. */
  channelUrl: string;
  validatorOptions?: ValidatorOptions;
  now?: () => Date;
  /** Milliseconds on a monotonic clock, for the invocation's time budget. */
  clock?: () => number;
  log?: (line: Record<string, unknown>) => void;
}

export type GroupJobOutcome = 'skipped' | 'requeued' | 'committed' | 'already' | 'rejected' | 'failed';

/** What a job needs to know of the message: the attempt it is for, and how many continuations came before it. */
export interface GroupJobMessage {
  group_id: string;
  attempt: number;
  n: number;
}

/** Members saved to the header at a time. A crash loses at most this many members' work, which is repeated harmlessly. */
const FLUSH_EVERY = 8;
const PARALLEL = 16;
const sha256Hex = (b: Uint8Array) => createHash('sha256').update(b).digest('hex');

type Bitmap = 'validated' | 'staged' | 'copied';

/** The group ends here. `burn`: files were copied (or may have been), so the numbers are burned and the group is `failed`; otherwise it is `rejected` and they are free. */
class Verdict extends Error {
  constructor(
    readonly failure: GroupFailure,
    readonly burn: boolean,
  ) {
    super(failure.message);
  }
}
const verdict = (code: string, message: string, burn: boolean, member?: string) => new Verdict({ code, message: message.slice(0, 500), ...(member ? { member } : {}) }, burn);

export async function validateGroup(d: GroupValidatorDeps, msg: GroupJobMessage): Promise<GroupJobOutcome> {
  return new GroupJob(d, msg).run();
}

type Step = 'done' | 'requeued' | 'skipped';
type Rows = Map<string, VersionRecord[]>;

class GroupJob {
  private readonly now: () => Date;
  private readonly clock: () => number;
  private readonly log: (line: Record<string, unknown>) => void;
  private readonly began: number;
  private readonly gid: string;
  private h!: GroupRecord;
  private members!: GroupMembers;
  /** Members started in this invocation: it always starts at least one, so every invocation makes progress. */
  private startedMembers = 0;

  constructor(
    private readonly d: GroupValidatorDeps,
    private readonly msg: GroupJobMessage,
  ) {
    this.now = d.now ?? (() => new Date());
    this.clock = d.clock ?? (() => performance.now());
    this.log = d.log ?? ((l) => console.log(JSON.stringify(l)));
    this.began = this.clock();
    this.gid = msg.group_id;
  }

  async run(): Promise<GroupJobOutcome> {
    const reg = this.d.registry;
    const first = await reg.getGroup(this.gid);
    if (!first) {
      this.log({ level: 'error', msg: 'a group job for an unknown group', group_id: this.gid });
      return 'skipped';
    }
    // A message of another attempt than the group's is for a validation that has been replaced (the group ended and opened again).
    if (first.attempt !== this.msg.attempt) return 'skipped';
    this.h = first;
    const members = await reg.getGroupMembers(this.gid);
    if (!members) throw new Error(`group ${this.gid}: its member list is missing`);
    this.members = members;

    // After the commit nothing is decided again: only what the commit left behind is cleared.
    if (this.h.committed_at !== undefined) {
      await this.clearQuarantine();
      return 'already';
    }
    // A group that failed (by a validator that died after saying so, or by the operator's script) still has its numbers to burn.
    if (this.h.status === 'failed') {
      await this.burn(this.h.failure ?? { code: 'failed', message: 'the group failed' });
      return 'failed';
    }
    if (this.h.status !== 'validating') return 'skipped';

    try {
      for (;;) {
        const phase = this.h.phase ?? 1;
        if (phase >= 3) return await this.phase3();
        const step = phase === 1 ? await this.phase1() : await this.phase2();
        if (step !== 'done') return step;
      }
    } catch (err) {
      if (!(err instanceof Verdict)) throw err;
      return this.end(err);
    }
  }

  // --- phase 1 -----------------------------------------------------------------------------------------------------

  private async phase1(): Promise<Step> {
    const rows = await this.rows();
    if (pastDeadline(this.h, this.now())) throw verdict('deadline_passed', `the group's deadline, ${this.h.deadline_at}, passed before its files were checked`, false);
    if (this.h.validated === '') await this.preflight(rows);

    let saved: number[] = [];
    for (const [i, m] of this.members.members.entries()) {
      if (bitmapHas(this.h.validated, i)) continue;
      if (this.overBudget()) return this.pause(saved, ['validated', 'staged']);
      this.startedMembers++;
      await this.validateMember(i, m, rows);
      saved.push(i);
      if (saved.length >= FLUSH_EVERY) {
        if (!(await this.save(saved, ['validated', 'staged']))) return 'skipped';
        saved = [];
      }
    }
    if (pastDeadline(this.h, this.now())) throw verdict('deadline_passed', `the group's deadline, ${this.h.deadline_at}, passed before its files were checked`, false);
    // Phase 2 is recorded before the first copy: from here a group that stops is failed, not rejected.
    return (await this.save(saved, ['validated', 'staged'], 2)) ? 'done' : 'skipped';
  }

  /**
   * Before any archive is opened: the declared bytes fit the group cap, every file's upload record exists and is not older than
   * the quarantine prefix can be trusted to keep it (24 hours less the hours reserved for validation), and every file is in
   * quarantine at its declared size.
   */
  private async preflight(rows: Rows): Promise<void> {
    const cfg = this.d.config;
    const limitMs = (24 - cfg.groupValidateHours) * 3_600_000;
    const files: Array<{ member: string; uploadId: string; key: string; filename: string; size: number }> = [];
    let bytes = 0;
    for (const m of this.members.members) {
      const row = this.rowOf(rows, m);
      for (const f of row.files) {
        bytes += f.size;
        const uploadId = uploadIdFor(this.gid, m, f);
        files.push({ member: m.name, uploadId, key: quarantineKeyFor(uploadId, f.filename), filename: f.filename, size: f.size });
      }
    }
    if (bytes > cfg.groupMaxBytes) throw verdict('limit_exceeded', `the group's files total ${bytes} bytes; a group holds at most ${cfg.groupMaxBytes}`, false);
    for (let i = 0; i < files.length; i += PARALLEL) {
      const batch = files.slice(i, i + PARALLEL);
      const got = await Promise.all(batch.map(async (f) => ({ record: await this.d.publishes.getUpload(f.uploadId), stat: await this.d.objects.head(f.key) })));
      for (const [j, f] of batch.entries()) {
        const { record, stat } = got[j]!;
        if (!record) throw verdict('upload_missing', `the upload record of ${f.filename} is gone; uploads are kept for a day`, false, f.member);
        const age = this.now().getTime() - Date.parse(record.created_at);
        if (!(age <= limitMs)) {
          throw verdict('upload_too_old', `${f.filename} was begun ${Math.floor(age / 3_600_000)} hours ago; the oldest upload a group may hold is ${24 - cfg.groupValidateHours} hours old`, false, f.member);
        }
        if (!stat || stat.size !== f.size) throw verdict('upload_missing', `${f.filename} is not in quarantine at its declared size`, false, f.member);
      }
    }
  }

  private async validateMember(i: number, m: GroupMember, rows: Rows): Promise<void> {
    const d = this.d;
    const row = this.rowOf(rows, m);
    const input = await d.registry.getCommitInput(this.gid, this.h.commit_hash ?? '', i);
    if (!input) throw new Error(`group ${this.gid}: the commit input of ${m.name} (${this.h.commit_hash ?? 'no hash'}) is missing`);
    const files = row.files.map((f) => ({ subdir: f.subdir, filename: f.filename, sha256: f.sha256, key: quarantineKeyFor(uploadIdFor(this.gid, m, f), f.filename) }));
    let facts;
    try {
      facts = await validateArchives(d.objects, d.validatorOptions, { name: row.name, version: row.version, manifest_sha256: input.manifest_sha256 }, files);
    } catch (err) {
      if (err instanceof Rejected) throw verdict(err.code, err.message, false, m.name);
      throw err;
    }
    const fill = fillFrom(d.channelUrl, this.now(), { version: row.version, ...(input.display ? { display: input.display } : {}), published_by: row.published_by ?? this.h.actor }, row.files, facts);
    await d.registry.applyGroupEvent(m.name, row.version, { type: 'stage', group_id: this.gid, attempt: this.h.attempt, fill }, this.audit(i, m, 'group_stage'));
  }

  // --- phase 2 -----------------------------------------------------------------------------------------------------

  private async phase2(): Promise<Step> {
    const rows = await this.rows();
    let saved: number[] = [];
    for (const [i, m] of this.members.members.entries()) {
      if (bitmapHas(this.h.copied, i)) continue;
      if (this.overBudget()) return this.pause(saved, ['copied']);
      this.startedMembers++;
      await this.copyMember(m, this.rowOf(rows, m));
      saved.push(i);
      if (saved.length >= FLUSH_EVERY) {
        if (!(await this.save(saved, ['copied']))) return 'skipped';
        saved = [];
      }
    }
    return (await this.save(saved, ['copied'], 3)) ? 'done' : 'skipped';
  }

  /** Copy a member's files into the channel from quarantine, each checked against its declared sha256, create-only. */
  private async copyMember(m: GroupMember, row: VersionRecord): Promise<void> {
    const objects = this.d.objects;
    for (const f of row.files) {
      const src = quarantineKeyFor(uploadIdFor(this.gid, m, f), f.filename);
      const bytes = await objects.get(src);
      if (!bytes) throw verdict('upload_missing', `${f.filename} vanished from quarantine after it was validated`, true, m.name);
      if (sha256Hex(bytes) !== f.sha256) throw verdict('sha256_mismatch', `${f.filename}: the upload changed after it was validated`, true, m.name);
      const dest = `${f.subdir}/${f.filename}`;
      const put = await objects.put(dest, bytes, { contentType: 'application/octet-stream', cacheControl: 'public, max-age=31536000, immutable', createOnly: true });
      if (put === 'exists') {
        // A repeat of this very step leaves the same bytes. Anything else under this name is not ours to publish over.
        const there = await objects.get(dest);
        if (!there || sha256Hex(there) !== f.sha256) throw verdict('sha256_mismatch', `the channel already holds other bytes at ${dest}`, true, m.name);
      }
    }
  }

  // --- phase 3 -----------------------------------------------------------------------------------------------------

  private async phase3(): Promise<GroupJobOutcome> {
    const d = this.d;
    if (pastDeadline(this.h, this.now())) throw verdict('deadline_passed', `the group's deadline, ${this.h.deadline_at}, passed before it could be committed`, true);
    const rows = await this.rows();
    const quota = d.config.projectQuotaBytes;
    const staged: VersionRecord[] = [];
    for (const m of this.members.members) {
      // The verification pass: every member is read back, as the stage left it. A row that is not is a defect, not a verdict:
      // the group is never committed, and the message goes to the dead-letter queue with its alarm.
      const row = this.rowOf(rows, m);
      if (row.staged_attempt !== this.h.attempt || row.files.length === 0 || row.files.some((f) => f.url === undefined)) {
        throw new Error(`group ${this.gid}: ${m.name} ${m.version} is not as it was staged (attempt ${String(row.staged_attempt)}, group attempt ${this.h.attempt})`);
      }
      staged.push(row);
      // The project total again, against what the registry holds now (a published row counts, a pending one does not).
      const used = liveBytes(rows.get(m.name) ?? []);
      const add = row.files.reduce((n, f) => n + f.size, 0);
      if (used + add > quota) throw verdict('limit_exceeded', `${m.name} would hold ${used + add} bytes; the limit is ${quota}`, true, m.name);
    }
    const order = writeOrder(this.members.members, (i) => staged[i]!.deps.map((x) => x.name));

    for (let attempt = 0; attempt < 3; attempt++) {
      const cur = await d.registry.getGroup(this.gid);
      if (!cur || cur.attempt !== this.h.attempt) return 'skipped';
      if (cur.committed_at !== undefined) return 'already';
      if (cur.status !== 'validating') return 'skipped';
      const at = this.now().toISOString();
      const out = await d.registry.commitGroup(this.gid, { rev: cur.rev, writeOrder: order, now: at, audit: groupAudit(this.gid, `a_${this.gid}_commit_${cur.attempt}`, 'group_commit', at, 'system') });
      switch (out.outcome) {
        case 'committed':
          this.log({ level: 'info', msg: 'group committed', group_id: this.gid, attempt: cur.attempt });
          await this.clearQuarantine();
          return 'committed';
        case 'already':
          return 'already';
        case 'deadline':
          throw verdict('deadline_passed', `the group's deadline, ${cur.deadline_at}, passed before it could be committed`, true);
        case 'missing':
          return 'skipped';
        case 'conflict':
          continue; // the header moved (a checkpoint, a resend): read it again
      }
    }
    throw new Error(`group ${this.gid}: the commit lost its compare-and-set three times`);
  }

  // --- ending ------------------------------------------------------------------------------------------------------

  /**
   * End the group on a verdict: the compare-and-set to `rejected` (nothing was copied) or `failed` (it may have been) comes
   * first, and it is the only thing that can end a group that is validating, so a commit that starts after it loses. A failed
   * group's numbers are burned after that; if this invocation dies in between, the redelivered message finds the group
   * `failed` and burns them.
   */
  private async end(v: Verdict): Promise<GroupJobOutcome> {
    const at = this.now().toISOString();
    const status = v.burn ? 'failed' : 'rejected';
    const after = await this.d.registry.updateGroup(
      this.gid,
      (cur) => (cur.status === 'validating' && cur.attempt === this.h.attempt && cur.committed_at === undefined ? ended(cur, status, at, v.failure) : undefined),
      groupAudit(this.gid, `a_${this.gid}_${status}_${this.h.attempt}`, v.burn ? 'group_fail' : 'group_reject', at, 'system', { code: v.failure.code, ...(v.failure.member ? { member: v.failure.member } : {}) }),
    );
    this.log({ level: 'warn', msg: `group ${status}`, group_id: this.gid, code: v.failure.code, member: v.failure.member });
    if (after?.status === 'failed') {
      await this.burn(after.failure ?? v.failure);
      return 'failed';
    }
    return after?.status === 'rejected' ? 'rejected' : 'skipped';
  }

  /** Tombstone every member row the group holds that is still pending. Idempotent; a row in any other state is left alone. */
  private async burn(failure: GroupFailure): Promise<void> {
    const date = this.now().toISOString().slice(0, 10);
    const list = this.members.members;
    for (let i = 0; i < list.length; i += PARALLEL) {
      await Promise.all(
        list.slice(i, i + PARALLEL).map((m, k) =>
          this.d.registry.applyGroupEvent(m.name, m.version, { type: 'group_burn', group_id: this.gid, reason_code: failure.code, date }, this.audit(i + k, m, 'group_burn')),
        ),
      );
    }
  }

  /** Delete the group's quarantine objects. A failure is only logged: the bucket's lifecycle rule expires quarantine/ after a day. */
  private async clearQuarantine(): Promise<void> {
    const rows = await this.rows();
    for (const m of this.members.members) {
      const row = rows.get(m.name)?.find((r) => r.canonical === m.canonical);
      for (const f of row?.files ?? []) {
        const key = quarantineKeyFor(uploadIdFor(this.gid, m, f), f.filename);
        try {
          await this.d.objects.delete(key);
        } catch (err) {
          this.log({ level: 'warn', msg: 'could not delete a quarantine object; the lifecycle rule will', key, error: String(err) });
        }
      }
    }
  }

  // --- the header ---------------------------------------------------------------------------------------------------

  /**
   * Save progress: the members now done go into the bitmaps (merged with what the header holds now), the group's clock moves
   * (`progress_at`, `sweep_at`, and `resend` back to 0: it counts resends since the last progress), and with `phase` the
   * group moves to that phase. False when the group is no longer validating (the operator's script ended it): the job stops.
   */
  private async save(done: readonly number[], maps: readonly Bitmap[], phase?: number): Promise<boolean> {
    const at = this.now().toISOString();
    const after = await this.d.registry.updateGroup(this.gid, (cur) => {
      if (cur.status !== 'validating' || cur.attempt !== this.h.attempt || cur.committed_at !== undefined) return undefined;
      const next: GroupRecord = { ...cur, progress_at: at, sweep_at: at, resend: 0 };
      for (const map of maps) for (const i of done) next[map] = bitmapSet(next[map], i);
      if (phase !== undefined && (cur.phase ?? 1) < phase) next.phase = phase;
      return next;
    });
    if (!after || after.status !== 'validating') return false;
    this.h = after;
    return true;
  }

  /** The time budget is spent: save what is done and send the continuation. */
  private async pause(done: readonly number[], maps: readonly Bitmap[]): Promise<Step> {
    if (!(await this.save(done, maps))) return 'skipped';
    await sendValidateGroup(this.d.groupQueue, this.gid, this.h.attempt, this.msg.n + 1, 0);
    return 'requeued';
  }

  private overBudget(): boolean {
    return this.startedMembers > 0 && this.clock() - this.began >= this.d.config.groupBudgetMs;
  }

  // --- the rows -----------------------------------------------------------------------------------------------------

  /** The members' packages' rows as the API view shows them. Before the commit a group's rows are `pending`, so this is them as stored. */
  private rows(): Promise<Rows> {
    return this.d.registry.versionsOf(
      this.members.members.map((m) => m.name),
      API_VIEW,
    );
  }

  /** The member's row, which must be the group's pending row. Anything else is a defect (the group's rows cannot be changed by anyone else while it is live). */
  private rowOf(rows: Rows, m: GroupMember): VersionRecord {
    const row = rows.get(m.name)?.find((r) => r.canonical === m.canonical);
    if (!row || row.group_id !== this.gid || row.state !== 'pending') {
      throw new Error(`group ${this.gid}: the row of ${m.name} ${m.version} is not the group's pending row (${row ? `${row.state}, group ${String(row.group_id)}` : 'missing'})`);
    }
    return row;
  }

  private audit(i: number, m: GroupMember, action: string): AuditEntry {
    return {
      name: m.name,
      ts: this.now().toISOString(),
      id: `${memberAuditId(this.gid, i)}_${action}_${this.h.attempt}`,
      actor: this.h.actor,
      action,
      version: m.version,
      detail: { group_id: this.gid },
    };
  }
}

/**
 * The order the chain writes the group's packages in (their `write_order`): dependencies before the packages that depend
 * on them, among the members only (a dependency outside the group is not ordered). Members that depend on each other in a
 * cycle are one unit, ordered by name inside it; units that do not depend on each other are ordered by name. Deterministic.
 * `depsOf(i)` names the packages member `i` depends on.
 */
export function writeOrder(members: readonly GroupMember[], depsOf: (index: number) => readonly string[]): number[] {
  const byName = new Map(members.map((m, i) => [m.name, i] as const));
  const byMemberName = (a: number, b: number) => (members[a]!.name < members[b]!.name ? -1 : members[a]!.name > members[b]!.name ? 1 : 0);
  const edges = members.map((_m, i) => [...new Set(depsOf(i).flatMap((n) => (byName.has(n) && byName.get(n) !== i ? [byName.get(n)!] : [])))].sort(byMemberName));
  // Tarjan's strongly connected components: a component is emitted after every component it depends on.
  const index = new Array<number>(members.length).fill(-1);
  const low = new Array<number>(members.length).fill(0);
  const onStack = new Array<boolean>(members.length).fill(false);
  const stack: number[] = [];
  const out: number[] = [];
  let counter = 0;
  const visit = (v: number): void => {
    index[v] = counter;
    low[v] = counter;
    counter++;
    stack.push(v);
    onStack[v] = true;
    for (const w of edges[v]!) {
      if (index[w] === -1) {
        visit(w);
        low[v] = Math.min(low[v]!, low[w]!);
      } else if (onStack[w]) {
        low[v] = Math.min(low[v]!, index[w]!);
      }
    }
    if (low[v] === index[v]) {
      const component: number[] = [];
      let w: number;
      do {
        w = stack.pop()!;
        onStack[w] = false;
        component.push(w);
      } while (w !== v);
      out.push(...component.sort(byMemberName));
    }
  };
  for (const v of members.map((_m, i) => i).sort(byMemberName)) if (index[v] === -1) visit(v);
  return out;
}
