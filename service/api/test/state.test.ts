import { applyEvent, IllegalTransition, type VersionEvent } from '../src/state';
import type { VersionState } from '../src/types';
import { rec } from './helpers';

const YANK: VersionEvent = { type: 'yank', reason: 'broken' };
const UNYANK: VersionEvent = { type: 'unyank' };
const PUBLISH: VersionEvent = { type: 'publish' };
const TOMB: VersionEvent = { type: 'tombstone', reason_code: 'malware', date: '2026-10-12' };
const at = (state: VersionState) => rec({ name: 'p', version: '1.0', state, ...(state === 'yanked' ? { yank_reason: 'old' } : {}) });

describe('state machine', () => {
  // [from, event, to]; to=null means the event is refused.
  const table: [VersionState, VersionEvent, VersionState | null][] = [
    ['pending', PUBLISH, 'published'],
    ['pending', TOMB, 'tombstoned'],
    ['pending', YANK, null],
    ['pending', UNYANK, null],
    ['published', YANK, 'yanked'],
    ['published', UNYANK, 'published'],
    ['published', PUBLISH, 'published'],
    ['published', TOMB, 'tombstoned'],
    ['yanked', UNYANK, 'published'],
    ['yanked', YANK, 'yanked'],
    ['yanked', TOMB, 'tombstoned'],
    ['yanked', PUBLISH, null],
    ['tombstoned', PUBLISH, null],
    ['tombstoned', YANK, null],
    ['tombstoned', UNYANK, null],
    ['tombstoned', TOMB, 'tombstoned'],
  ];

  test.each(table)('%s + %j -> %s', (from, ev, to) => {
    if (to === null) {
      expect(() => applyEvent(at(from), ev)).toThrow(IllegalTransition);
    } else {
      expect(applyEvent(at(from), ev).state).toBe(to);
    }
  });

  test('a real change bumps rev, an idempotent one returns the same record', () => {
    const p = at('published');
    expect(applyEvent(p, YANK).rev).toBe(p.rev + 1);
    expect(applyEvent(p, UNYANK)).toBe(p);
    const y = at('yanked');
    expect(applyEvent(y, YANK)).toBe(y);
    expect(applyEvent(y, YANK).yank_reason).toBe('old'); // the first reason stands
  });

  test('unyank drops the reason; yank sets it', () => {
    expect(applyEvent(at('yanked'), UNYANK)).not.toHaveProperty('yank_reason');
    expect(applyEvent(at('published'), YANK).yank_reason).toBe('broken');
  });

  test('yank needs a reason', () => {
    expect(() => applyEvent(at('published'), { type: 'yank', reason: '' })).toThrow(IllegalTransition);
  });

  test('tombstone removes urls, keeps sha256 and drops a yank reason', () => {
    const t = applyEvent(at('yanked'), TOMB);
    expect(t.state).toBe('tombstoned');
    expect(t.tombstone).toEqual({ reason_code: 'malware', date: '2026-10-12' });
    expect(t).not.toHaveProperty('yank_reason');
    expect(t.files.length).toBeGreaterThan(0);
    for (const f of t.files) {
      expect(f).not.toHaveProperty('url');
      expect(f.sha256).toMatch(/^[0-9a-f]{64}$/);
    }
  });

  test('the transition error is version_not_found with a reason', () => {
    expect(() => applyEvent(at('tombstoned'), YANK)).toThrow(expect.objectContaining({ code: 'version_not_found', status: 404 }));
  });
});
