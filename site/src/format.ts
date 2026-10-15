// Display formatting for API values: times in UTC, byte sizes, version states. Pure and locale-free, so a page renders
// the same bytes everywhere (and in tests).

import type { VersionState } from './types.js';

/** '2026-10-13T12:00:00Z' -> '2026-10-13 12:00 UTC'. A string that is not a timestamp is returned unchanged. */
export function formatTime(iso: string): string {
  const t = Date.parse(iso);
  if (Number.isNaN(t)) return iso;
  const s = new Date(t).toISOString();
  return `${s.slice(0, 10)} ${s.slice(11, 16)} UTC`;
}

/** The date part only: '2026-10-13'. */
export function formatDate(iso: string): string {
  const t = Date.parse(iso);
  return Number.isNaN(t) ? iso : new Date(t).toISOString().slice(0, 10);
}

const UNITS = ['KiB', 'MiB', 'GiB', 'TiB'];

/** 512 -> '512 bytes', 123456 -> '120.6 KiB'. */
export function formatBytes(n: number): string {
  if (!Number.isFinite(n) || n < 0) return String(n);
  if (n < 1024) return n === 1 ? '1 byte' : `${Math.round(n)} bytes`;
  let v = n / 1024;
  let u = 0;
  // Compare the shown (rounded) value, so 1048575 bytes is '1.0 MiB', not '1024.0 KiB'.
  while (Number(v.toFixed(1)) >= 1024 && u < UNITS.length - 1) {
    v /= 1024;
    u++;
  }
  return `${v.toFixed(1)} ${UNITS[u]}`;
}

/** A version's state as words; never empty, and an unknown state shows the raw value the API sent. */
export function stateLabel(state: VersionState, raw?: string, yankReason?: string | null): string {
  switch (state) {
    case 'published':
      return 'published';
    case 'yanked':
      return yankReason ? `yanked: ${yankReason}` : 'yanked';
    case 'tombstoned':
      return 'tombstoned (files removed by an administrator)';
    default:
      return `unknown (${raw ?? 'no state'})`;
  }
}
