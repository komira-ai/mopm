import { RegistryError } from './errors';
import type { VersionRecord } from './types';

/**
 * pending -> published -> yanked <-> published, and any -> tombstoned (terminal).
 * `pending -> tombstoned` is how a rejected publish burns its number.
 */
export type UserEvent =
  | { type: 'publish'; fill?: PublishFill }
  | { type: 'yank'; reason: string }
  | { type: 'unyank' }
  /** `unpublished`: a pending version being burned by a rejected publish; no file was ever published, so none is kept. */
  | { type: 'tombstone'; reason_code: string; date: string; unpublished?: boolean };

/**
 * The two events only a group's own code sends, through `GroupStore.applyGroupEvent` (src/group-store.ts), which
 * applies them to the stored row. `Store.updateVersion` takes `UserEvent` and refuses these at run time as well.
 *
 * - `stage`: fill a member the group reserved and stamp it with the attempt, in one write. The row stays `pending`.
 *   A row that already carries this attempt's stamp is left as it is (a redelivery), and a row of another group is
 *   refused.
 * - `group_publish`: the flip. A `pending` member that carries the attempt becomes `published` at the commit time. A
 *   row in any other state is left as it is: a yanked member stays yanked, so the flip never unyanks.
 */
export type GroupEvent =
  | { type: 'stage'; group_id: string; attempt: number; fill: PublishFill }
  | { type: 'group_publish'; group_id: string; attempt: number; committed_at: string };

export type VersionEvent = UserEvent | GroupEvent;

/**
 * What the validator learned from the archives, written when the version goes `pending -> published`: a pending
 * record is only a reserved number, and these fields come from the validated files.
 */
export interface PublishFill
  extends Pick<VersionRecord, 'version' | 'build' | 'requires_mojo' | 'deps' | 'native' | 'files' | 'manifest_sha256' | 'published_at'> {
  published_by?: string;
  /** The display metadata the commit request carried; stored on the version so the read API serves it. */
  description?: string;
  license?: string;
  repository?: string;
  homepage?: string;
  keywords?: string[];
  readme?: string;
}

/** Raised for an event the state does not allow. Reported as invalid_transition (409). */
export class IllegalTransition extends RegistryError {
  constructor(rec: Pick<VersionRecord, 'name' | 'version' | 'state'>, ev: VersionEvent) {
    super('invalid_transition', `Cannot ${ev.type} '${rec.name}' ${rec.version}: it is ${rec.state}.`, {
      action: ev.type,
      name: rec.name,
      version: rec.version,
      state: rec.state,
    });
    this.name = 'IllegalTransition';
  }
}

/** A group event for a row that belongs to another group, or to none. Reported as invalid_transition (409). */
export class WrongGroup extends RegistryError {
  constructor(rec: Pick<VersionRecord, 'name' | 'version' | 'group_id'>, ev: GroupEvent) {
    super('invalid_transition', `Cannot ${ev.type} '${rec.name}' ${rec.version} for group ${ev.group_id}: it belongs to ${rec.group_id === undefined ? 'no group' : `group ${rec.group_id}`}.`, {
      action: ev.type,
      name: rec.name,
      version: rec.version,
      group_id: ev.group_id,
    });
    this.name = 'WrongGroup';
  }
}

function applyGroupEvent(rec: VersionRecord, ev: GroupEvent): VersionRecord {
  if (rec.group_id !== ev.group_id) throw new WrongGroup(rec, ev);
  const next = (patch: Partial<VersionRecord>): VersionRecord => ({ ...rec, ...patch, rev: rec.rev + 1 });
  if (ev.type === 'stage') {
    if (rec.state !== 'pending') throw new IllegalTransition(rec, ev);
    if (rec.staged_attempt === ev.attempt) return rec;
    // A stage of an older attempt (a message that outlived a reopen) must not overwrite a newer fill.
    if (rec.staged_attempt !== undefined && rec.staged_attempt > ev.attempt) throw new IllegalTransition(rec, ev);
    return next({ ...ev.fill, staged_attempt: ev.attempt });
  }
  // The flip: only a filled member of this attempt is published; every other state is left alone (never unyanks).
  if (rec.state !== 'pending') return rec;
  if (rec.staged_attempt !== ev.attempt) throw new IllegalTransition(rec, ev);
  return next({ state: 'published', published_at: ev.committed_at });
}

/**
 * The next record for an event. Returns the same object when the event changes nothing (idempotent yank,
 * publish of a published one, tombstone of a tombstoned one); otherwise a new object with `rev` + 1.
 */
export function applyEvent(rec: VersionRecord, ev: VersionEvent): VersionRecord {
  if (ev.type === 'stage' || ev.type === 'group_publish') return applyGroupEvent(rec, ev);
  const next = (patch: Partial<VersionRecord>): VersionRecord => ({ ...rec, ...patch, rev: rec.rev + 1 });
  switch (rec.state) {
    case 'tombstoned':
      if (ev.type === 'tombstone') return rec;
      throw new IllegalTransition(rec, ev);
    case 'pending':
      if (ev.type === 'publish') return next({ state: 'published', ...(ev.fill ?? {}) });
      if (ev.type === 'tombstone') return tombstoned(rec, ev, next);
      throw new IllegalTransition(rec, ev);
    case 'published':
      if (ev.type === 'publish') return rec;
      if (ev.type === 'unyank') throw new IllegalTransition(rec, ev);
      if (ev.type === 'yank') {
        if (ev.reason.length === 0) throw new RegistryError('invalid_request', 'A yank needs a reason.', { detail: 'a yank needs a reason' });
        return next({ state: 'yanked', yank_reason: ev.reason });
      }
      return tombstoned(rec, ev, next);
    case 'yanked':
      if (ev.type === 'yank') return rec;
      if (ev.type === 'unyank') {
        const { yank_reason: _drop, ...rest } = rec;
        return { ...rest, state: 'published', rev: rec.rev + 1 };
      }
      if (ev.type === 'tombstone') return tombstoned(rec, ev, next);
      throw new IllegalTransition(rec, ev);
  }
}

function tombstoned(
  rec: VersionRecord,
  ev: Extract<VersionEvent, { type: 'tombstone' }>,
  next: (p: Partial<VersionRecord>) => VersionRecord,
): VersionRecord {
  // The bytes are gone; the sha256 stays so a lock can be explained.
  const files = rec.state === 'pending' && ev.unpublished ? [] : rec.files.map(({ url: _url, ...f }) => f);
  const out = next({ state: 'tombstoned', tombstone: { reason_code: ev.reason_code, date: ev.date }, files });
  delete out.yank_reason;
  return out;
}
