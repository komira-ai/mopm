import { RegistryError } from './errors';
import type { VersionRecord } from './types';

/**
 * pending -> published -> yanked <-> published, and any -> tombstoned (terminal).
 * `pending -> tombstoned` is how a rejected publish burns its number.
 */
export type VersionEvent =
  | { type: 'publish' }
  | { type: 'yank'; reason: string }
  | { type: 'unyank' }
  | { type: 'tombstone'; reason_code: string; date: string };

/** Raised for an event the state does not allow. Reported as version_not_found: the spec has no dedicated code. */
export class IllegalTransition extends RegistryError {
  constructor(rec: Pick<VersionRecord, 'name' | 'version' | 'state'>, ev: VersionEvent) {
    super('version_not_found', `'${rec.name}' has no version '${rec.version}'.`, {
      name: rec.name,
      version: rec.version,
      reason: `cannot ${ev.type} a ${rec.state} version`,
    });
    this.name = 'IllegalTransition';
  }
}

/**
 * The next record for an event. Returns the same object when the event changes nothing (idempotent yank,
 * unyank of a published version, publish of a published one); otherwise a new object with `rev` + 1.
 */
export function applyEvent(rec: VersionRecord, ev: VersionEvent): VersionRecord {
  const next = (patch: Partial<VersionRecord>): VersionRecord => ({ ...rec, ...patch, rev: rec.rev + 1 });
  switch (rec.state) {
    case 'tombstoned':
      if (ev.type === 'tombstone') return rec;
      throw new IllegalTransition(rec, ev);
    case 'pending':
      if (ev.type === 'publish') return next({ state: 'published' });
      if (ev.type === 'tombstone') return tombstoned(rec, ev, next);
      throw new IllegalTransition(rec, ev);
    case 'published':
      if (ev.type === 'publish' || ev.type === 'unyank') return rec;
      if (ev.type === 'yank') {
        if (ev.reason.length === 0) throw new IllegalTransition(rec, ev);
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
  const files = rec.files.map(({ url: _url, ...f }) => f);
  const out = next({ state: 'tombstoned', tombstone: { reason_code: ev.reason_code, date: ev.date }, files });
  delete out.yank_reason;
  return out;
}
