import type { Principal } from '../auth';
import type { GroupMembers } from '../group';
import { API_VIEW } from '../group';
import { bitmapHas, commitRequestHash, type CommitInput, type GroupRecord, type GroupStore } from '../group-store';
import type { Store } from '../store';
import type { AuditEntry, VersionRecord } from '../types';
import type { PublishConfig } from './config';
import { parseDisplay } from './display';
import { groupCommitRefused, invalidRequest, PublishError, uploadInvalid } from './errors';
import { quarantineKeyFor, uploadIdFor } from './group-keys';
import { ENDED_TAIL_SECONDS, groupAudit, pastDeadline } from './group-lifecycle';
import type { ObjectStore, Queue } from './ports';
import { actorOf } from './service';
import type { ValidateGroupMessage } from './types';

/**
 * POST /groups/{group_id}/commit (spec/api/openapi.yaml: commitGroup): the request that says a group's files are uploaded
 * and hands over what the archives cannot say for themselves (each member's manifest hash and display fields). It does
 * not publish anything. It checks that the group is ready, stores the request, moves the group from `open` to
 * `validating` and queues the group's validation (src/publish/group-validator.ts), which validates every member, copies the
 * files and commits the group, or ends it.
 *
 * Idempotent: the same request again while the group is validating queues the validation again (the queue drops a repeat
 * within its window, so it is one job), and for a group that has committed it answers as it is. A different request for a
 * group that already has one is refused.
 */

const SHA256 = /^[0-9a-f]{64}$/;
const BATCH = 16;
const isObject = (v: unknown): v is Record<string, unknown> => typeof v === 'object' && v !== null && !Array.isArray(v);

export interface GroupCommitBody {
  group_id: string;
  status: string;
  attempt: number;
  status_url: string;
}

/** The members' inputs of a commit request in the group's member order, and the hash that names them. Throws invalid_request. */
export function parseGroupCommit(members: GroupMembers, body: unknown): { inputs: CommitInput[]; hash: string } {
  if (!isObject(body)) throw invalidRequest('the body is not a JSON object');
  const list = body.members;
  if (!Array.isArray(list)) throw invalidRequest("'members' lists the manifest of each member of the group");
  const byName = new Map<string, CommitInput>();
  for (const m of list) {
    if (!isObject(m)) throw invalidRequest('a member is not a JSON object');
    const { name, manifest_sha256 } = m;
    if (typeof name !== 'string') throw invalidRequest("a member needs a 'name'");
    if (byName.has(name)) throw invalidRequest(`'${name}' appears twice`);
    if (typeof manifest_sha256 !== 'string' || !SHA256.test(manifest_sha256)) throw invalidRequest(`'manifest_sha256' of '${name}' is 64 lowercase hex digits`);
    const display = parseDisplay(m);
    byName.set(name, { name, manifest_sha256, ...(Object.keys(display).length > 0 ? { display } : {}) });
  }
  const inputs: CommitInput[] = [];
  for (const m of members.members) {
    const got = byName.get(m.name);
    if (!got) throw invalidRequest(`'members' has no entry for '${m.name}', a member of the group`);
    inputs.push(got);
    byName.delete(m.name);
  }
  const extra = [...byName.keys()][0];
  if (extra !== undefined) throw invalidRequest(`'${extra}' is not a member of the group`);
  return { inputs, hash: commitRequestHash(JSON.stringify(inputs)) };
}

/** The message that starts (or goes on with) a group's validation. `resend` separates the dedup ids of the sweeper's resends. */
export async function sendValidateGroup(queue: Queue, gid: string, attempt: number, n: number, resend: number): Promise<void> {
  const msg: ValidateGroupMessage = { type: 'validate_group', group_id: gid, attempt, n };
  // One FIFO group per group: its validation runs one message at a time, in order, and other groups' jobs run beside it.
  await queue.send({ body: JSON.stringify(msg), groupId: gid, dedupId: `vg:${gid}:${attempt}:${n}:${resend}` });
}

export interface GroupCommitDeps {
  registry: Store & GroupStore;
  /** Only `head` is used: every file must have arrived. */
  objects: Pick<ObjectStore, 'head'>;
  config: PublishConfig;
  /** The group queue. Absent: the deployment has none and a commit answers `unavailable`. */
  groupQueue?: Queue;
  now?: () => Date;
}

/** What the commit needs of the group routes: the group as the caller may see it. */
export interface GroupAccess {
  load(p: Principal, id: string): Promise<{ header: GroupRecord; members: GroupMembers }>;
}

export class GroupCommitter {
  private readonly now: () => Date;
  constructor(
    private readonly d: GroupCommitDeps,
    private readonly access: GroupAccess,
  ) {
    this.now = d.now ?? (() => new Date());
  }

  async commit(p: Principal, id: string, body: unknown): Promise<{ started: boolean; body: GroupCommitBody }> {
    const reg = this.d.registry;
    const queue = this.d.groupQueue;
    if (!queue) throw new PublishError('unavailable', 'The registry is temporarily unavailable.');
    const { header, members } = await this.access.load(p, id);
    const { inputs, hash } = parseGroupCommit(members, body);
    const answer = (h: GroupRecord): GroupCommitBody => ({ group_id: id, status: h.status, attempt: h.attempt, status_url: `/api/v1/groups/${id}` });

    if (header.status === 'validating' || header.status === 'committed' || header.status === 'visible') {
      if (header.commit_hash !== hash) throw groupCommitRefused(`group ${id} is ${header.status} on another commit request`);
      // The same request again. A group that is validating gets its job queued again (the first send may never have left).
      if (header.status === 'validating') await sendValidateGroup(queue, id, header.attempt, 0, 0);
      return { started: header.status === 'validating', body: answer(header) };
    }
    if (header.status !== 'open') {
      throw groupCommitRefused(header.status === 'expired' ? `group ${id} expired at ${header.deadline_at}` : `group ${id} is ${header.status}`);
    }
    const now = this.now();
    if (pastDeadline(header, now)) throw groupCommitRefused(`group ${id} is past its deadline, ${header.deadline_at}`);
    const unreserved = members.members.filter((_m, i) => !bitmapHas(header.reserved, i)).length;
    if (unreserved > 0) throw groupCommitRefused(`${unreserved} of ${members.members.length} members are not reserved yet; repeat the create request until it answers without 'reserving'`);

    await this.requireUploads(id, members);
    await reg.putCommitInputs(id, hash, inputs, Math.floor(Date.parse(header.deadline_at) / 1000) + ENDED_TAIL_SECONDS);

    const at = now.toISOString();
    const audit: AuditEntry = groupAudit(id, `a_${id}_commitreq_${header.attempt}`, 'group_commit_request', at, actorOf(p));
    // Compare-and-set on the header: only a group that is still open, and not past its deadline, begins validating.
    const after = await reg.updateGroup(
      id,
      (cur) =>
        cur.status === 'open' && cur.attempt === header.attempt && !pastDeadline(cur, this.now())
          ? { ...cur, status: 'validating', commit_hash: hash, phase: 1, progress_at: at, sweep_at: at, resend: 0 }
          : undefined,
      audit,
    );
    if (!after) throw groupCommitRefused(`group ${id} is gone`);
    if (after.status !== 'validating' || after.commit_hash !== hash) {
      throw groupCommitRefused(after.status === 'open' ? `group ${id} is past its deadline, ${after.deadline_at}` : `group ${id} is ${after.status}`);
    }
    await sendValidateGroup(queue, id, after.attempt, 0, 0);
    return { started: true, body: answer(after) };
  }

  /** Every declared file of every member is in quarantine at its declared size. The first that is not is named. */
  private async requireUploads(gid: string, members: GroupMembers): Promise<void> {
    const rows = await this.d.registry.versionsOf(
      members.members.map((m) => m.name),
      API_VIEW,
    );
    const files: Array<{ member: string; key: string; filename: string; size: number }> = [];
    for (const m of members.members) {
      const row = rows.get(m.name)?.find((r: VersionRecord) => r.canonical === m.canonical);
      if (!row || row.group_id !== gid || row.state !== 'pending') throw groupCommitRefused(`${m.name} ${m.version} is not reserved for this group`);
      for (const f of row.files) {
        files.push({ member: m.name, key: quarantineKeyFor(uploadIdFor(gid, m, f), f.filename), filename: f.filename, size: f.size });
      }
    }
    for (let i = 0; i < files.length; i += BATCH) {
      const batch = files.slice(i, i + BATCH);
      const stats = await Promise.all(batch.map((f) => this.d.objects.head(f.key)));
      const bad = batch.findIndex((f, j) => stats[j]?.size !== f.size);
      if (bad >= 0) throw uploadInvalid(`${batch[bad]!.filename} of '${batch[bad]!.member}' was not uploaded`);
    }
  }
}
