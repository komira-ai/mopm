import { RegistryError } from './errors';
import type { VersionRecord } from './types';

/**
 * pending -> published -> yanked <-> published, and any -> tombstoned (terminal).
 * `pending -> tombstoned` is how a rejected publish burns its number.
 */
export type VersionEvent =
  | { type: 'publish'; fill?: PublishFill }
  | { type: 'yank'; reason: string }
  | { type: 'unyank' }
  /** `unpublished`: a pending version being burned by a rejected publish; no file was ever published, so none is kept. */
  | { type: 'tombstone'; reason_code: string; date: string; unpublished?: boolean };

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

/**
 * The next record for an event. Returns the same object when the event changes nothing (idempotent yank,
 * publish of a published one, tombstone of a tombstoned one); otherwise a new object with `rev` + 1.
 */
export function applyEvent(rec: VersionRecord, ev: VersionEvent): VersionRecord {
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
