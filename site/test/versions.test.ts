// The release lines of src/versions.ts: semver's grammar and order, one line per major and per 0.MINOR, the version
// that shows a line (published first, a release before a pre-release), and versions outside the grammar after every
// line. Each table lists the cases of one rule; the inputs are VersionSummary rows as the API gives them.
import { compareSemver, lineOf, parseSemver, releaseLines } from '../src/versions';
import type { VersionSummary, VersionState } from '../src/types';

const AT = '2026-10-13T12:00:00Z';
const v = (version: string, state: VersionState = 'published'): VersionSummary => ({ version, state, published_at: AT });
/** The rows as [line, shown version, its state, count], the shape every case below compares. */
const rows = (versions: VersionSummary[]) => releaseLines(versions).map((l) => [l.line, l.shown.version, l.shown.state, l.count]);

describe('parseSemver', () => {
  test.each([
    ['1.2.3', { major: '1', minor: '2', patch: '3', pre: [] }],
    ['0.0.0', { major: '0', minor: '0', patch: '0', pre: [] }],
    ['1.0.0-rc.1', { major: '1', minor: '0', patch: '0', pre: ['rc', '1'] }],
    ['1.0.0-0.3.7', { major: '1', minor: '0', patch: '0', pre: ['0', '3', '7'] }],
    ['1.0.0-x-y.0a', { major: '1', minor: '0', patch: '0', pre: ['x-y', '0a'] }],
    ['1.0.0+build.5', { major: '1', minor: '0', patch: '0', pre: [] }],
    ['1.0.0-beta+exp.sha.5114f85', { major: '1', minor: '0', patch: '0', pre: ['beta'] }],
    ['12345678901234567890.0.0', { major: '12345678901234567890', minor: '0', patch: '0', pre: [] }],
  ])('%j is read', (s, want) => {
    expect(parseSemver(s)).toEqual(want);
  });

  test.each([
    '', '1', '1.0', '1.0.0.0', 'v1.0.0', '01.0.0', '1.01.0', '1.0.01', '1.0.0-', '1.0.0-01', '1.0.0-a..b', '1.0.0+',
    '1.0.0+a..b', '1.0.0-a_b', ' 1.0.0', '1.0.0 ', '1.0.0\n', '-1.0.0', '1.0.0rc1', '../x',
  ])('%j is outside the grammar', (s) => {
    expect(parseSemver(s)).toBeNull();
  });
});

describe('compareSemver', () => {
  const cmp = (a: string, b: string) => Math.sign(compareSemver(parseSemver(a)!, parseSemver(b)!));

  // semver.org, item 11's example, then numeric parts that text order or a JavaScript number would get wrong.
  test.each([
    ['1.0.0-alpha', '1.0.0-alpha.1'],
    ['1.0.0-alpha.1', '1.0.0-alpha.beta'],
    ['1.0.0-alpha.beta', '1.0.0-beta'],
    ['1.0.0-beta', '1.0.0-beta.2'],
    ['1.0.0-beta.2', '1.0.0-beta.11'],
    ['1.0.0-beta.11', '1.0.0-rc.1'],
    ['1.0.0-rc.1', '1.0.0'],
    ['1.0.0', '2.0.0'],
    ['2.0.0', '2.1.0'],
    ['2.1.0', '2.1.1'],
    ['9.0.0', '10.0.0'],
    ['0.9.0', '0.10.0'],
    ['1.0.9', '1.0.10'],
    ['1.0.0-2', '1.0.0-10'],
    ['1.0.0-99', '1.0.0-a'],
    ['1.0.0-B', '1.0.0-a'],
    ['9007199254740992.0.0', '9007199254740993.0.0'],
    ['0.0.0-rc', '0.0.0'],
  ])('%j < %j', (a, b) => {
    expect([cmp(a, b), cmp(b, a), cmp(a, a)]).toEqual([-1, 1, 0]);
  });

  test('build metadata does not change the order', () => {
    expect([cmp('1.0.0+a', '1.0.0+b'), cmp('1.0.0+a', '1.0.0'), cmp('1.0.0-rc+a', '1.0.0-rc')]).toEqual([0, 0, 0]);
  });
});

test.each([
  ['2.3.4', '2.x'],
  ['10.0.0', '10.x'],
  ['1.0.0-rc.1', '1.x'],
  ['0.4.1', '0.4.x'],
  ['0.10.0', '0.10.x'],
  ['0.0.3', '0.0.x'],
  ['0.3.0-alpha', '0.3.x'],
])('lineOf(%j) is %j', (s, want) => {
  expect(lineOf(parseSemver(s)!)).toBe(want);
});

describe('releaseLines', () => {
  test('nothing in, nothing out', () => {
    expect(releaseLines([])).toEqual([]);
  });

  test('one row per major from 1 up, newest line first, each shown by its highest version and counting all of it', () => {
    expect(rows([v('2.1.0'), v('2.0.0'), v('1.5.0'), v('1.0.3'), v('1.0.0'), v('10.0.0')])).toEqual([
      ['10.x', '10.0.0', 'published', 1],
      ['2.x', '2.1.0', 'published', 2],
      ['1.x', '1.5.0', 'published', 3],
    ]);
  });

  test('below 1.0.0 each minor is a line of its own, ordered by number, and 0.0.x is one line', () => {
    expect(rows([v('1.0.0'), v('0.10.0'), v('0.9.1'), v('0.9.0'), v('0.2.0'), v('0.0.2'), v('0.0.1')])).toEqual([
      ['1.x', '1.0.0', 'published', 1],
      ['0.10.x', '0.10.0', 'published', 1],
      ['0.9.x', '0.9.1', 'published', 2],
      ['0.2.x', '0.2.0', 'published', 1],
      ['0.0.x', '0.0.2', 'published', 2],
    ]);
  });

  test('the order the API gives does not change the lines or the version shown', () => {
    const want = rows([v('2.0.0'), v('1.1.0'), v('1.0.0'), v('0.3.0')]);
    expect(rows([v('1.0.0'), v('0.3.0'), v('2.0.0'), v('1.1.0')])).toEqual(want);
    expect(rows([v('0.3.0'), v('1.1.0'), v('1.0.0'), v('2.0.0')])).toEqual(want);
  });

  test('a pre-release sorts below its release: the release shows the line', () => {
    expect(rows([v('1.0.0-rc.1'), v('1.0.0'), v('1.0.0-beta')])).toEqual([['1.x', '1.0.0', 'published', 3]]);
  });

  test('a release shows its line even when a pre-release of a higher version is newer', () => {
    expect(rows([v('1.1.0-beta.1'), v('1.0.0')])).toEqual([['1.x', '1.0.0', 'published', 2]]);
  });

  test('a line of pre-releases only is shown by its highest one, and places by it', () => {
    expect(rows([v('2.0.0-rc.1'), v('2.0.0-rc.2'), v('1.0.0'), v('0.3.0-alpha')])).toEqual([
      ['2.x', '2.0.0-rc.2', 'published', 2],
      ['1.x', '1.0.0', 'published', 1],
      ['0.3.x', '0.3.0-alpha', 'published', 1],
    ]);
  });

  test('a yanked version does not show its line while a version of the line is published', () => {
    expect(rows([v('1.1.0', 'yanked'), v('1.0.0')])).toEqual([['1.x', '1.0.0', 'published', 2]]);
  });

  test('a published pre-release shows its line before a yanked release', () => {
    expect(rows([v('1.1.0', 'yanked'), v('1.1.0-rc.1')])).toEqual([['1.x', '1.1.0-rc.1', 'published', 2]]);
  });

  test('a line with nothing published is shown by its highest version, in its own state', () => {
    expect(rows([v('2.1.0', 'yanked'), v('2.0.0', 'yanked'), v('1.0.0')])).toEqual([
      ['2.x', '2.1.0', 'yanked', 2],
      ['1.x', '1.0.0', 'published', 1],
    ]);
    expect(rows([v('3.1.0', 'tombstoned'), v('3.0.0', 'yanked')])).toEqual([['3.x', '3.1.0', 'tombstoned', 2]]);
    expect(rows([v('4.0.0', 'unknown')])).toEqual([['4.x', '4.0.0', 'unknown', 1]]);
  });

  test('with nothing published, a pre-release above the release shows the line: only the higher counts', () => {
    expect(rows([v('1.0.0', 'yanked'), v('1.1.0-rc.1', 'yanked')])).toEqual([['1.x', '1.1.0-rc.1', 'yanked', 2]]);
    expect(rows([v('1.1.0-rc.1', 'tombstoned'), v('1.0.0', 'yanked')])).toEqual([['1.x', '1.1.0-rc.1', 'tombstoned', 2]]);
    expect(rows([v('1.0.0-rc.1', 'yanked'), v('1.0.0', 'yanked')])).toEqual([['1.x', '1.0.0', 'yanked', 2]]);
  });

  test('a tombstoned or unknown-state version does not show its line while one of the line is published', () => {
    expect(rows([v('1.2.0', 'tombstoned'), v('1.1.0', 'unknown'), v('1.0.0')])).toEqual([['1.x', '1.0.0', 'published', 3]]);
  });

  test('versions outside the grammar are rows of their own after every line, in the order given', () => {
    const out = releaseLines([v('v2.0.0'), v('1.0.0'), v('1.0', 'yanked'), v('0.1.0')]);
    expect(out.map((l) => [l.line, l.shown.version, l.shown.state, l.count])).toEqual([
      ['1.x', '1.0.0', 'published', 1],
      ['0.1.x', '0.1.0', 'published', 1],
      [null, 'v2.0.0', 'published', 1],
      [null, '1.0', 'yanked', 1],
    ]);
  });

  test('only versions outside the grammar: each a row, nothing grouped', () => {
    expect(rows([v('a'), v('a')])).toEqual([
      [null, 'a', 'published', 1],
      [null, 'a', 'published', 1],
    ]);
  });

  test('two versions equal but for build metadata: the first given shows the line, both are counted', () => {
    expect(rows([v('1.0.0+a'), v('1.0.0+b')])).toEqual([['1.x', '1.0.0+a', 'published', 2]]);
    expect(rows([v('1.0.0+b'), v('1.0.0+a')])).toEqual([['1.x', '1.0.0+b', 'published', 2]]);
  });

  test('majors past the largest exact JavaScript number keep their order', () => {
    expect(rows([v('9007199254740992.0.0'), v('9007199254740993.0.0')])).toEqual([
      ['9007199254740993.x', '9007199254740993.0.0', 'published', 1],
      ['9007199254740992.x', '9007199254740992.0.0', 'published', 1],
    ]);
  });

  test('every version given is counted in exactly one row', () => {
    const versions = [v('2.0.0'), v('2.0.0-rc.1'), v('1.0.0', 'yanked'), v('0.2.0'), v('0.1.1', 'tombstoned'), v('0.1.0'), v('bad')];
    expect(releaseLines(versions).reduce((n, l) => n + l.count, 0)).toBe(versions.length);
  });
});
