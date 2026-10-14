// format.ts: the words and numbers a page shows for API values, locale-free so every reader (and test) sees the same.
import { formatBytes, formatDate, formatTime, stateLabel } from '../src/format';

describe('stateLabel', () => {
  test.each([
    ['published', undefined, undefined, 'published'],
    ['yanked', undefined, 'crashes on empty body', 'yanked: crashes on empty body'],
    ['yanked', undefined, '', 'yanked'],
    ['yanked', undefined, null, 'yanked'],
    ['tombstoned', undefined, undefined, 'tombstoned (files removed by an administrator)'],
    ['unknown', 'quarantined', undefined, 'unknown (quarantined)'],
    ['unknown', undefined, undefined, 'unknown (no state)'],
  ] as const)('%s (raw %s, reason %s) is "%s"', (state, raw, reason, want) => {
    expect(stateLabel(state, raw, reason)).toBe(want);
  });
});

describe('formatTime and formatDate', () => {
  test('a timestamp is its UTC date and minute', () => {
    expect(formatTime('2026-10-13T12:00:00Z')).toBe('2026-10-13 12:00 UTC');
    expect(formatTime('2026-10-13T23:59:59.999Z')).toBe('2026-10-13 23:59 UTC');
  });

  test('an offset is converted to UTC, across midnight', () => {
    expect(formatTime('2026-10-13T23:30:00-02:00')).toBe('2026-10-14 01:30 UTC');
    expect(formatDate('2026-10-13T23:30:00-02:00')).toBe('2026-10-14');
  });

  test('a string that is not a timestamp is shown unchanged', () => {
    expect(formatTime('soon')).toBe('soon');
    expect(formatDate('')).toBe('');
  });
});

describe('formatBytes', () => {
  test.each([
    [0, '0 bytes'],
    [1, '1 byte'],
    [1023, '1023 bytes'],
    [1024, '1.0 KiB'],
    [123456, '120.6 KiB'],
    [1024 * 1024 - 1, '1.0 MiB'],
    [1024 * 1024 - 52, '1023.9 KiB'],
    [1024 * 1024, '1.0 MiB'],
    [5 * 1024 ** 4, '5.0 TiB'],
    [3 * 1024 ** 5, '3072.0 TiB'],
    [-1, '-1'],
    [Number.NaN, 'NaN'],
  ])('%d is %s', (n, want) => {
    expect(formatBytes(n)).toBe(want);
  });
});
