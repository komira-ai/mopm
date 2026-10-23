import type { Principal } from '../auth';
import type { GroupMembers } from '../group';
import type { GroupRecord, GroupStore } from '../group-store';
import { groupNotSettled, invalidRequest, PublishError } from './errors';
import type { GroupAccess } from './group-commit';
import { groupAudit } from './group-lifecycle';
import { MAX_REASON, sendYankRows } from './group-yank';
import type { Queue } from './ports';
import { actorOf, parseYank } from './service';

/**
 * PUT /groups/{group_id}/yank (spec/api/openapi.yaml: yankGroup), with the body of a single version's yank: `{yanked: true, reason}` or
 * `{yanked: false}`. Writes the intent on the header with a compare-and-set and queues the rows (src/publish/group-yank.ts does the
 * rest); nothing else happens in the request.
 *
 *   - not `visible`: 409 `group_not_settled` (the commit's chain is still running, or the group never committed);
 *   - yank: a group never yanked or `restored` begins a yank; `yanking` or `yanked` answers as it is (a repeat of a yank whose rows were
 *     not yet queued queues them); `unyanking` is 409 `group_not_settled`;
 *   - unyank: a group that is `yanked` begins an unyank; `unyanking` answers as it is; `yanking` is 409 `group_not_settled`; a group
 *     that was never yanked or is `restored` has nothing to restore and answers as it is.
 */

export interface GroupYankDeps {
  registry: GroupStore;
  /** The group queue: the request queues the rows on it. Absent, a request answers `unavailable`. */
  groupQueue?: Queue;
  now?: () => Date;
}

export interface GroupYankAnswer {
  /** A yank or unyank is running (the route answers 202); false: the group was already as asked (200). */
  started: boolean;
  header: GroupRecord;
  members: GroupMembers;
}

export class GroupYanker {
  private readonly now: () => Date;
  constructor(
    private readonly d: GroupYankDeps,
    private readonly access: GroupAccess,
  ) {
    this.now = d.now ?? (() => new Date());
  }

  /** `authorize` is given the member list once the caller is known to see the group; it throws when the token does not cover every member. */
  async set(p: Principal, id: string, body: unknown, authorize?: (members: GroupMembers) => void): Promise<GroupYankAnswer> {
    const req = parseYank(body);
    if (req.yanked && req.reason.length > MAX_REASON) throw invalidRequest(`'reason' is at most ${MAX_REASON} characters`);
    const queue = this.d.groupQueue;
    if (!queue) throw new PublishError('unavailable', 'The registry is temporarily unavailable.');
    const { header: first, members } = await this.access.load(p, id);
    authorize?.(members);
    const by = actorOf(p);
    for (let tries = 0; tries < 3; tries++) {
      const header = tries === 0 ? first : ((await this.d.registry.getGroup(id)) ?? first);
      const done = req.yanked ? await this.yank(queue, header, members, by, req.reason) : await this.unyank(queue, header, members, by);
      if (done) return done;
    }
    throw groupNotSettled(id, 'it changed while the request was being handled; repeat the request');
  }

  private async yank(queue: Queue, header: GroupRecord, members: GroupMembers, by: string, reason: string): Promise<GroupYankAnswer | undefined> {
    const id = header.group_id;
    const answer = (h: GroupRecord, started: boolean): GroupYankAnswer => ({ started, header: h, members });
    if (header.status !== 'visible') throw groupNotSettled(id, `it is ${header.status}; a group can be yanked once it is visible`);
    const y = header.yank;
    if (y?.state === 'unyanking') throw groupNotSettled(id, 'it is being unyanked');
    if (y?.state === 'yanked') return answer(header, false);
    if (y?.state === 'yanking') {
      // A repeat: if the first request died before queueing the rows, this queues them (the queue drops a copy it already has).
      if (!y.rows_done) await sendYankRows(queue, id, header.attempt, 'yank', y.seq, 0);
      return answer(header, true);
    }
    const before = y?.seq ?? 0;
    const seq = before + 1;
    const at = this.now().toISOString();
    const after = await this.d.registry.updateGroup(
      id,
      (cur) =>
        cur.status === 'visible' && cur.attempt === header.attempt && (cur.yank?.seq ?? 0) === before && (cur.yank === undefined || cur.yank.state === 'restored')
          ? { ...cur, yank: { reason, by, requested_at: at, yanked_set: '', seq, state: 'yanking' }, progress_at: at, sweep_pk: 'active', sweep_at: at, resend: 0 }
          : undefined,
      groupAudit(id, `a_${id}_yank_${seq}`, 'group_yank_request', at, by, { reason }),
    );
    // Another request for the same yank may have won the write: the group is then in this yank and the answer is the same.
    if (after?.yank?.seq !== seq) return undefined;
    if (after.yank.state === 'yanking' && !after.yank.rows_done) await sendYankRows(queue, id, after.attempt, 'yank', seq, 0);
    return answer(after, after.yank.state === 'yanking');
  }

  private async unyank(queue: Queue, header: GroupRecord, members: GroupMembers, by: string): Promise<GroupYankAnswer | undefined> {
    const id = header.group_id;
    const answer = (h: GroupRecord, started: boolean): GroupYankAnswer => ({ started, header: h, members });
    if (header.status !== 'visible') throw groupNotSettled(id, `it is ${header.status}; a group can be yanked or unyanked once it is visible`);
    const y = header.yank;
    if (y === undefined || y.state === 'restored') return answer(header, false);
    if (y.state === 'yanking') throw groupNotSettled(id, 'it is being yanked');
    if (y.state === 'unyanking') {
      if (!y.rows_done) await sendYankRows(queue, id, header.attempt, 'unyank', y.seq, 0);
      return answer(header, true);
    }
    const at = this.now().toISOString();
    const after = await this.d.registry.updateGroup(
      id,
      (cur) => {
        if (cur.status !== 'visible' || cur.attempt !== header.attempt || cur.yank?.seq !== y.seq || cur.yank.state !== 'yanked') return undefined;
        const { rows_done: _rows, repodata_done: _repodata, index_done: _index, ...keep } = cur.yank;
        return { ...cur, yank: { ...keep, state: 'unyanking', unyank_by: by, unyank_at: at }, progress_at: at, sweep_pk: 'active', sweep_at: at, resend: 0 };
      },
      groupAudit(id, `a_${id}_unyank_${y.seq}`, 'group_unyank_request', at, by),
    );
    if (after?.yank?.seq !== y.seq || (after.yank.state !== 'unyanking' && after.yank.state !== 'restored')) return undefined;
    if (after.yank.state === 'unyanking' && !after.yank.rows_done) await sendYankRows(queue, id, after.attempt, 'unyank', y.seq, 0);
    return answer(after, after.yank.state === 'unyanking');
  }
}
